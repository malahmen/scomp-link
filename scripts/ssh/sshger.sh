#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_DIR="${SCRIPT_DIR}/../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v jq  &>/dev/null || error_exit "jq is required: brew install jq  /  apt install jq"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# -----------------------------------------------------------------------------
# Core helpers — ~/.ssh/config is the single source of truth.
# The managed section (between BEGIN/END markers) holds all sshger profiles.
# -----------------------------------------------------------------------------

# Called from load_profiles; accesses its locals via bash dynamic scoping.
_profiles_flush() {
    [[ -z "$host" ]] && return
    local p
    p=$(jq -n \
        --arg host       "$host"            \
        --arg hostname   "$hostname"        \
        --arg user       "$user"            \
        --arg port       "$port"            \
        --arg key        "$key"             \
        --arg additional "${addl%$'\n'}"    \
        '{host:$host,hostname:$hostname,user:$user,port:$port,key:$key,additional:$additional}')
    json=$(printf '%s' "$json" | jq --arg n "$host" --argjson p "$p" '.profiles[$n]=$p')
    host=""; hostname=""; user=""; port="22"; key=""; addl=""
}

# Parse the managed section of ~/.ssh/config and return profiles as JSON.
load_profiles() {
    [[ ! -f "$SSH_DIR/config" ]] && printf '{"profiles": {}}\n' && return
    grep -q '^# === BEGIN sshger ===$' "$SSH_DIR/config" \
        || { printf '{"profiles": {}}\n'; return; }

    local json='{"profiles": {}}' host="" hostname="" user="" port="22" key="" addl="" in_managed=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '# === BEGIN sshger ===') in_managed=1; continue ;;
            '# === END sshger ===')   _profiles_flush; in_managed=0; continue ;;
        esac
        (( in_managed )) || continue
        [[ "$line" == '# Profile:'* ]] && continue
        if [[ "$line" =~ ^Host[[:space:]]+(.+)$ ]]; then
            _profiles_flush
            host="${BASH_REMATCH[1]}"; hostname="$host"; user=""; port="22"; key=""; addl=""
        elif [[ "$line" =~ ^[[:space:]]+HostName[[:space:]]+(.+)$    ]]; then hostname="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+User[[:space:]]+(.+)$        ]]; then user="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+Port[[:space:]]+(.+)$        ]]; then port="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+IdentityFile[[:space:]]+(.+)$ ]]; then key="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]] && -n "${line// }"           ]]; then addl+="$line"$'\n'
        fi
    done < "$SSH_DIR/config"

    printf '%s\n' "$json"
}

# Persist profiles by rewriting the managed section of ~/.ssh/config.
save_profiles() { update_ssh_config "$1"; }

# Rewrite only the sshger-managed section of ~/.ssh/config.
# Accepts profiles JSON as first argument; reads from config if omitted.
update_ssh_config() {
    local profiles_json="${1:-$(load_profiles)}"
    local section_tmp
    section_tmp=$(mktemp)

    printf '# === BEGIN sshger ===\n' > "$section_tmp"
    while IFS= read -r entry; do
        local name host hostname user port key additional
        name=$(printf '%s' "$entry"       | jq -r '.key')
        host=$(printf '%s' "$entry"       | jq -r '.value.host')
        hostname=$(printf '%s' "$entry"   | jq -r '.value.hostname')
        user=$(printf '%s' "$entry"       | jq -r '.value.user')
        port=$(printf '%s' "$entry"       | jq -r '.value.port')
        key=$(printf '%s' "$entry"        | jq -r '.value.key')
        additional=$(printf '%s' "$entry" | jq -r '.value.additional // empty')

        printf '# Profile: %s\nHost %s\n    HostName %s\n    User %s\n' \
            "$name" "$host" "$hostname" "$user" >> "$section_tmp"
        [[ "$port" != "22" ]] && printf '    Port %s\n' "$port" >> "$section_tmp"
        printf '    IdentityFile %s\n' "$key" >> "$section_tmp"
        [[ -n "$additional" ]] && printf '%s\n' "$additional" >> "$section_tmp"
        printf '\n' >> "$section_tmp"
    done < <(printf '%s' "$profiles_json" | jq -c '.profiles | to_entries[]')
    printf '# === END sshger ===\n' >> "$section_tmp"

    local tmp
    tmp=$(mktemp)

    if [[ ! -f "$SSH_DIR/config" ]]; then
        mv "$section_tmp" "$tmp"
    elif grep -q '^# === BEGIN sshger ===$' "$SSH_DIR/config"; then
        awk -v sf="$section_tmp" '
            /^# === BEGIN sshger ===$/ {
                while ((getline line < sf) > 0) print line
                close(sf); skip=1; next
            }
            /^# === END sshger ===$/ { skip=0; next }
            !skip { print }
        ' "$SSH_DIR/config" > "$tmp"
        rm -f "$section_tmp"
    elif grep -q '^# Managed by sshger' "$SSH_DIR/config"; then
        # Old whole-file format — replace entirely with the sectioned format
        mv "$section_tmp" "$tmp"
    else
        { cat "$SSH_DIR/config"; printf '\n'; cat "$section_tmp"; } > "$tmp"
        rm -f "$section_tmp"
    fi

    mv "$tmp" "$SSH_DIR/config"
    chmod 600 "$SSH_DIR/config"
}

_copy_to_clipboard() {
    if command -v pbcopy &>/dev/null; then
        pbcopy
    elif command -v xclip &>/dev/null; then
        xclip -selection clipboard
    elif command -v xsel &>/dev/null; then
        xsel --clipboard --input
    else
        return 1
    fi
}

_require_profiles() {
    local names
    names=$(load_profiles | jq -r '.profiles | keys[]')
    if [[ -z "$names" ]]; then
        warn "No profiles found. Add one first." >&2
        return 1
    fi
    echo "$names"
}

# Remove a Host block that sits OUTSIDE the managed section.
_remove_unmanaged_host() {
    local host_alias="$1"
    local tmp
    tmp=$(mktemp)
    awk -v host="$host_alias" '
        BEGIN { skip=0; in_managed=0 }
        /^# === BEGIN sshger ===$/ { in_managed=1; print; next }
        /^# === END sshger ===$/ { in_managed=0; print; next }
        in_managed { print; next }
        /^Host / {
            if ($2 == host) { skip=1; next }
            else { skip=0; print; next }
        }
        !skip { print }
    ' "$SSH_DIR/config" > "$tmp"
    mv "$tmp" "$SSH_DIR/config"
    chmod 600 "$SSH_DIR/config"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_add() {
    header "SSH Profile Manager — Add Profile"

    local profile_name host hostname user port key_path additional

    profile_name=$(gum input --placeholder "work, personal, github" \
        --header "Profile name:")
    [[ -z "$profile_name" ]] && warn "Profile name required." >&2 && return 1

    if load_profiles | jq -e --arg n "$profile_name" '.profiles[$n] != null' > /dev/null; then
        warn "Profile '$profile_name' already exists. Use 'edit' to modify it." >&2
        return 1
    fi

    host=$(gum input --placeholder "github.com" --header "Host:")
    [[ -z "$host" ]] && warn "Host required." >&2 && return 1

    if [[ -f "$SSH_DIR/config" ]] && \
       awk '/^Host / { for(i=2;i<=NF;i++) print $i }' "$SSH_DIR/config" | grep -qx "$host"; then
        warn "Host '$host' already exists in ~/.ssh/config. Use a different alias or edit the existing entry." >&2
        return 1
    fi

    hostname=$(gum input --placeholder "$host" \
        --header "HostName (leave blank to use Host):")
    [[ -z "$hostname" ]] && hostname="$host"

    # Catch the common copy-paste mistake: pasting a vendor URL like
    # 'git@ssh.dev.azure.com' or 'ubuntu@ec2-1-2-3-4.amazonaws.com' into the
    # HostName field. HostName must be a bare hostname; the part before '@' is
    # the SSH user and belongs in the User field. Split and inform.
    local default_user="git"
    if [[ "$hostname" == *@* ]]; then
        default_user="${hostname%%@*}"
        hostname="${hostname#*@}"
        info "Detected 'user@host' pattern — split into User='${default_user}', HostName='${hostname}'."
    fi

    user=$(gum input --placeholder "$default_user" --header "User:")
    [[ -z "$user" ]] && user="$default_user"

    port=$(gum input --placeholder "22" --header "Port:")
    [[ -z "$port" ]] && port="22"

    # SSH key -----------------------------------------------------------
    if gum confirm "Generate a new SSH key for this profile?"; then
        local key_type key_comment
        key_type=$(gum choose --header "Key type:" "ed25519" "rsa-4096")

        case "$key_type" in
            ed25519)  key_path="$SSH_DIR/id_${profile_name}_ed25519" ;;
            rsa-4096) key_path="$SSH_DIR/id_${profile_name}_rsa"     ;;
        esac

        key_comment=$(gum input --placeholder "$user@$host" --header "Key comment:")
        [[ -z "$key_comment" ]] && key_comment="$user@$host"

        case "$key_type" in
            ed25519)
                gum spin --spinner dot --title "Generating ed25519 key..." -- \
                    ssh-keygen -t ed25519 -f "$key_path" -C "$key_comment" -N ""
                ;;
            rsa-4096)
                gum spin --spinner dot --title "Generating RSA 4096 key..." -- \
                    ssh-keygen -t rsa -b 4096 -f "$key_path" -C "$key_comment" -N ""
                ;;
        esac
        chmod 600 "$key_path"
        success "Key generated: $key_path"
    else
        local existing_keys
        existing_keys=$(find "$SSH_DIR" -name "*.pub" -type f 2>/dev/null \
            | sed 's/\.pub$//' || true)
        if [[ -n "$existing_keys" ]]; then
            key_path=$(echo "$existing_keys" \
                | gum choose --header "Select existing key:")
        fi
        if [[ -z "${key_path:-}" ]]; then
            key_path=$(gum input --placeholder "$SSH_DIR/id_rsa" \
                --header "Key path:")
        fi
    fi

    # Additional options ------------------------------------------------
    info "Additional SSH config options (optional, ctrl+e to open in \$EDITOR):"
    local additional=""
    additional=$(gum write --placeholder "IdentitiesOnly yes
ProxyJump jump-host
ForwardAgent yes") || additional=""

    # Preview + confirm -------------------------------------------------
    # Show the resulting config block so the user can sanity-check field
    # placement (HostName vs User, etc.) before it's written to ~/.ssh/config.
    local preview="Host ${host}
    HostName ${hostname}
    User ${user}"
    [[ "$port" != "22" ]] && preview+="
    Port ${port}"
    preview+="
    IdentityFile ${key_path}"
    if [[ -n "$additional" ]]; then
        preview+="
$(printf '%s' "$additional" | sed 's/^/    /')"
    fi
    echo
    gum style --foreground "${CYAN:-212}" --bold "Resulting ~/.ssh/config block:"
    gum style --border rounded --padding "0 1" --foreground "${GREEN:-82}" "$preview"

    if ! gum confirm "Save this profile?"; then
        warn "Aborted — profile not saved." >&2
        return 1
    fi

    # Persist -----------------------------------------------------------
    local profiles new_profiles profile_json
    profiles=$(load_profiles)
    profile_json=$(jq -n \
        --arg host       "$host"       \
        --arg hostname   "$hostname"   \
        --arg user       "$user"       \
        --arg port       "$port"       \
        --arg key        "$key_path"   \
        --arg additional "$additional" \
        '{host: $host, hostname: $hostname, user: $user,
          port: $port, key: $key, additional: $additional}')
    new_profiles=$(echo "$profiles" \
        | jq --arg name "$profile_name" --argjson p "$profile_json" \
             '.profiles[$name] = $p')
    save_profiles "$new_profiles"

    success "Profile '$profile_name' added."

    # Usage example ------------------------------------------------------
    # The alias replaces the *entire* host part of an SSH/SCP-style URL.
    # Users frequently paste a vendor URL like 'git@host.com:repo' and
    # prepend the alias, ending up with 'alias@host.com:repo' — which makes
    # ssh ignore the config block entirely (no Host match) and fall back to
    # the default key. Show the correct shape explicitly.
    echo
    gum style --foreground "${CYAN:-212}" --bold "How to use this profile:"
    gum style --foreground "${GREEN:-82}" "  git clone ${host}:path/to/repo.git"
    gum style --foreground "${GREEN:-82}" "  ssh ${host}"
    gum style --foreground "${GREEN:-82}" "  scp file ${host}:/remote/path"
    echo
    gum style --foreground "${YELLOW:-220}" \
        "Don't write '${host}@${hostname}:…' — the alias '${host}' replaces the whole host part."
    gum style --faint \
        "(The alias resolves to user='${user}', host='${hostname}', and your key, via ~/.ssh/config.)"

    if [[ -f "${key_path}.pub" ]]; then
        info "Add this public key to your git hosting service before testing:"
        gum style --border rounded --padding "0 1" "$(cat "${key_path}.pub")"
        if gum confirm "Copy public key to clipboard?"; then
            if cat "${key_path}.pub" | _copy_to_clipboard; then
                success "Public key copied to clipboard."
            else
                warn "No clipboard utility found (pbcopy / xclip / xsel)." >&2
            fi
        fi
    fi

    gum confirm "Test the connection now?" && ssh -T "$host" 2>&1 || true
}

cmd_remove() {
    header "SSH Profile Manager — Remove Profile"

    local profile_names selected key_path profiles new_profiles
    profile_names=$(_require_profiles) || return
    profiles=$(load_profiles)

    selected=$(echo "$profile_names" | gum choose --header "Select profile to remove:")
    [[ -z "$selected" ]] && return

    gum confirm "Remove profile '$selected'?" || return

    key_path=$(echo "$profiles" | jq -r ".profiles[\"$selected\"].key")
    if [[ -f "$key_path" ]] && gum confirm "Also delete key files ($key_path)?"; then
        rm -f "$key_path" "${key_path}.pub"
        success "Key files deleted."
    fi

    new_profiles=$(echo "$profiles" | jq "del(.profiles[\"$selected\"])")
    save_profiles "$new_profiles"

    success "Profile '$selected' removed."
}

cmd_view() {
    header "SSH Profile Manager — View Profile"

    local profile_names selected profile key_path additional
    profile_names=$(_require_profiles) || return

    selected=$(echo "$profile_names" | gum choose --header "Select profile to view:")
    [[ -z "$selected" ]] && return

    profile=$(load_profiles | jq ".profiles[\"$selected\"]")

    gum style \
        --foreground "${CYAN}" --border-foreground "${CYAN}" --border rounded \
        --align left --width 60 --margin "1 2" --padding "1 2" \
        "$(printf 'Profile:   %s\n\nHost:      %s\nHostName:  %s\nUser:      %s\nPort:      %s\nIdentity:  %s' \
            "$selected" \
            "$(echo "$profile" | jq -r '.host')"     \
            "$(echo "$profile" | jq -r '.hostname')" \
            "$(echo "$profile" | jq -r '.user')"     \
            "$(echo "$profile" | jq -r '.port')"     \
            "$(echo "$profile" | jq -r '.key')")"

    additional=$(echo "$profile" | jq -r '.additional // empty')
    if [[ -n "$additional" ]]; then
        info "Additional options:"
        echo "$additional" | sed 's/^/  /'
    fi

    key_path=$(echo "$profile" | jq -r '.key')
    if [[ -f "${key_path}.pub" ]]; then
        info "Public key:"
        gum style --border rounded --padding "0 1" "$(cat "${key_path}.pub")"
    fi
}

cmd_edit() {
    header "SSH Profile Manager — Edit Profile"

    local profile_names selected current profiles new_profiles updated_json
    profile_names=$(_require_profiles) || return
    profiles=$(load_profiles)

    selected=$(echo "$profile_names" | gum choose --header "Select profile to edit:")
    [[ -z "$selected" ]] && return

    current=$(echo "$profiles" | jq ".profiles[\"$selected\"]")

    local new_host new_hostname new_user new_port new_key current_add new_additional
    new_host=$(gum input --header "Host:" \
        --value "$(echo "$current" | jq -r '.host')")
    new_hostname=$(gum input --header "HostName:" \
        --value "$(echo "$current" | jq -r '.hostname')")
    new_user=$(gum input --header "User:" \
        --value "$(echo "$current" | jq -r '.user')")
    new_port=$(gum input --header "Port:" \
        --value "$(echo "$current" | jq -r '.port')")
    new_key=$(gum input --header "Key path:" \
        --value "$(echo "$current" | jq -r '.key')")

    current_add=$(echo "$current" | jq -r '.additional // empty')
    info "Additional SSH config options (ctrl+e to open in \$EDITOR):"
    local new_additional=""
    new_additional=$(gum write --placeholder "Additional SSH options..." \
        ${current_add:+--value "$current_add"}) || new_additional="${current_add}"

    updated_json=$(jq -n \
        --arg host       "$new_host"       \
        --arg hostname   "$new_hostname"   \
        --arg user       "$new_user"       \
        --arg port       "$new_port"       \
        --arg key        "$new_key"        \
        --arg additional "$new_additional" \
        '{host: $host, hostname: $hostname, user: $user,
          port: $port, key: $key, additional: $additional}')
    new_profiles=$(echo "$profiles" \
        | jq --arg name "$selected" --argjson p "$updated_json" \
             '.profiles[$name] = $p')
    save_profiles "$new_profiles"

    success "Profile '$selected' updated."
}

cmd_use() {
    header "SSH Profile Manager — Wire Profile to a Repository"

    local target_dir
    target_dir=$(gum input \
        --header "Repository path:" \
        --value "$(pwd)")
    [[ -z "$target_dir" ]] && return

    target_dir="${target_dir/#\~/$HOME}"
    if [[ ! -d "$target_dir" ]]; then
        warn "Directory not found: $target_dir" >&2
        return 1
    fi

    if ! git -C "$target_dir" rev-parse --git-dir > /dev/null 2>&1; then
        warn "Not a git repository: $target_dir" >&2
        gum confirm "Initialize a git repo there?" || return
        git -C "$target_dir" init
    fi

    local profile_names selected profile host user key_path
    profile_names=$(_require_profiles) || return

    selected=$(echo "$profile_names" \
        | gum choose --header "Select profile to wire to this repo:")
    [[ -z "$selected" ]] && return

    profile=$(load_profiles | jq ".profiles[\"$selected\"]")
    host=$(echo "$profile"     | jq -r '.host')
    user=$(echo "$profile"     | jq -r '.user')
    key_path=$(echo "$profile" | jq -r '.key')

    local current_remote
    current_remote=$(git -C "$target_dir" config --get remote.origin.url 2>/dev/null || true)
    if [[ -z "$current_remote" ]]; then
        local repo_name suggested_url new_remote
        repo_name=$(basename "$target_dir")
        suggested_url="git@${host}:${user}/${repo_name}.git"
        new_remote=$(gum input --header "Remote URL:" --value "$suggested_url")
        [[ -n "$new_remote" ]] && git -C "$target_dir" remote add origin "$new_remote"
    fi

    # IdentitiesOnly prevents the SSH agent from offering unrelated keys
    git -C "$target_dir" config core.sshCommand "ssh -i ${key_path} -o IdentitiesOnly=yes"
    success "Profile '$selected' wired to: $target_dir"
    info "SSH command: $(git -C "$target_dir" config core.sshCommand)"

    if gum confirm "Set git user name/email for this repo?"; then
        local git_name git_email
        git_name=$(gum input --header "Git user name:")
        git_email=$(gum input --header "Git email:")
        [[ -n "$git_name" ]]  && git -C "$target_dir" config user.name  "$git_name"
        [[ -n "$git_email" ]] && git -C "$target_dir" config user.email "$git_email"
    fi

    gum confirm "Test the connection?" && git -C "$target_dir" fetch --dry-run 2>&1 || true
}

cmd_test() {
    header "SSH Profile Manager — Test Connection"

    if [[ ! -f "$SSH_DIR/config" ]]; then
        warn "No ~/.ssh/config found."
        return 0
    fi

    local all_hosts
    all_hosts=$(awk '/^Host / && $2 !~ /[*?]/ { print $2 }' "$SSH_DIR/config")

    if [[ -z "$all_hosts" ]]; then
        warn "No Host entries found in ~/.ssh/config." >&2
        return 0
    fi

    local scope
    scope=$(gum choose --header "Test which hosts?" \
        "selected — pick one or more" \
        "all — test every host")
    [[ -z "$scope" ]] && return 0

    local targets
    if [[ "$scope" == all* ]]; then
        targets="$all_hosts"
    else
        targets=$(echo "$all_hosts" | gum choose --no-limit \
            --header "Select hosts to test (space to toggle, enter to confirm):")
        [[ -z "$targets" ]] && return 0
    fi

    while IFS= read -r host_alias; do
        [[ -z "$host_alias" ]] && continue

        local effective_host target
        effective_host=$(ssh -G "$host_alias" 2>/dev/null | awk '/^hostname / {print $2; exit}')

        # Use git@<alias> only for known git hosting services — the User in
        # the config may legitimately be an account name (e.g. malahmen), not
        # the SSH username.  For everything else, pass just the alias and let
        # the SSH config supply the User.
        if printf '%s' "$effective_host" | grep -qiE "(github\.com|gitlab\.com|bitbucket\.org)$"; then
            target="git@${host_alias}"
        else
            target="$host_alias"
        fi

        info "Testing '$host_alias' → ${target} ..."
        local output exit_code=0
        output=$(ssh -T \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            "$target" </dev/null 2>&1) || exit_code=$?

        # Auth detection
        #
        # Most git-hosting services return a non-zero exit code even on a
        # successful SSH handshake because they refuse interactive shell
        # access after the key is verified. So exit code alone is not a
        # reliable signal — we need to inspect the message:
        #
        #   GitHub  : "Hi <user>! You've successfully authenticated, but GitHub
        #             does not provide shell access."
        #   GitLab  : "Welcome to GitLab, @<user>!"
        #   Bitbucket: "logged in as <user>"
        #   Azure DevOps: "remote: Shell access is not supported."
        #
        # Failure indicators take precedence so we never report a hard-fail as OK.
        local result
        if echo "$output" | grep -qiE 'permission denied|publickey.*(denied|failed)|could not be loaded|host key verification failed|no such identity'; then
            result="fail"
        elif [[ $exit_code -eq 0 ]] \
            || echo "$output" | grep -qiE 'authenticated|welcome|hello|shell access (is )?not (supported|allowed)|does not provide shell|logged in as'; then
            result="ok"
        else
            result="fail"
        fi

        if [[ "$result" == "ok" ]]; then
            success "[$host_alias] OK${output:+  ($output)}"
        else
            warn "[$host_alias] Failed (exit ${exit_code})${output:+  — $output}"
        fi
    done <<< "$targets"
}

cmd_import() {
    header "SSH Profile Manager — Import Unmanaged Hosts"

    if [[ ! -f "$SSH_DIR/config" ]]; then
        warn "No ~/.ssh/config found."
        return 0
    fi

    # Only surface hosts that sit OUTSIDE the managed section
    local unmanaged_hosts
    unmanaged_hosts=$(awk '
        /^# === BEGIN sshger ===$/ { skip=1; next }
        /^# === END sshger ===$/ { skip=0; next }
        !skip && /^Host / && $2 !~ /[*?]/ { print $2 }
    ' "$SSH_DIR/config")

    if [[ -z "$unmanaged_hosts" ]]; then
        info "No unmanaged Host entries found — nothing to import."
        return 0
    fi

    local selected
    selected=$(echo "$unmanaged_hosts" | gum choose --no-limit \
        --header "Select hosts to import (space to toggle, enter to confirm):")
    [[ -z "$selected" ]] && return 0

    local profiles imported=0
    profiles=$(load_profiles)

    while IFS= read -r host_alias; do
        [[ -z "$host_alias" ]] && continue

        local ssh_g_out hostname user port identity
        ssh_g_out=$(ssh -G "$host_alias" 2>/dev/null)
        hostname=$(printf '%s' "$ssh_g_out" | awk '/^hostname /    {print $2}')
        user=$(printf '%s'     "$ssh_g_out" | awk '/^user /        {print $2}')
        port=$(printf '%s'     "$ssh_g_out" | awk '/^port /        {print $2}')
        identity=$(printf '%s' "$ssh_g_out" | awk '/^identityfile /{print $2; exit}')
        identity="${identity/#\~/$HOME}"

        local profile_json
        profile_json=$(jq -n \
            --arg host     "$host_alias" \
            --arg hostname "${hostname:-$host_alias}" \
            --arg user     "${user:-$(whoami)}" \
            --arg port     "${port:-22}" \
            --arg key      "$identity" \
            --arg additional "" \
            '{host: $host, hostname: $hostname, user: $user,
              port: $port, key: $key, additional: $additional}')

        profiles=$(printf '%s' "$profiles" \
            | jq --arg name "$host_alias" --argjson p "$profile_json" \
                 '.profiles[$name] = $p')

        success "Imported: $host_alias → ${user}@${hostname}:${port}"
        (( imported++ )) || true
    done <<< "$selected"

    if [[ $imported -gt 0 ]]; then
        save_profiles "$profiles"
        info "$imported profile(s) moved to managed section."

        if gum confirm "Remove the original unmanaged entries to avoid duplicates?"; then
            while IFS= read -r host_alias; do
                [[ -z "$host_alias" ]] && continue
                _remove_unmanaged_host "$host_alias"
                info "Unmanaged entry removed: $host_alias"
            done <<< "$selected"
        fi
    fi
}

cmd_list() {
    header "SSH Profile Manager — All Profiles"

    local profiles profile_count
    profiles=$(load_profiles)
    profile_count=$(echo "$profiles" | jq '.profiles | length')

    if [[ "$profile_count" -eq 0 ]]; then
        info "No profiles configured yet."
        return
    fi

    echo "$profiles" | jq -r '
        .profiles | to_entries[] |
        "  \(.key)\n    Host: \(.value.host)  User: \(.value.user)  Port: \(.value.port)\n    Key:  \(.value.key)"'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    while true; do
        header "SSH Profile Manager"

        local profile_count
        profile_count=$(load_profiles | jq '.profiles | length')
        info "${profile_count} profile(s) configured."

        local action
        action=$(gum choose \
            --header "Select action:" \
            --height 14 \
            "add     — create a new profile and generate/assign a key" \
            "import  — bring unmanaged ~/.ssh/config hosts under management" \
            "remove  — delete a profile (optionally its key files)" \
            "view    — show profile details and public key" \
            "edit    — modify an existing profile" \
            "use     — wire a profile to the current git repo" \
            "test    — verify the SSH connection for a profile" \
            "list    — show all profiles" \
            "── quit") || true

        [[ -z "$action" || "$action" == "── quit" ]] && {
            gum style --faint "Bye."
            exit 0
        }

        case "$action" in
            add*)    cmd_add    || true ;;
            import*) cmd_import || true ;;
            remove*) cmd_remove || true ;;
            view*)   cmd_view   || true ;;
            edit*)   cmd_edit   || true ;;
            use*)    cmd_use    || true ;;
            test*)   cmd_test   || true ;;
            list*)   cmd_list   || true ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main

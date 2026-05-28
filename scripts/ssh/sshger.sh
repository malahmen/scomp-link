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
PROFILES_FILE="$SSH_DIR/profiles.json"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

[[ -f "$PROFILES_FILE" ]] || echo '{"profiles": {}}' > "$PROFILES_FILE"

# -----------------------------------------------------------------------------
# Core helpers
# -----------------------------------------------------------------------------

load_profiles() { cat "$PROFILES_FILE"; }

save_profiles() { echo "$1" > "$PROFILES_FILE"; }

# Write only the sshger-managed section of ~/.ssh/config.
# Entries outside the BEGIN/END markers are left untouched.
update_ssh_config() {
    local section_tmp
    section_tmp=$(mktemp)

    printf '# === BEGIN sshger ===\n' > "$section_tmp"
    while IFS= read -r entry; do
        local name host hostname user port key additional
        name=$(echo "$entry"       | jq -r '.key')
        host=$(echo "$entry"       | jq -r '.value.host')
        hostname=$(echo "$entry"   | jq -r '.value.hostname')
        user=$(echo "$entry"       | jq -r '.value.user')
        port=$(echo "$entry"       | jq -r '.value.port')
        key=$(echo "$entry"        | jq -r '.value.key')
        additional=$(echo "$entry" | jq -r '.value.additional // empty')

        printf '# Profile: %s\nHost %s\n    HostName %s\n    User %s\n' \
            "$name" "$host" "$hostname" "$user" >> "$section_tmp"
        [[ "$port" != "22" ]] && printf '    Port %s\n' "$port" >> "$section_tmp"
        printf '    IdentityFile %s\n' "$key" >> "$section_tmp"
        [[ -n "$additional" ]] && printf '%s\n' "$additional" >> "$section_tmp"
        printf '\n' >> "$section_tmp"
    done < <(load_profiles | jq -c '.profiles | to_entries[]')
    printf '# === END sshger ===\n' >> "$section_tmp"

    local tmp
    tmp=$(mktemp)

    if [[ ! -f "$SSH_DIR/config" ]]; then
        mv "$section_tmp" "$tmp"
    elif grep -q '^# === BEGIN sshger ===$' "$SSH_DIR/config"; then
        # Replace the existing managed section in place
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
        # First run on an existing config — append the managed section
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
    [[ -z "$profile_name" ]] && warn "Profile name required." && return 1

    host=$(gum input --placeholder "github.com" --header "Host:")
    [[ -z "$host" ]] && warn "Host required." && return 1

    hostname=$(gum input --placeholder "$host" \
        --header "HostName (leave blank to use Host):")
    [[ -z "$hostname" ]] && hostname="$host"

    user=$(gum input --placeholder "git" --header "User:")
    [[ -z "$user" ]] && user="git"

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

        info "Public key:"
        gum style --border rounded --padding "0 1" "$(cat "${key_path}.pub")"

        if gum confirm "Copy public key to clipboard?"; then
            if cat "${key_path}.pub" | _copy_to_clipboard; then
                success "Public key copied to clipboard."
            else
                warn "No clipboard utility found (pbcopy / xclip / xsel)."
            fi
        fi
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
    info "Additional SSH config options (optional):"
    additional=$(gum write --placeholder "IdentitiesOnly yes
ProxyJump jump-host
ForwardAgent yes") || additional=""

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
    update_ssh_config

    success "Profile '$profile_name' added."

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
    update_ssh_config

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
    new_additional=$(gum write --value "$current_add" \
        --placeholder "Additional SSH options...") || new_additional=""

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
    update_ssh_config

    success "Profile '$selected' updated."
}

cmd_use() {
    header "SSH Profile Manager — Use Profile in Current Directory"

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        warn "Not in a git repository."
        gum confirm "Initialize a git repo here?" || return
        git init
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
    current_remote=$(git config --get remote.origin.url 2>/dev/null || true)
    if [[ -z "$current_remote" ]]; then
        local repo_name suggested_url new_remote
        repo_name=$(basename "$(pwd)")
        suggested_url="git@${host}:${user}/${repo_name}.git"
        new_remote=$(gum input --header "Remote URL:" --value "$suggested_url")
        [[ -n "$new_remote" ]] && git remote add origin "$new_remote"
    fi

    # IdentitiesOnly prevents the SSH agent from offering unrelated keys
    git config core.sshCommand "ssh -i ${key_path} -o IdentitiesOnly=yes"
    success "Profile '$selected' wired to this repository."
    info "SSH command: $(git config core.sshCommand)"

    if gum confirm "Set git user name/email for this repo?"; then
        local git_name git_email
        git_name=$(gum input --header "Git user name:")
        git_email=$(gum input --header "Git email:")
        [[ -n "$git_name" ]]  && git config user.name  "$git_name"
        [[ -n "$git_email" ]] && git config user.email "$git_email"
    fi

    gum confirm "Test the connection?" && git fetch --dry-run 2>&1 || true
}

cmd_test() {
    header "SSH Profile Manager — Test Connection"

    local profile_names
    profile_names=$(_require_profiles) || return

    local scope
    scope=$(gum choose --header "Test which profiles?" \
        "selected — pick one" \
        "all — test every profile")
    [[ -z "$scope" ]] && return

    local targets
    if [[ "$scope" == all* ]]; then
        targets="$profile_names"
    else
        targets=$(echo "$profile_names" | gum choose --header "Select profile to test:")
        [[ -z "$targets" ]] && return
    fi

    local profiles
    profiles=$(load_profiles)

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local host user port key_path
        host=$(echo "$profiles"     | jq -r ".profiles[\"$name\"].host")
        user=$(echo "$profiles"     | jq -r ".profiles[\"$name\"].user")
        port=$(echo "$profiles"     | jq -r ".profiles[\"$name\"].port")
        key_path=$(echo "$profiles" | jq -r ".profiles[\"$name\"].key")

        info "Testing '$name' → ${user}@${host}:${port} ..."
        local output exit_code=0
        output=$(ssh -T \
            -i "$key_path" \
            -o IdentitiesOnly=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            -p "$port" \
            "${user}@${host}" 2>&1) || exit_code=$?

        # ssh -T exits 1 on hosts like GitHub that reject PTY but confirm auth;
        # treat any output containing an auth-success phrase as a pass.
        if [[ $exit_code -eq 0 ]] || echo "$output" | grep -qiE "(authenticated|welcome|success)"; then
            success "[$name] OK${output:+  ($output)}"
        else
            warn "[$name] Failed (exit ${exit_code})${output:+  — $output}"
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
        update_ssh_config
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

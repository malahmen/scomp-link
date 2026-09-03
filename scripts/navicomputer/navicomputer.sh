#!/usr/bin/env bash
# description: Manage SSH profiles in ~/.ssh/config via the navicomputer engine
# -----------------------------------------------------------------------------
# navicomputer.sh — gum front-end for the navicomputer SSH-profile engine.
#
# scomp-link owns the interactive experience (this file); the logic lives in the
# standalone navicomputer engine (its own repo). This shim resolves the engine
# (local checkout → cache → clone), collects options via gum, and runs the
# engine with the matching flags — the holo-convert / younglings-key pattern.
#
# Engine resolution order:
#   1. $NAVICOMPUTER_DIR/navicomputer.sh        (explicit override)
#   2. ../../../navicomputer/navicomputer.sh    (sibling dev checkout)
#   3. ~/.cache/scomp-link/navicomputer/…       (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)       (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_common/ui.sh
source "${SCRIPT_DIR}/../_common/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required to fetch the engine." >&2; exit 1; }

NAVI_REPO="${NAVICOMPUTER_REPO:-https://github.com/malahmen/navicomputer.git}"
NAVI_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/navicomputer"
ENGINE=""

# -----------------------------------------------------------------------------
resolve_engine() {
    if [[ -n "${NAVICOMPUTER_DIR:-}" && -f "${NAVICOMPUTER_DIR}/navicomputer.sh" ]]; then
        ENGINE="${NAVICOMPUTER_DIR}/navicomputer.sh"
        info "Using navicomputer from \$NAVICOMPUTER_DIR: ${NAVICOMPUTER_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../navicomputer/navicomputer.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/navicomputer.sh"
        info "Using local navicomputer checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${NAVI_CACHE}/navicomputer.sh" ]]; then
        ENGINE="${NAVI_CACHE}/navicomputer.sh"
        info "Using cached navicomputer: ${NAVI_CACHE}"
        if [[ -d "${NAVI_CACHE}/.git" ]] && gum confirm "Update navicomputer (git pull)?"; then
            gum spin --spinner dot --title "Updating navicomputer..." -- \
                git -C "$NAVI_CACHE" pull --ff-only || warn "Update failed; using the existing copy."
        fi
        return
    fi
    gum confirm "navicomputer engine not found. Clone it from ${NAVI_REPO}?" \
        || error_exit "navicomputer engine is unavailable."
    mkdir -p "$(dirname "$NAVI_CACHE")"
    gum spin --spinner dot --title "Cloning navicomputer..." -- \
        git clone --depth 1 "$NAVI_REPO" "$NAVI_CACHE" \
        || error_exit "Failed to clone navicomputer from ${NAVI_REPO}"
    ENGINE="${NAVI_CACHE}/navicomputer.sh"
    success "navicomputer cloned to ${NAVI_CACHE}"
}

# jq is the engine's hard dependency; the front-end parses its JSON too.
install_jq() {
    if command -v brew &>/dev/null; then gum spin --title "Installing jq..." -- brew install jq
    elif command -v apt-get &>/dev/null; then sudo apt-get update -y && sudo apt-get install -y jq
    elif command -v dnf &>/dev/null; then sudo dnf install -y jq
    else warn "No supported package manager — install jq manually."; fi
    command -v jq &>/dev/null
}
ensure_jq() {
    command -v jq &>/dev/null && return 0
    warn "jq is required (parsing SSH profiles)."
    gum confirm "Install jq now?" && install_jq && return 0
    return 1
}

engine() { bash "$ENGINE" "$@"; }

_copy_to_clipboard() {
    if command -v pbcopy &>/dev/null; then pbcopy
    elif command -v xclip &>/dev/null; then xclip -selection clipboard
    elif command -v xsel &>/dev/null; then xsel --clipboard --input
    else return 1; fi
}

# Pick a profile alias from the engine's JSON. Echoes the choice (empty = none).
pick_profile() {
    local names
    names=$(engine list --json 2>/dev/null | jq -r '.profiles | keys[]') || true
    [[ -n "$names" ]] || { warn "No profiles yet — add one first."; return 1; }
    printf '%s\n' "$names" | gum choose --header "${1:-Select a profile:}"
}

# -----------------------------------------------------------------------------
# Flows
# -----------------------------------------------------------------------------
nav_add() {
    header "Add SSH profile"
    local name hostname user port additional
    name=$(gum input --header "Profile name = Host alias (what you type after 'ssh'):" \
        --placeholder "github-work") || return
    [[ -n "$name" ]] || { warn "Name required."; return; }
    if engine list --json 2>/dev/null | jq -e --arg n "$name" '.profiles[$n]!=null' >/dev/null; then
        warn "Profile '$name' already exists — use Edit."; return
    fi
    hostname=$(gum input --header "HostName (blank = same as the alias):" --placeholder "github.com") || return
    local default_user="git"
    if [[ "$hostname" == *@* ]]; then
        default_user="${hostname%%@*}"; hostname="${hostname#*@}"
        info "Split 'user@host' → User='${default_user}', HostName='${hostname}'."
    fi
    user=$(gum input --header "User:" --placeholder "$default_user") || return; [[ -z "$user" ]] && user="$default_user"
    port=$(gum input --header "Port:" --placeholder "22") || return; [[ -z "$port" ]] && port="22"

    local key_args=()
    if gum confirm "Generate a new SSH key for this profile?"; then
        local ktype kcomment
        ktype=$(gum choose --header "Key type:" "ed25519" "rsa") || return
        kcomment=$(gum input --header "Key comment:" --placeholder "${user}@${name}") || true
        key_args=(--gen-key "$ktype"); [[ -n "$kcomment" ]] && key_args+=(--key-comment "$kcomment")
    else
        local existing sel=""
        existing=$(find "$HOME/.ssh" -name '*.pub' -type f 2>/dev/null | sed 's/\.pub$//' || true)
        [[ -n "$existing" ]] && sel=$(printf '%s\n' "$existing" | gum choose --header "Select existing key:") || true
        [[ -z "$sel" ]] && sel=$(gum input --header "Key path:" --placeholder "$HOME/.ssh/id_ed25519") || true
        [[ -n "$sel" ]] || { warn "A key is required."; return; }
        key_args=(--key "$sel")
    fi

    info "Additional SSH config options (optional, ctrl+e for \$EDITOR):"
    additional=$(gum write --placeholder $'IdentitiesOnly yes\nProxyJump jump-host') || additional=""

    local args=(add --name "$name" --user "$user" --port "$port")
    [[ -n "$hostname" ]] && args+=(--hostname "$hostname")
    args+=("${key_args[@]}")
    [[ -n "$additional" ]] && args+=(--additional "$additional")

    gum confirm "Save profile '$name'?" || { warn "Aborted."; return; }
    local pub; pub=$(engine "${args[@]}") || { warn "Add failed (see above)."; return; }

    gum style --foreground "${CYAN:-212}" --bold "How to use it:"
    gum style --foreground "${GREEN:-82}" "  ssh ${name}    git clone ${name}:path/repo.git    scp file ${name}:/path"
    if [[ -n "$pub" && -f "$pub" ]]; then
        info "Public key (add it to your git host before testing):"
        gum style --border rounded --padding "0 1" "$(cat "$pub")"
        gum confirm "Copy public key to clipboard?" && { cat "$pub" | _copy_to_clipboard && success "Copied." || warn "No clipboard tool found."; }
    fi
    gum confirm "Test the connection now?" && engine test --name "$name" || true
}

nav_edit() {
    header "Edit SSH profile"
    local name; name=$(pick_profile "Select a profile to edit:") || return
    [[ -n "$name" ]] || return
    local cur; cur=$(engine view --name "$name" --json)
    local hostname user port key additional
    hostname=$(gum input --header "HostName:" --value "$(jq -r .hostname <<<"$cur")") || return
    user=$(gum input --header "User:" --value "$(jq -r .user <<<"$cur")") || return
    port=$(gum input --header "Port:" --value "$(jq -r .port <<<"$cur")") || return
    key=$(gum input --header "Key path:" --value "$(jq -r .key <<<"$cur")") || return
    additional=$(gum write --value "$(jq -r '.additional // empty' <<<"$cur")") || additional=""
    engine edit --name "$name" --hostname "$hostname" --user "$user" --port "$port" \
        --key "$key" --additional "$additional" && success "Updated '$name'."
}

nav_view() {
    header "View SSH profile"
    local name; name=$(pick_profile "Select a profile to view:") || return
    [[ -n "$name" ]] || return
    engine view --name "$name"
    local key; key=$(engine view --name "$name" --json | jq -r .key)
    [[ -f "${key}.pub" ]] && { info "Public key:"; gum style --border rounded --padding "0 1" "$(cat "${key}.pub")"; }
}

nav_remove() {
    header "Remove SSH profile"
    local name; name=$(pick_profile "Select a profile to remove:") || return
    [[ -n "$name" ]] || return
    gum confirm "Remove profile '$name'?" || return
    local del=(); gum confirm "Also delete its key files?" && del=(--delete-keys)
    engine remove --name "$name" "${del[@]}"
}

nav_use() {
    header "Wire a profile to a git repo"
    local repo; repo=$(gum input --header "Repository path:" --value "$(pwd)") || return
    [[ -n "$repo" ]] || return
    local name; name=$(pick_profile "Select a profile to wire:") || return
    [[ -n "$name" ]] || return
    local extra=()
    if ! git -C "${repo/#\~/$HOME}" rev-parse --git-dir &>/dev/null; then
        gum confirm "Not a git repo — initialize one there?" && extra+=(--init) || return
    fi
    local remote; remote=$(gum input --header "Remote URL (blank = skip):" \
        --placeholder "git@${name}:me/repo.git") || true
    [[ -n "$remote" ]] && extra+=(--remote "$remote")
    if gum confirm "Set git user.name / user.email for this repo?"; then
        local gn ge; gn=$(gum input --header "Git user name:") || true; ge=$(gum input --header "Git email:") || true
        [[ -n "$gn" ]] && extra+=(--git-name "$gn"); [[ -n "$ge" ]] && extra+=(--git-email "$ge")
    fi
    engine use --name "$name" --repo "$repo" "${extra[@]}"
}

nav_test() {
    header "Test SSH connections"
    local scope; scope=$(gum choose --header "Test which?" "selected — pick profiles" "all — every host") || return
    if [[ "$scope" == all* ]]; then
        engine test --all
    else
        local picks; picks=$(engine hosts | gum choose --no-limit --header "Select hosts (space to toggle):") || true
        [[ -n "$picks" ]] || return
        local args=(test); while IFS= read -r h; do [[ -n "$h" ]] && args+=(--name "$h"); done <<< "$picks"
        engine "${args[@]}"
    fi
}

nav_import() {
    header "Import unmanaged hosts"
    local unmanaged; unmanaged=$(engine unmanaged) || true
    [[ -n "$unmanaged" ]] || { info "No unmanaged Host entries to import."; return; }
    local picks; picks=$(printf '%s\n' "$unmanaged" | gum choose --no-limit \
        --header "Select hosts to import (space to toggle):") || true
    [[ -n "$picks" ]] || return
    local args=(import); while IFS= read -r h; do [[ -n "$h" ]] && args+=(--host "$h"); done <<< "$picks"
    gum confirm "Remove the original unmanaged entries after importing?" && args+=(--remove-original)
    engine "${args[@]}"
}

nav_list() { header "All SSH profiles"; engine list; }

# -----------------------------------------------------------------------------
main() {
    resolve_engine
    ensure_jq || error_exit "jq is required."
    while true; do
        header "navicomputer — SSH profiles"
        local count; count=$(engine list --json 2>/dev/null | jq '.profiles | length' 2>/dev/null || echo 0)
        info "${count} profile(s) configured."
        local action
        action=$(gum choose --header "Select action:" --height 12 \
            "add     — create a profile (generate/assign a key)" \
            "import  — adopt unmanaged ~/.ssh/config hosts" \
            "list    — show all profiles" \
            "view    — show one profile + public key" \
            "edit    — modify a profile" \
            "use     — wire a profile to a git repo" \
            "test    — verify SSH auth" \
            "remove  — delete a profile" \
            "── quit") || exit 0
        case "$action" in
            add*)    nav_add    || true ;;
            import*) nav_import || true ;;
            list*)   nav_list   || true ;;
            view*)   nav_view   || true ;;
            edit*)   nav_edit   || true ;;
            use*)    nav_use    || true ;;
            test*)   nav_test   || true ;;
            remove*) nav_remove || true ;;
            *) exit 0 ;;
        esac
        echo ""
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"

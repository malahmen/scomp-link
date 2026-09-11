#!/usr/bin/env bash
# description: Vanilla WoW multibox client — gum front-end for the dark-portal engine
# Standalone export (export.sh): no extra setup deps — git is checked at runtime (engine clone).
# -----------------------------------------------------------------------------
# gum front-end for the standalone, flag-driven `dark-portal` engine — provisions
# and launches multiple vanilla WoW (1.12.1) clients under Wine (Bottles) for
# multiboxing on a single Linux PC. The real logic lives in its own repo as a
# gum-free CLI; this file only resolves that engine, collects options with gum,
# and drives it by flags. Same split as wow-nordrassil / protocol-droid /
# navicomputer / holo-convert / mind-trick / younglings-key.
#
# Named wow-dark-portal so it sorts next to wow-nordrassil (the server side).
#
# Engine resolution order:
#   1. $DARK_PORTAL_DIR/dark-portal.sh      (explicit override — a checkout you control)
#   2. ../../../dark-portal/dark-portal.sh  (sibling dev checkout next to scomp-link)
#   3. ~/.cache/scomp-link/dark-portal/…    (cached clone; offers git pull)
#   4. git clone --depth 1 (public HTTPS)   (first run)
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git &>/dev/null || { echo "[error] git is required." >&2; exit 1; }

DARK_PORTAL_REPO="${DARK_PORTAL_REPO:-https://github.com/malahmen/dark-portal.git}"
DARK_PORTAL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/dark-portal"
ENGINE=""

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

resolve_engine() {
    if [[ -n "${DARK_PORTAL_DIR:-}" && -f "${DARK_PORTAL_DIR}/dark-portal.sh" ]]; then
        ENGINE="${DARK_PORTAL_DIR}/dark-portal.sh"; info "Using dark-portal from \$DARK_PORTAL_DIR: ${DARK_PORTAL_DIR}"; return
    fi
    local sib="${SCRIPT_DIR}/../../../dark-portal/dark-portal.sh"
    if [[ -f "$sib" ]]; then
        ENGINE="$(cd "$(dirname "$sib")" && pwd)/dark-portal.sh"; info "Using local dark-portal checkout: $(dirname "$ENGINE")"; return
    fi
    if [[ -f "${DARK_PORTAL_CACHE}/dark-portal.sh" ]]; then
        ENGINE="${DARK_PORTAL_CACHE}/dark-portal.sh"; info "Using cached dark-portal: ${DARK_PORTAL_CACHE}"
        if [[ -d "${DARK_PORTAL_CACHE}/.git" ]] && gum confirm "Update dark-portal (git pull)?"; then
            gum spin --spinner dot --title "Updating dark-portal..." -- git -C "$DARK_PORTAL_CACHE" pull --ff-only || warn "Update failed; using existing copy."
        fi
        return
    fi
    gum confirm "dark-portal engine not found. Clone it from ${DARK_PORTAL_REPO}?" || error_exit "dark-portal engine is unavailable."
    mkdir -p "$(dirname "$DARK_PORTAL_CACHE")"
    gum spin --spinner dot --title "Cloning dark-portal..." -- git clone --depth 1 "$DARK_PORTAL_REPO" "$DARK_PORTAL_CACHE" \
        || error_exit "Failed to clone dark-portal from ${DARK_PORTAL_REPO}"
    ENGINE="${DARK_PORTAL_CACHE}/dark-portal.sh"; success "dark-portal cloned to ${DARK_PORTAL_CACHE}"
}

# Engine drivers. eget reads an effective config value for pre-filling prompts.
#
# engine: only for calls whose stdout is captured and whose exit status the
# caller inspects itself (the instance/runner/realm listings). Every action a
# menu runs goes through engine_foreground instead: under `set -e` a bare
# `engine` that exits non-zero (a rejected setting, a failed launch, a missing
# runner) or a Ctrl-C (our INT trap is `exit 0`) would end the whole TUI, while
# an error or an interrupt has to leave the operator back in the menu.
engine()     { bash "$ENGINE" "$@"; }
eget()       { bash "$ENGINE" get "$1" 2>/dev/null || true; }
engine_foreground() {
    trap ':' INT
    bash "$ENGINE" "$@" || true
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
}

# -----------------------------------------------------------------------------
# gum pickers — all interactivity lives here.
# -----------------------------------------------------------------------------

# _pick_value_label <header> <current-value> <default-label> "value|Label" ...
# Presents labels via gum choose, echoes the matching value on stdout.
_pick_value_label() {
    local hdr="$1" current="$2" fallback_label="$3"; shift 3
    local -a values=() labels=()
    local pair
    for pair in "$@"; do
        values+=("${pair%%|*}")
        labels+=("${pair#*|}")
    done
    local current_label="$fallback_label" i
    for i in "${!values[@]}"; do
        [[ "${values[$i]}" == "$current" ]] && current_label="${labels[$i]}"
    done
    local chosen
    chosen=$(printf '%s\n' "${labels[@]}" | gum choose --header "${hdr} (current: ${current_label}):") || true
    [[ -z "$chosen" ]] && { echo "$current"; return; }
    for i in "${!labels[@]}"; do
        [[ "${labels[$i]}" == "$chosen" ]] && { echo "${values[$i]}"; return; }
    done
    echo "$current"
}

# _pick_instance <header> — gum-choose an existing instance name (via the
# engine's machine-readable listing), empty/non-zero on cancel or none.
_pick_instance() {
    local hdr="$1" names
    # Bare `engine`: stdout is the data and the `|| true` is the caller's own
    # handling of a non-zero exit (nothing configured yet) — an empty list.
    names="$(engine list-instances --names 2>/dev/null || true)"
    [[ -n "$names" ]] || { warn "No instances configured yet — add one first."; return 1; }
    printf '%s\n' "$names" | gum choose --header "$hdr"
}

# _pick_instances <header> — like _pick_instance, but multi-select
# (space to toggle, enter to confirm) via --no-limit, for launch's multibox
# case: picking instances one at a time to start a multibox session is
# needlessly repetitive when they're all going to be launched anyway. Echoes
# one name per line; empty/non-zero on cancel or none configured.
_pick_instances() {
    local hdr="$1" names
    # Bare `engine`: same captured-listing case as _pick_instance.
    names="$(engine list-instances --names 2>/dev/null || true)"
    [[ -n "$names" ]] || { warn "No instances configured yet — add one first."; return 1; }
    printf '%s\n' "$names" | gum choose --no-limit --header "$hdr"
}

# Scan the LAN via the engine and persist the picked realm as the default.
_discover_and_set() {
    local candidates chosen
    # Bare `engine`: the scan's stdout is the candidate list and the `|| true`
    # is the caller's own handling of a failed/empty scan.
    candidates="$(engine discover-realm 2>/dev/null || true)"
    [[ -n "$candidates" ]] || { warn "No realm candidates found on the LAN."; return 1; }
    chosen=$(printf '%s\n' "$candidates" | gum choose --header "Candidate realm(s) (port open — not protocol-verified):") || true
    [[ -n "$chosen" ]] || return 1
    engine_foreground set DEFAULT_REALM_ADDRESS "$chosen"
    success "Default realm address set to ${chosen}."
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_configure() {
    header "dark-portal — Configure"

    local src
    src=$(gum input --value "$(eget CLIENT_SOURCE_DIR)" --placeholder "/path/to/vanilla client" \
        --header "Path to a pristine vanilla client install (contains WoW.exe):") || return 0
    # gum input does no shell expansion, and the engine only tilde-expands
    # CONFIG_DIR — a typed "~/games/wow" would be stored literally and make
    # `configure` fail on a path that does not exist.
    src="${src/#\~/$HOME}"
    [[ -n "$src" ]] && engine_foreground set CLIENT_SOURCE_DIR "$src"

    local mode
    mode=$(_pick_value_label "Client file isolation mode" "$(eget CLIENT_ISOLATION_MODE)" "full" \
        "full|full (complete copy per instance — best at high instance counts)" \
        "shared|shared (symlinked install, private WTF/Cache only — lowest disk use)")
    engine_foreground set CLIENT_ISOLATION_MODE "$mode"

    local arch
    arch=$(_pick_value_label "Bottle architecture" "$(eget WINE_ARCH)" "win32" \
        "win32|win32 (matches this 32-bit-era client)" "win64|win64")
    engine_foreground set WINE_ARCH "$arch"

    local runners runner cur_runner
    # Bare `engine`: captured listing, `|| true` handled by the branch below.
    runners="$(engine list-runners 2>/dev/null || true)"
    cur_runner="$(eget BOTTLES_RUNNER)"; cur_runner="${cur_runner:-<none>}"
    if [[ -n "$runners" ]]; then
        runner=$(printf '%s\n' "$runners" | gum choose --header "Wine runner (current: ${cur_runner}):") || true
        [[ -n "$runner" ]] && engine_foreground set BOTTLES_RUNNER "$runner"
    else
        warn "No Bottles Wine runner available yet — run 'Install dependencies', then launch Bottles once from your app menu so it downloads a runner."
    fi

    local res
    res=$(gum input --value "$(eget DEFAULT_RESOLUTION)" --header "Default window resolution (WxH):") || return 0
    [[ -n "$res" ]] && engine_foreground set DEFAULT_RESOLUTION "$res"

    local realm_choice
    realm_choice=$(gum choose "Enter manually" "Discover on LAN" \
        --header "Default realm ($(eget DEFAULT_REALM_ADDRESS):$(eget DEFAULT_REALM_PORT)):") || true
    case "$realm_choice" in
        "Discover on LAN") _discover_and_set || true ;;
        "Enter manually")
            local addr port
            addr=$(gum input --value "$(eget DEFAULT_REALM_ADDRESS)" --placeholder "192.168.1.50" --header "Realm address:") || true
            [[ -n "$addr" ]] && engine_foreground set DEFAULT_REALM_ADDRESS "$addr"
            port=$(gum input --value "$(eget DEFAULT_REALM_PORT)" --header "Realm port:") || true
            [[ -n "$port" ]] && engine_foreground set DEFAULT_REALM_PORT "$port"
            ;;
    esac

    # Validate the collected settings and grant Bottles the host fs access.
    engine_foreground configure
}

action_add_instance() {
    header "dark-portal — Add instance"
    local name
    name=$(gum input --placeholder "box1" --header "Instance name (letters/digits/-/_ — becomes its window title):") || return 0
    [[ -n "$name" ]] || { info "Cancelled."; return 0; }

    local res realm cur_addr
    cur_addr="$(eget DEFAULT_REALM_ADDRESS)"; cur_addr="${cur_addr:-<default>}"
    # Placeholder, not --value: pre-filling the default made every instance
    # store its own RESOLUTION copy, so a later change to DEFAULT_RESOLUTION
    # never reached it. Blank keeps the instance following the default.
    res=$(gum input --placeholder "$(eget DEFAULT_RESOLUTION)" --header "Resolution (blank = follow DEFAULT_RESOLUTION):") || true
    realm=$(gum input --placeholder "$cur_addr" --header "Realm address override (blank = use default):") || true

    local -a args=(add-instance --name "$name")
    [[ -n "$res" ]] && args+=(--resolution "$res")
    if [[ -n "$realm" ]]; then
        args+=(--realm "$realm")
        local port
        port=$(gum input --value "$(eget DEFAULT_REALM_PORT)" --header "Realm port for this override:") || true
        [[ -n "$port" ]] && args+=(--port "$port")
    fi
    engine_foreground "${args[@]}"
}

action_edit_instance() {
    header "dark-portal — Edit instance"
    local name; name=$(_pick_instance "Edit which instance?") || return 0
    [[ -n "$name" ]] || return 0

    local res realm
    res=$(gum input --header "New resolution WxH (blank = leave unchanged):") || true
    realm=$(gum input --header "New realm address override (blank = leave unchanged):") || true

    local -a args=(edit-instance --name "$name")
    [[ -n "$res" ]] && args+=(--resolution "$res")
    if [[ -n "$realm" ]]; then
        args+=(--realm "$realm")
        local port
        port=$(gum input --value "$(eget DEFAULT_REALM_PORT)" --header "Realm port:") || true
        [[ -n "$port" ]] && args+=(--port "$port")
    fi
    if [[ -z "$res" && -z "$realm" ]]; then
        info "Nothing to change."
        return 0
    fi
    engine_foreground "${args[@]}"
}

action_remove_instance() {
    header "dark-portal — Remove instance"
    local name; name=$(_pick_instance "Remove which instance?") || return 0
    [[ -n "$name" ]] || return 0
    gum confirm "Remove instance '${name}'? This deletes its Bottles bottle and client files." || { info "Cancelled."; return 0; }
    engine_foreground remove-instance --name "$name"
}

action_winecfg() {
    header "dark-portal — winecfg"
    local name; name=$(_pick_instance "Open winecfg for which instance?") || return 0
    [[ -n "$name" ]] || return 0
    engine_foreground winecfg --name "$name"
}

action_launch() {
    local names; names=$(_pick_instances "Launch which instance(s)? (space to select multiple, enter to launch)") || return 0
    [[ -n "$names" ]] || return 0

    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        engine_foreground launch --name "$name"
        echo ""
    done <<< "$names"
}

action_stop() {
    local name; name=$(_pick_instance "Stop which instance?") || return 0
    [[ -n "$name" ]] || return 0
    engine_foreground stop --name "$name"
}

# -----------------------------------------------------------------------------
# Menus — mirror the original category layout.
# -----------------------------------------------------------------------------

_submenu() {
    local title="$1"; shift
    local -a opts=("$@")
    while true; do
        header "Vanilla WoW Client — ${title}"
        local action
        action=$(printf '%s\n' "${opts[@]}" "back" | gum choose --header "Choose an action:") || true
        [[ -z "$action" || "$action" == "back" ]] && return
        case "$action" in
            install-deps)    engine_foreground install-deps ;;
            configure)       action_configure || true ;;
            discover-realm)  _discover_and_set || true ;;
            winecfg)         action_winecfg || true ;;
            add-instance)    action_add_instance || true ;;
            list-instances)  engine_foreground list-instances ;;
            edit-instance)   action_edit_instance || true ;;
            remove-instance) action_remove_instance || true ;;
            launch)          action_launch || true ;;
            stop)            action_stop || true ;;
            stop-all)        engine_foreground stop-all ;;
        esac
        echo ""
    done
}

main() {
    resolve_engine
    gum style --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        "dark-portal" "vanilla WoW multibox client — the Dark Portal"
    while true; do
        local category
        category=$(gum choose "Setup" "Instances" "Launch" "Status" "Quit" --header "Choose a category:") || true
        [[ -z "$category" || "$category" == "Quit" ]] && { gum style --faint "Bye."; exit 0; }
        case "$category" in
            Setup)     _submenu "Setup"     install-deps configure discover-realm winecfg ;;
            Instances) _submenu "Instances" add-instance list-instances edit-instance remove-instance ;;
            Launch)    _submenu "Launch"    launch stop stop-all ;;
            Status)    engine_foreground status ;;
        esac
    done
}

main "$@"

#!/usr/bin/env bash
# Standalone export (export.sh): tools the slimmed setup.sh pre-installs.
# export-setup: node uv python
# -----------------------------------------------------------------------------
# bmad.sh
# Interactive TUI to manage BMAD-METHOD projects (https://github.com/bmad-code-org):
#   - Create a new project and install BMAD into it (interactive installer)
#   - Update the BMAD version inside an existing project (stable / prerelease)
#   - Delete a whole project folder from disk (git-safety check + typed confirm)
#
# A JSON registry (managed with python3, a BMAD prerequisite) remembers the
# projects it manages, so ones created in unusual folders are still found; a
# folder scan can fold in projects created elsewhere.
#
# Called by init.sh — expects gum to be available.
# BMAD needs: Node >= 20.12 (npx), Python >= 3.10, uv. Project home:
#   https://github.com/bmad-code-org/BMAD-METHOD   docs: https://docs.bmad-method.org
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers: ../_common in the repo, or alongside this script when exported.
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"
else
    COMMON_DIR="${SCRIPT_DIR}"
fi
if [[ ! -f "${COMMON_DIR}/ui.sh" ]]; then
    printf "\033[0;31m[ERROR] ui.sh not found in %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

BMAD_PKG="bmad-method"                # npx package (append @next for prerelease)
BMAD_MARKER_DIR="_bmad"              # dir BMAD creates in a project (its fingerprint)
REGISTRY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/scomp-link/bmad"
REGISTRY_FILE="${REGISTRY_DIR}/projects.json"
SCAN_DEPTH=5                          # how deep to look for */_bmad when scanning

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------

_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Open a path in the OS file manager (best-effort, non-blocking).
open_path() {
    if command -v xdg-open &>/dev/null; then xdg-open "$1" &>/dev/null &
    elif command -v open &>/dev/null; then open "$1" &>/dev/null || true
    fi
}

# Expand a leading ~ and print an absolute path (dir need not exist yet).
_abspath() {
    local p="${1/#\~/$HOME}"
    if [[ -d "$p" ]]; then (cd "$p" && pwd); else printf '%s' "$p"; fi
}

# True when $1 (dotted version) >= $2.
_ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

# Run an interactive command but keep this TUI alive on Ctrl-C (so the child
# gets the signal and we return to the menu). Returns the child's exit status.
run_foreground() {
    local rc=0
    trap ':' INT
    "$@" || rc=$?
    trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM
    return $rc
}

# Run `npx <pkg> install` inside a project directory (interactive passthrough).
_bmad_install_in() { ( cd "$1" && npx "$2" install ); }

# -----------------------------------------------------------------------------
# Dependency guardrails (checked, not force-installed — offer uv, guide the rest)
# -----------------------------------------------------------------------------

install_uv() {
    if command -v brew &>/dev/null; then
        run_foreground brew install uv
    else
        info "Installing uv via the official installer..."
        run_foreground bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    fi
    command -v uv &>/dev/null
}

require_bmad_deps() {
    local missing=0 v
    if command -v node &>/dev/null; then
        v="$(node -v 2>/dev/null | sed 's/^v//')"
        _ver_ge "${v:-0}" "20.12" || { warn "Node ${v} is too old — BMAD needs >= 20.12."; missing=1; }
    else
        warn "Node.js not found (need >= 20.12). Install via mise ('mise use -g node@lts') or your package manager."
        missing=1
    fi
    command -v npx &>/dev/null || { warn "npx not found (ships with Node.js)."; missing=1; }

    if command -v python3 &>/dev/null; then
        v="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
        _ver_ge "${v:-0}" "3.10" || warn "python3 is ${v}; BMAD wants >= 3.10 (uv can provide one)."
    else
        warn "python3 not found (need >= 3.10)."
        missing=1
    fi

    if ! command -v uv &>/dev/null; then
        warn "uv (Astral's Python package manager) not found."
        if gum confirm "Install uv now?"; then install_uv || { warn "uv install failed."; missing=1; }
        else missing=1; fi
    fi

    (( missing == 0 ))
}

# -----------------------------------------------------------------------------
# Registry (JSON, managed by python3 — a BMAD prerequisite, so no extra dep)
#   _reg add <path> <name> <iso>   _reg touch <path> <iso>
#   _reg remove <path>             _reg list  (TSV: path name created updated exists)
#   _reg prune
# -----------------------------------------------------------------------------

_reg() {
    REG_FILE="$REGISTRY_FILE" python3 - "$@" <<'PY'
import json, os, sys
path = os.environ["REG_FILE"]

def load():
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {"projects": []}

def save(d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, path)

d = load()
projs = d.setdefault("projects", [])
def find(p): return next((x for x in projs if x.get("path") == p), None)

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "add":
    p, name, now = sys.argv[2], sys.argv[3], sys.argv[4]
    e = find(p)
    if e:
        e["name"] = name; e["last_update"] = now
    else:
        projs.append({"path": p, "name": name, "created": now, "last_update": now})
    save(d)
elif cmd == "touch":
    p, now = sys.argv[2], sys.argv[3]
    e = find(p)
    if e:
        e["last_update"] = now; save(d)
elif cmd == "remove":
    d["projects"] = [x for x in projs if x.get("path") != sys.argv[2]]
    save(d)
elif cmd == "prune":
    d["projects"] = [x for x in projs if os.path.isdir(x.get("path", ""))]
    save(d)
elif cmd == "list":
    for x in projs:
        ex = "1" if os.path.isdir(x.get("path", "")) else "0"
        print("\t".join([x.get("path", ""), x.get("name", ""),
                         x.get("created", ""), x.get("last_update", ""), ex]))
PY
}

# Find project dirs (the parent of a _bmad folder) under a base directory.
scan_bmad_projects() {
    local base="$1" found
    found=$(find "$base" -maxdepth "$SCAN_DEPTH" -type d -name "$BMAD_MARKER_DIR" \
        ! -path "*/node_modules/*" ! -path "*/.git/*" 2>/dev/null \
        | sed "s|/${BMAD_MARKER_DIR}\$||" | sort -u)
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

# Pick a managed project: choose from the registry (existing only), or scan a
# folder and register the pick. Echoes the chosen project dir on stdout.
pick_project() {
    local path name created updated ex menu=()
    while IFS=$'\t' read -r path name created updated ex; do
        [[ -n "$path" && "$ex" == "1" ]] && menu+=("$path")
    done < <(_reg list)
    menu+=("↻ Scan a folder for BMAD projects…")

    local choice
    choice=$(printf '%s\n' "${menu[@]}" | gum choose --header "Select a BMAD project:") || return 1
    [[ -z "$choice" ]] && return 1

    if [[ "$choice" == ↻* ]]; then
        local base
        base=$(gum input --value "." --header "Folder to scan for BMAD projects:") || return 1
        base="$(_abspath "${base:-.}")"
        [[ -d "$base" ]] || { warn "Not a folder: ${base}"; return 1; }
        local found
        found=$(scan_bmad_projects "$base") || { warn "No BMAD projects under ${base} (depth ${SCAN_DEPTH})."; return 1; }
        choice=$(printf '%s\n' "$found" | gum choose --header "BMAD projects found:") || return 1
        [[ -z "$choice" ]] && return 1
        _reg add "$choice" "$(basename "$choice")" "$(_now)"   # remember it
    fi
    printf '%s' "$choice"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_create() {
    header "Create a BMAD project"
    require_bmad_deps || { warn "Missing prerequisites — resolve the above and retry."; return; }

    local name parent dir
    name=$(gum input --header "Project name (folder to create):" --placeholder "my-bmad-project") || return
    [[ -z "$name" ]] && { gum style --faint "Cancelled."; return; }
    parent=$(gum input --value "." --header "Parent directory (created if missing):") || return
    dir="$(_abspath "${parent:-.}")/${name}"

    if [[ -e "$dir" ]]; then
        if [[ -d "$dir/$BMAD_MARKER_DIR" ]]; then
            warn "${dir} already looks like a BMAD project. Use 'Update' instead."
            return
        fi
        gum confirm "${dir} already exists. Install BMAD into it anyway?" || return
    fi
    mkdir -p "$dir" || { warn "Could not create ${dir}."; return; }

    header "Installing BMAD"
    info "Running 'npx ${BMAD_PKG} install' in ${dir} (follow its prompts)…"
    run_foreground _bmad_install_in "$dir" "$BMAD_PKG" || true

    if [[ -d "$dir/$BMAD_MARKER_DIR" ]]; then
        _reg add "$dir" "$name" "$(_now)"
        success "Created and registered: ${dir}"
        open_path "$dir" 2>/dev/null || true
    else
        warn "No ${BMAD_MARKER_DIR}/ found in ${dir} — install may have been cancelled. Not registered."
    fi
}

action_update() {
    header "Update BMAD in a project"
    require_bmad_deps || { warn "Missing prerequisites — resolve the above and retry."; return; }

    local dir; dir=$(pick_project) || { gum style --faint "Cancelled."; return; }
    [[ -d "$dir/$BMAD_MARKER_DIR" ]] || warn "No ${BMAD_MARKER_DIR}/ in ${dir} — the installer will treat this as a fresh install."

    local channel pkg
    channel=$(gum choose "stable" "prerelease (@next)" --header "Which BMAD version?") || return
    [[ "$channel" == prerelease* ]] && pkg="${BMAD_PKG}@next" || pkg="$BMAD_PKG"

    header "Updating BMAD"
    info "Running 'npx ${pkg} install' in ${dir} (it detects the existing install)…"
    run_foreground _bmad_install_in "$dir" "$pkg" || true
    _reg add "$dir" "$(basename "$dir")" "$(_now)"   # upsert + refresh timestamp
    success "Update finished for ${dir}"
}

# Print git-backed-up status for a directory (advisory; always returns 0).
git_safety_report() {
    local dir="$1"
    if [[ ! -d "$dir/.git" ]]; then
        warn "Not a git repository — nothing here is backed up by git."
        return 0
    fi
    local dirty ahead
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null || true)
    [[ -n "$dirty" ]] && warn "Uncommitted changes: $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') file(s)."
    if [[ -z "$(git -C "$dir" remote 2>/dev/null)" ]]; then
        warn "No git remote — commits live only on this disk."
    else
        # wc -l (not grep -c) so an empty result stays 0 under `set -o pipefail`.
        ahead=$(git -C "$dir" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
        (( ahead > 0 )) && warn "${ahead} commit(s) not pushed to any remote."
        [[ -z "$dirty" && "${ahead:-0}" -eq 0 ]] && success "Clean and fully pushed — safe to delete."
    fi
    return 0
}

action_delete() {
    header "Delete a BMAD project"
    local dir; dir=$(pick_project) || { gum style --faint "Cancelled."; return; }
    local name; name="$(basename "$dir")"

    info "Target: ${dir}  ($(du -sh "$dir" 2>/dev/null | awk '{print $1}' || echo '?'))"
    git_safety_report "$dir"

    warn "This permanently deletes the ENTIRE folder ${dir} and everything under it."
    local typed
    typed=$(gum input --header "Type the project name '${name}' to confirm deletion (blank to cancel):") || return
    if [[ "$typed" != "$name" ]]; then
        gum style --faint "Name did not match — nothing deleted."
        return
    fi

    rm -rf "$dir" && { _reg remove "$dir"; success "Deleted ${dir} and removed it from the registry."; } \
        || warn "Deletion failed for ${dir}."
}

action_list() {
    header "Managed BMAD projects"
    local any=0 path name created updated ex tag
    while IFS=$'\t' read -r path name created updated ex; do
        [[ -z "$path" ]] && continue
        any=1
        [[ "$ex" == "1" ]] && tag="" || tag="  (missing)"
        info "${name} — ${path}${tag}   [updated ${updated}]"
    done < <(_reg list)
    (( any )) || { info "No projects registered yet. Create one, or use Update/Delete to scan and register."; return; }
    if _reg list | grep -q $'\t0$'; then
        gum confirm "Some registered folders no longer exist. Prune them from the registry?" \
            && { _reg prune; success "Registry pruned."; }
    fi
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------

main() {
    while true; do
        header "BMAD project manager"
        local action
        action=$(gum choose \
            "Create a new project" \
            "Update BMAD in a project" \
            "Delete a project" \
            "List managed projects" \
            "Quit" \
            --header "What do you want to do?") || exit 0
        case "$action" in
            "Create a new project")     action_create ;;
            "Update BMAD in a project") action_update ;;
            "Delete a project")         action_delete ;;
            "List managed projects")    action_list ;;
            "Quit"|"")                  exit 0 ;;
        esac
    done
}

main "$@"

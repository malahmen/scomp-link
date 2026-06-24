#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# akinn_tui.sh — gum front-end for Akinn (Automated Kubernetes Installation for
# New Nodes).
#
# Akinn itself (akinn.sh) is a standalone, gum-free, POSIX node provisioner that
# runs AS ROOT ON the target Ubuntu / Raspberry Pi node. It is fully flag-driven
# and asks the user nothing — so it needs no TUI and is never modified or
# overwritten by this script. This front-end only helps an operator discover and
# assemble the correct flag invocation, then hands off to the real akinn.sh.
#
# Two ways to use Akinn:
#   1. This TUI  — figure out which flags you need, then run / print them.
#   2. Directly — `sh akinn.sh -m node1 -v v1.30 ...` for experienced users / CI.
#
# Note: akinn provisions the machine it runs on. Run this TUI ON the node you
# want to turn into a master/worker (or use "print" and paste the command there).
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_DIR="${SCRIPT_DIR}/../_common"
if [[ ! -d "$COMMON_DIR" ]]; then
    printf "\033[0;31m[ERROR] _common directory not found at %s\033[0m\n" "$COMMON_DIR" >&2
    exit 1
fi
# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"

command -v gum  &>/dev/null || { echo "[error] gum is required. Run setup.sh first." >&2; exit 1; }
command -v git  &>/dev/null || error_exit "git is required to fetch akinn: apt install git / brew install git"
command -v curl &>/dev/null || error_exit "curl is required to fetch version lists."

# -----------------------------------------------------------------------------
# Locate / fetch the akinn repository.
#
# Resolution order:
#   1. $AKINN_DIR              — explicit override (a checkout you control)
#   2. sibling dev checkout    — _sh_scripts/akinn next to scomp-link
#   3. local cache             — ~/.cache/scomp-link/akinn (clone target)
# -----------------------------------------------------------------------------

AKINN_REPO="${AKINN_REPO:-https://github.com/malahmen/akinn.git}"
AKINN_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/scomp-link/akinn"
# scripts/akinn -> scripts -> scomp-link -> _sh_scripts ; akinn sits beside scomp-link
_AKINN_SIBLING="$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || true)/akinn"

resolve_akinn() {
    if [[ -n "${AKINN_DIR:-}" && -f "${AKINN_DIR}/akinn.sh" ]]; then
        info "Using akinn from \$AKINN_DIR: ${AKINN_DIR}"
        return
    fi

    if [[ -f "${_AKINN_SIBLING}/akinn.sh" ]]; then
        AKINN_DIR="$_AKINN_SIBLING"
        info "Using local akinn checkout: ${AKINN_DIR}"
        return
    fi

    if [[ -f "${AKINN_CACHE}/akinn.sh" ]]; then
        AKINN_DIR="$AKINN_CACHE"
        info "Using cached akinn: ${AKINN_DIR}"
        if [[ -d "${AKINN_CACHE}/.git" ]] && gum confirm "Update akinn (git pull)?"; then
            gum spin --spinner dot --title "Updating akinn..." -- \
                git -C "$AKINN_DIR" pull --ff-only \
                || warn "Update failed; using the existing copy."
        fi
        return
    fi

    # Nothing found — clone it.
    local repo
    repo=$(gum input --header "akinn repository URL:" --value "$AKINN_REPO") || true
    [[ -z "$repo" ]] && error_exit "No repository URL provided."
    mkdir -p "$(dirname "$AKINN_CACHE")"
    gum spin --spinner dot --title "Cloning akinn..." -- \
        git clone --depth 1 "$repo" "$AKINN_CACHE" \
        || error_exit "Failed to clone akinn from ${repo}"
    AKINN_DIR="$AKINN_CACHE"
    success "akinn cloned to ${AKINN_DIR}"
}

# Source akinn's own URL + regex definitions so the version lists we present are
# exactly the ones akinn validates against — they can never drift out of sync.
load_akinn_defs() {
    # shellcheck disable=SC1090,SC1091
    source "${AKINN_DIR}/constants.sh"   # K_RELEASES, CRDS_RELEASES, ...
    # shellcheck disable=SC1090,SC1091
    source "${AKINN_DIR}/regex.sh"       # re_kver, re_crds_ver, ...
}

# -----------------------------------------------------------------------------
# Version pickers (reuse akinn's URLs + regexes via the env-passed definitions).
# -----------------------------------------------------------------------------

# Kubernetes: akinn's apt repo path is built from the MINOR version
# (pkgs.k8s.io/.../stable:/v1.30/deb/). A full patch tag like v1.30.2 would
# produce an invalid repo URL, so we collapse to minor versions here.
#
# We try akinn's own re_kver first (so the list matches what akinn validates),
# then fall back to bare semver tags — GitHub's releases page dropped the
# "Kubernetes vX.Y.Z" wording the original regex relied on, so the strict match
# can come back empty on the current markup.
choose_k_version() {
    local versions
    versions=$(K_RELEASES="$K_RELEASES" RE="$re_kver" gum spin --spinner dot \
        --title "Fetching Kubernetes versions..." -- \
        bash -c '
            out=$(curl -s "$K_RELEASES")
            mins=$(printf "%s" "$out" | grep -Eo "$RE" | sed "s/Kubernetes //")
            # Fallback: bare v1.2.3 tags when the strict regex finds nothing.
            [ -z "$mins" ] && mins=$(printf "%s" "$out" | grep -Eo "v[0-9]+\.[0-9]+\.[0-9]+")
            printf "%s\n" "$mins" | sed -E "s/(v[0-9]+\.[0-9]+)\.[0-9]+/\1/" | sort -ru
        ') || versions=""

    if [[ -z "$versions" ]]; then
        warn "Could not fetch the Kubernetes version list — enter one manually."
        gum input --header "Kubernetes version (minor, e.g. v1.30):" --placeholder "v1.30"
        return
    fi
    printf '%s\n' "$versions" | gum choose --header "Kubernetes version (minor):" --height 12
}

# Calico CRDs: the manifest URL uses the full release tag, so present full tags.
choose_crds_version() {
    local versions
    versions=$(CRDS_RELEASES="$CRDS_RELEASES" RE="$re_crds_ver" gum spin --spinner dot \
        --title "Fetching Calico (CRDs) versions..." -- \
        bash -c 'curl -s "$CRDS_RELEASES" | grep -Eo "$RE" | sed "s/release-//" | sort -ru') || versions=""

    if [[ -z "$versions" ]]; then
        warn "Could not fetch the Calico version list — enter one manually."
        gum input --header "Calico CRDs version (e.g. v3.25.2):" --placeholder "v3.25.2"
        return
    fi
    printf '%s\n' "$versions" | gum choose --header "Calico (CRDs) version:" --height 12
}

# -----------------------------------------------------------------------------
# Flag builders. Each populates the global FLAGS array.
# akinn parses -l/-i/-p/-t/-h only AFTER it has seen -w, so the node-type flag
# is always emitted first.
# -----------------------------------------------------------------------------

DEFAULT_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

build_master() {
    FLAGS=()
    local name arch version crds cidr ip

    name=$(gum input --header "Master node name (hostname):" --placeholder "k8s-master-1") || return 1
    [[ -z "$name" ]] && { warn "Node name is required."; return 1; }

    arch=$(gum input --header "Architecture:" --value "$DEFAULT_ARCH") || return 1
    [[ -z "$arch" ]] && arch="$DEFAULT_ARCH"

    version=$(choose_k_version) || return 1
    [[ -z "$version" ]] && { warn "Kubernetes version is required."; return 1; }

    crds=$(choose_crds_version) || return 1
    [[ -z "$crds" ]] && { warn "Calico CRDs version is required."; return 1; }

    cidr=$(gum input --header "Pod network CIDR:" --value "10.244.0.0/16") || return 1
    [[ -z "$cidr" ]] && cidr="10.244.0.0/16"

    # akinn defaults the advertise address to the node's first IP (hostname -I);
    # leave blank to use that, or set one explicitly (akinn honours -i here now).
    ip=$(gum input --header "API server advertise IP (blank = node's first IP):" \
        --placeholder "192.168.1.10") || return 1

    FLAGS=( -m "$name" -a "$arch" -v "$version" -c "$crds" -n "$cidr" )
    [[ -n "$ip" ]] && FLAGS+=( -i "$ip" )
}

build_worker() {
    FLAGS=()
    local name arch version ip port muser login token hash

    name=$(gum input --header "Worker node name (hostname):" --placeholder "k8s-worker-1") || return 1
    [[ -z "$name" ]] && { warn "Node name is required."; return 1; }

    arch=$(gum input --header "Architecture:" --value "$DEFAULT_ARCH") || return 1
    [[ -z "$arch" ]] && arch="$DEFAULT_ARCH"

    version=$(choose_k_version) || return 1
    [[ -z "$version" ]] && { warn "Kubernetes version is required."; return 1; }

    ip=$(gum input --header "Master node IP address:" --placeholder "192.168.1.10") || return 1
    [[ -z "$ip" ]] && { warn "Master node IP is required."; return 1; }

    port=$(gum input --header "Master node API port:" --value "6443") || return 1
    [[ -z "$port" ]] && port="6443"

    # SSH user on the MASTER (akinn -u). Defaults to this node's user, but the
    # master's account is often different — confirm it.
    muser=$(gum input --header "SSH user on the master node:" --value "$(whoami)") || return 1
    [[ -z "$muser" ]] && muser="$(whoami)"

    login=$(prompt_file "Master node SSH password file:" "$HOME/.akinn/master_login") || return 1
    [[ -z "$login" ]] && { warn "Master login file is required (worker copies kubeconfig over scp)."; return 1; }

    token=$(prompt_file "Join token file (from the master):" "$HOME/master_node/token") || return 1
    [[ -z "$token" ]] && { warn "Token file is required."; return 1; }

    hash=$(prompt_file "Discovery CA hash file (from the master):" "$HOME/master_node/hash") || return 1
    [[ -z "$hash" ]] && { warn "Hash file is required."; return 1; }

    FLAGS=( -w "$name" -a "$arch" -v "$version" -i "$ip" -p "$port" \
            -u "$muser" -l "$login" -t "$token" -h "$hash" )
}

# prompt_file <header> <default-path> — path input that expands ~ and warns
# (without blocking) on a missing file, leaving akinn to report the
# authoritative error at run time.
prompt_file() {
    local header="$1" default="$2" path
    path=$(gum input --header "$header" --value "$default") || return 1
    [[ -z "$path" ]] && { echo ""; return 0; }
    path="${path/#\~/$HOME}"
    [[ ! -f "$path" ]] && warn "File not found yet: ${path} (akinn will re-check at run time)."
    echo "$path"
}

# -----------------------------------------------------------------------------
# Hand-off
# -----------------------------------------------------------------------------

run_or_print() {
    [[ "${#FLAGS[@]}" -eq 0 ]] && return 0

    echo
    gum style --foreground "${CYAN:-212}" --bold "Resulting akinn command:"
    gum style --border rounded --padding "0 1" --foreground "${GREEN:-82}" \
        "sh akinn.sh ${FLAGS[*]}"
    echo

    local choice
    choice=$(gum choose --header "What now?" \
        "run    — execute on THIS machine now (provisions it as root)" \
        "print  — just show the command to run on the node yourself" \
        "back   — discard and return to the menu") || return 0

    case "$choice" in
        run*)
            gum confirm "akinn will modify THIS system as root (swap, apt, kubeadm). Continue?" \
                || { warn "Aborted — nothing changed."; return 0; }
            info "Handing off to akinn: ${AKINN_DIR}/akinn.sh"
            # akinn self-elevates with sudo and uses /bin/sh internally.
            sh "${AKINN_DIR}/akinn.sh" "${FLAGS[@]}" \
                || warn "akinn exited with errors (see output above)."
            ;;
        print*)
            info "Run this ON the target node, from the akinn directory:"
            gum style --foreground "${CYAN:-212}" "  cd ${AKINN_DIR}"
            gum style --foreground "${CYAN:-212}" "  sh akinn.sh ${FLAGS[*]}"
            ;;
        *) return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    header "Akinn — Kubernetes Node Installer"
    resolve_akinn
    load_akinn_defs

    while true; do
        local node
        node=$(gum choose \
            --header "What kind of node is THIS machine becoming?" \
            "master — initialize a new control-plane node" \
            "worker — join this node to an existing cluster" \
            "── quit") || true

        [[ -z "$node" || "$node" == "── quit" ]] && { gum style --faint "Bye."; exit 0; }

        FLAGS=()
        case "$node" in
            master*) build_master && run_or_print || warn "Master setup cancelled." ;;
            worker*) build_worker && run_or_print || warn "Worker setup cancelled." ;;
        esac

        echo
        gum confirm "Back to the menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main

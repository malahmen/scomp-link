#!/usr/bin/env bash
# description: Install and manage LM Studio (Flatpak), headless service support
# Standalone export (export.sh): no extra setup deps — LM Studio app + display deps are handled at runtime.
# -----------------------------------------------------------------------------
# lmstudio.sh
# Interactive TUI for installing and managing LM Studio (Flatpak) so that the
# `lms` CLI works out of the box, with an optional headless boot-time service.
#
# Background (why this script exists):
#   LM Studio's Flatpak has a static `persistent=.lmstudio` permission that
#   sandboxes `~/.lmstudio` to `~/.var/app/ai.lmstudio.lm-studio/.lmstudio`.
#   If "LM Studio Home" ever gets pointed at the real `~/.lmstudio` (e.g. a
#   leftover from a prior non-Flatpak install), the app's identity/passkey
#   machinery still resolves to the sandboxed copy while other state resolves
#   to the real one — two divergent passkeys, and `lms` fails with
#   "Invalid passkey for lms CLI client". Granting the sandbox full
#   `--filesystem=home` access (done unconditionally by cmd_install below)
#   makes path resolution consistent everywhere and prevents this outright.
#
# Sourced helpers (scripts/_common/):
#   ui.sh — header/info/success/warn/error_exit
#
# Config: ~/.config/lmstudio-tui/lmstudio.conf (XDG-style, key=value)
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../_common" ]]; then
    COMMON_DIR="${SCRIPT_DIR}/../_common"   # scomp-link repo layout
else
    COMMON_DIR="${SCRIPT_DIR}"              # exported standalone: deps sit alongside
fi

# shellcheck source=../_common/ui.sh
source "${COMMON_DIR}/ui.sh"
# shellcheck source=../_common/deps.sh
source "${COMMON_DIR}/deps.sh"   # _ensure_pkg (dnf/apt/rpm-ostree), _require_sudo_or_instruct

trap 'echo ""; gum style --faint "Interrupted."; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

APP_ID="ai.lmstudio.lm-studio"
FLATHUB_REPO="https://flathub.org/repo/flathub.flatpakrepo"
LMSTUDIO_HOME="${HOME}/.lmstudio"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lmstudio-tui"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/lmstudio.conf"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
XVFB_UNIT="${SYSTEMD_USER_DIR}/lmstudio-xvfb.service"
APP_UNIT="${SYSTEMD_USER_DIR}/lmstudio.service"
WRAPPER_SCRIPT="${CONFIG_DIR}/lmstudio-headless.sh"

mkdir -p "$CONFIG_DIR"

# -----------------------------------------------------------------------------
# Config persistence
# -----------------------------------------------------------------------------

cfg_load() {
    INSTALL_SCOPE="user"
    XVFB_DISPLAY="99"
    SERVICE_ENABLED="false"

    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

cfg_save() {
    cat > "$CONFIG_FILE" <<EOF
INSTALL_SCOPE="${INSTALL_SCOPE}"
XVFB_DISPLAY="${XVFB_DISPLAY}"
SERVICE_ENABLED="${SERVICE_ENABLED}"
EOF
}

# -----------------------------------------------------------------------------
# Dependency helpers
# -----------------------------------------------------------------------------

# flatpak + Xvfb via the shared, rpm-ostree-aware _ensure_pkg (deps.sh). Using the
# common helper is what lets the headless path work on immutable Fedora Atomic
# hosts (Bazzite) — the previous private dnf/apt-only resolver aborted there.
_ensure_flatpak() {
    command -v flatpak &>/dev/null && { info "flatpak found: $(flatpak --version)"; return 0; }
    info "flatpak not found. Installing..."
    _ensure_pkg flatpak flatpak flatpak
}

_ensure_xvfb() {
    command -v Xvfb &>/dev/null && { info "Xvfb found: $(command -v Xvfb)"; return 0; }
    info "Xvfb not found. Installing (needed to run LM Studio headless)..."
    _ensure_pkg Xvfb xorg-x11-server-Xvfb xvfb
}

_ensure_flathub_remote() {
    if [[ "$INSTALL_SCOPE" == "user" ]]; then
        flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO"
    else
        _require_sudo_or_instruct "Adding the flathub remote system-wide" \
            "sudo flatpak remote-add --if-not-exists flathub $FLATHUB_REPO"
        sudo flatpak remote-add --if-not-exists flathub "$FLATHUB_REPO"
    fi
}

_app_installed() {
    flatpak list --app --columns=application 2>/dev/null | grep -qx "$APP_ID"
}

# -----------------------------------------------------------------------------
# install — core steps
# -----------------------------------------------------------------------------

_install_app() {
    if _app_installed; then
        info "LM Studio (${APP_ID}) is already installed."
        return
    fi

    info "Installing LM Studio via Flatpak (${INSTALL_SCOPE} scope)..."
    if [[ "$INSTALL_SCOPE" == "user" ]]; then
        gum spin --spinner dot --title "flatpak install --user flathub ${APP_ID}..." -- \
            flatpak install --user -y flathub "$APP_ID" \
            || error_exit "flatpak install failed."
    else
        _require_sudo_or_instruct "Installing LM Studio system-wide" \
            "sudo flatpak install -y flathub $APP_ID"
        gum spin --spinner dot --title "flatpak install flathub ${APP_ID}..." -- \
            sudo flatpak install -y flathub "$APP_ID" \
            || error_exit "flatpak install failed."
    fi
    success "LM Studio installed."
}

# The fix for the passkey bug: grant the sandbox full home access so every
# code path inside the app (identity/passkey included) resolves the same
# `~/.lmstudio` regardless of any custom "LM Studio Home" setting.
_apply_sandbox_override() {
    info "Granting LM Studio's sandbox consistent home-directory access..."
    flatpak override --user --filesystem=home "$APP_ID" \
        || error_exit "flatpak override failed."
    success "Sandbox override applied (filesystems=home)."
}

# Launches the app against a throwaway Xvfb display just long enough for its
# first-run bootstrap (copies the lms binary into ~/.lmstudio/bin, patches
# shell rc files, generates the passkey) to complete, then kills it.
_bootstrap_cli() {
    if [[ -x "${LMSTUDIO_HOME}/bin/lms" ]] && "${LMSTUDIO_HOME}/bin/lms" status &>/dev/null; then
        info "lms CLI already bootstrapped and talking to a running server."
        return
    fi

    _ensure_xvfb

    local bootstrap_display=":77"
    info "Starting a throwaway headless display for first-run setup..."
    Xvfb "$bootstrap_display" -screen 0 1280x1024x24 -nolisten tcp &
    local xvfb_pid=$!
    sleep 1

    info "Launching LM Studio once to complete first-run bootstrap..."
    DISPLAY="$bootstrap_display" flatpak run "$APP_ID" &
    local app_pid=$!

    if ! gum spin --spinner dot --title "Waiting for lms CLI to become available..." -- \
        bash -c '
            for i in $(seq 1 60); do
                [[ -x "'"${LMSTUDIO_HOME}"'/bin/lms" ]] && "'"${LMSTUDIO_HOME}"'/bin/lms" status &>/dev/null && exit 0
                sleep 1
            done
            exit 1
        '; then
        kill "$app_pid" 2>/dev/null || true
        kill "$xvfb_pid" 2>/dev/null || true
        error_exit "LM Studio did not finish first-run bootstrap in time. Try running 'lmstudio.sh install' again."
    fi

    flatpak kill "$APP_ID" 2>/dev/null || true
    kill "$xvfb_pid" 2>/dev/null || true
    sleep 1

    export PATH="${LMSTUDIO_HOME}/bin:$PATH"
    command -v lms &>/dev/null || warn "lms not yet on PATH for this shell — open a new terminal (bootstrap already patched your shell rc files)."
    success "lms CLI bootstrapped: $("${LMSTUDIO_HOME}/bin/lms" version 2>/dev/null | grep -m1 'lms' || echo 'ok')"
}

# -----------------------------------------------------------------------------
# ROCm GPU sandbox fix
# -----------------------------------------------------------------------------
# Background: LM Studio's Flatpak only requests `devices=dri`, which exposes
# /dev/dri (fine for Vulkan/OpenGL) but not /dev/kfd — the kernel interface
# ROCm compute needs. On a host with a ROCm-capable AMD GPU this makes LM
# Studio's bundled ROCm llama.cpp backend fail hardware survey with
# "No ROCm supported accelerators found!" even though the kernel driver and
# GPU both support it fine — /dev/kfd exists on the host, it's just invisible
# inside the sandbox. Flatpak has no finer-grained "just kfd" device knob, so
# the fix is `--device=all`, followed by an app restart so the new device
# list takes effect. Vulkan (used via /dev/dri) is unaffected either way.

_host_has_rocm_capable_gpu() {
    [[ -e /dev/kfd ]] || return 1
    lspci -k 2>/dev/null | grep -qi 'amdgpu'
}

_rocm_sandbox_fix_applied() {
    flatpak override --user --show "$APP_ID" 2>/dev/null | grep -qE '^devices=.*\ball\b'
}

_apply_rocm_sandbox_override() {
    info "Granting LM Studio's sandbox access to /dev/kfd (ROCm compute)..."
    flatpak override --user --device=all "$APP_ID" \
        || error_exit "flatpak override failed."
    success "Sandbox override applied (devices=all)."
}

cmd_fix_rocm() {
    header "LM Studio — ROCm sandbox fix"

    _app_installed || error_exit "LM Studio is not installed. Run 'install' first."

    if ! _host_has_rocm_capable_gpu; then
        info "No ROCm-capable AMD GPU detected on this host (no /dev/kfd, or amdgpu not bound) — nothing to fix."
        return
    fi

    if _rocm_sandbox_fix_applied; then
        success "Fix already applied — sandbox already has full device access."
        return
    fi

    warn "LM Studio's sandbox can't see /dev/kfd, so its ROCm backend can't detect this GPU (Vulkan still works fine in the meantime)."
    gum confirm "Apply the fix now (flatpak override --device=all)?" || { info "Skipped."; return; }

    _apply_rocm_sandbox_override

    local running="false"
    flatpak ps --columns=application 2>/dev/null | grep -qx "$APP_ID" && running="true"
    local service_active="false"
    systemctl --user is-active --quiet lmstudio.service 2>/dev/null && service_active="true"

    if [[ "$running" == "true" || "$service_active" == "true" ]]; then
        gum confirm "LM Studio needs to restart to pick up the new sandbox permissions. Restart it now?" || {
            warn "Restart LM Studio manually (or 'systemctl --user restart lmstudio.service') for the fix to take effect."
            return
        }

        if [[ "$service_active" == "true" ]]; then
            systemctl --user restart lmstudio.service
        else
            flatpak kill "$APP_ID" 2>/dev/null || true
            sleep 1
            nohup flatpak run "$APP_ID" >/dev/null 2>&1 &
            disown
        fi
        success "LM Studio restarted. To actually use ROCm for a model, select the engine with:"
        info "  lms runtime select llama.cpp-linux-x86_64-amd-rocm-avx2 --latest"
    else
        info "LM Studio isn't currently running — the fix will take effect next launch."
    fi
}

# -----------------------------------------------------------------------------
# service — headless boot-time autostart (Xvfb + LM Studio, no login required)
# -----------------------------------------------------------------------------

_write_wrapper_script() {
    cat > "$WRAPPER_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:${XVFB_DISPLAY}
export PATH="${LMSTUDIO_HOME}/bin:\$PATH"

flatpak run ${APP_ID} &
app_pid=\$!

# Guarantee the local API server is up regardless of the app's own
# "start server on launch" setting.
for i in \$(seq 1 60); do
    if lms status &>/dev/null; then
        lms server start &>/dev/null || true
        break
    fi
    sleep 1
done

wait "\$app_pid"
EOF
    chmod +x "$WRAPPER_SCRIPT"
}

_write_systemd_units() {
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "$XVFB_UNIT" <<EOF
[Unit]
Description=Headless X server for LM Studio

[Service]
ExecStart=/usr/bin/Xvfb :${XVFB_DISPLAY} -screen 0 1280x1024x24 -nolisten tcp
Restart=on-failure

[Install]
WantedBy=default.target
EOF

    cat > "$APP_UNIT" <<EOF
[Unit]
Description=LM Studio (headless, autostart)
After=lmstudio-xvfb.service network-online.target
Requires=lmstudio-xvfb.service
Wants=network-online.target

[Service]
ExecStart=${WRAPPER_SCRIPT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

cmd_service_enable() {
    header "LM Studio — Enable headless boot service"
    cfg_load

    _ensure_xvfb
    _apply_sandbox_override

    local display
    display=$(gum input --value "${XVFB_DISPLAY}" --header "Xvfb display number to use:") || true
    XVFB_DISPLAY="${display:-$XVFB_DISPLAY}"

    _write_wrapper_script
    _write_systemd_units

    systemctl --user daemon-reload
    systemctl --user enable lmstudio-xvfb.service lmstudio.service

    if gum confirm "Enable lingering so this starts at boot even when you're not logged in? (recommended)"; then
        loginctl enable-linger "$(whoami)" \
            || warn "Could not enable linger (needs polkit permission for your own user, or run: sudo loginctl enable-linger $(whoami))"
    else
        warn "Skipped linger — the service will only start once you log in."
    fi

    info "Starting services now..."
    systemctl --user restart lmstudio-xvfb.service
    sleep 2
    systemctl --user restart lmstudio.service

    if ! gum spin --spinner dot --title "Waiting for LM Studio server to come up..." -- \
        bash -c 'export PATH="'"${LMSTUDIO_HOME}"'/bin:$PATH"; for i in $(seq 1 60); do lms status &>/dev/null && exit 0; sleep 1; done; exit 1'; then
        warn "Server did not respond yet — check: journalctl --user -u lmstudio.service -f"
    else
        success "LM Studio is running headless. lms status:"
        PATH="${LMSTUDIO_HOME}/bin:$PATH" lms status || true
    fi

    SERVICE_ENABLED="true"
    cfg_save
    success "Headless service enabled. It will survive reboots (and logins, if linger is on)."
    info "Manage it with: systemctl --user {status|restart|stop} lmstudio.service"
}

cmd_service_disable() {
    header "LM Studio — Disable headless boot service"
    cfg_load

    systemctl --user stop lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    systemctl --user disable lmstudio.service lmstudio-xvfb.service 2>/dev/null || true

    if gum confirm "Also disable lingering for your user (only if nothing else relies on it)?"; then
        loginctl disable-linger "$(whoami)" 2>/dev/null || true
    fi

    SERVICE_ENABLED="false"
    cfg_save
    success "Headless service disabled. Unit files left in place under ${SYSTEMD_USER_DIR} — re-run 'service-enable' to turn it back on."
}

# -----------------------------------------------------------------------------
# cmd: install
# -----------------------------------------------------------------------------

cmd_install() {
    header "LM Studio — Install"
    cfg_load

    local scope
    scope=$(gum choose \
        "user  (recommended — no root needed)" \
        "system  (requires root)" \
        --header "Install scope:") || true
    [[ -z "$scope" ]] && error_exit "Install scope is required."
    case "$scope" in
        user*)   INSTALL_SCOPE="user" ;;
        system*) INSTALL_SCOPE="system" ;;
    esac

    _ensure_flatpak
    _ensure_flathub_remote
    _install_app

    # Applied unconditionally and BEFORE first launch — this is what prevents
    # the "Invalid passkey" bug from ever showing up on this machine.
    _apply_sandbox_override

    _bootstrap_cli

    cfg_save

    if gum confirm "Set up LM Studio to run as a background service, starting even without login?"; then
        cmd_service_enable
    else
        info "Skipping headless service. Launch normally with: flatpak run ${APP_ID}"
    fi

    success "Install complete."
}

# -----------------------------------------------------------------------------
# cmd: status
# -----------------------------------------------------------------------------

cmd_status() {
    header "LM Studio — Status"
    cfg_load

    gum style --foreground "${CYAN}" --bold "── Flatpak"
    if _app_installed; then
        flatpak info "$APP_ID" 2>/dev/null | head -5
    else
        warn "Not installed."
    fi

    gum style --foreground "${CYAN}" --bold "── Sandbox permissions"
    flatpak info --show-permissions "$APP_ID" 2>/dev/null | grep -E "^filesystems|^persistent|^devices" || warn "Could not read permissions."
    if _host_has_rocm_capable_gpu; then
        if _rocm_sandbox_fix_applied; then
            success "ROCm sandbox fix: applied."
        else
            warn "ROCm-capable AMD GPU detected but sandbox fix not applied. Run: lmstudio.sh fix-rocm"
        fi
    fi

    gum style --foreground "${CYAN}" --bold "── Headless service"
    if [[ -f "$APP_UNIT" ]]; then
        systemctl --user status lmstudio.service --no-pager 2>/dev/null | head -6 || true
        info "Linger: $(loginctl show-user "$(whoami)" -p Linger 2>/dev/null || echo unknown)"
    else
        info "Not configured. Run: lmstudio.sh service-enable"
    fi

    gum style --foreground "${CYAN}" --bold "── API server"
    if command -v lms &>/dev/null; then
        lms status 2>&1 || true
    else
        PATH="${LMSTUDIO_HOME}/bin:$PATH" "${LMSTUDIO_HOME}/bin/lms" status 2>&1 || warn "lms CLI not found."
    fi
}

# -----------------------------------------------------------------------------
# cmd: bench (Kamino item 15)
# -----------------------------------------------------------------------------
# How fast each local model runs on THIS host, through LM Studio's own server:
# generation (tokens/s, which on a unified-memory APU is set by memory
# bandwidth) and prefill (prompt tokens/s at a RAG-sized context, which is
# compute-bound and is what a long retrieved context waits on). One model is
# loaded at a time, at the context asked for, fully on the GPU; every figure is
# the median of several runs, after an untimed warm-up; each prompt starts with
# a unique tag so no cached prefix is reused. For a DENSE model every weight is
# read once per token, so its file size x tokens/s is the bandwidth it
# actually got - the figure the corelia report (Kamino local-models-2026-10-10)
# could only estimate. The host's load is checked first and recorded, as in
# speaches.sh's bench (item 8: a run beside a game came out 1.12x slow).
LM_URL="${SCOMP_LMSTUDIO_URL:-http://127.0.0.1:1234}"
LM_BENCH_SCHEMA="scomp-link/lmstudio-bench/1"
LM_BENCH_OUT="${SCOMP_LMSTUDIO_BENCH_OUT:-$HOME}"
LM_LOADAVG="${SCOMP_LMSTUDIO_LOADAVG:-/proc/loadavg}"
# A text file for the prefill prompt. Prefill speed does not depend on what
# the text says, so by default it is generated.
LM_BENCH_TEXT="${SCOMP_LMSTUDIO_BENCH_TEXT:-}"
LM_GEN_PROMPT="Write a detailed, practical explanation of how a write-ahead log makes a database crash-safe. Use plain prose."

# lms, wherever this install keeps it: ~/.lmstudio when install granted the
# sandbox the home folder, else the Flatpak's own copy, which only finds its
# key with HOME pointed at the sandbox (corelia, 2026-10-22).
_lms() {
    local sandbox="${HOME}/.var/app/${APP_ID}"
    if [[ -x "${LMSTUDIO_HOME}/bin/lms" ]]; then
        "${LMSTUDIO_HOME}/bin/lms" "$@"
    elif [[ -x "${sandbox}/.lmstudio/bin/lms" ]]; then
        HOME="$sandbox" "${sandbox}/.lmstudio/bin/lms" "$@"
    elif command -v lms &>/dev/null; then
        lms "$@"
    else
        return 127
    fi
}

_lm_median() { sort -g | awk '{v[NR]=$1} END {if (!NR) exit 1; print (NR % 2) ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2}'; }

# _lm_text <approx tokens> - a prompt of about that many tokens (~4 chars each)
_lm_text() {
    local chars=$(( $1 * 4 ))
    if [[ -n "$LM_BENCH_TEXT" && -r "$LM_BENCH_TEXT" ]]; then
        head -c "$chars" "$LM_BENCH_TEXT"
    else
        awk -v n="$chars" 'BEGIN {
            for (i = 1; out < n; i++) {
                s = sprintf("Section %d. The record of decision %d was kept beside the change it describes, so that the reason survives the people who made it. ", i, i * 7 % 997)
                printf "%s", s; out += length(s)
            }
        }'
    fi
}

# _lm_chat <model> <prompt file> <max tokens> -> "tok_s ttft prompt_tokens completion_tokens"
_lm_chat() {
    jq -n --arg m "$1" --rawfile p "$2" --argjson mt "$3" \
        '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $mt, temperature: 0, stream: false}' \
    | curl -fsS --max-time 3600 -H 'content-type: application/json' --data-binary @- "${LM_URL}/api/v0/chat/completions" \
    | jq -r '[.stats.tokens_per_second, .stats.time_to_first_token, .usage.prompt_tokens, .usage.completion_tokens] | map(. // "null") | @tsv'
}

_lm_gtt_used_gib() {
    local f
    for f in /sys/class/drm/card*/device/mem_info_gtt_used; do
        [[ -r "$f" ]] && { awk '{printf "%.1f", $1 / 1073741824}' "$f"; return; }
    done
    echo null
}

cmd_bench() {
    header "LM Studio - bench (${LM_URL})"
    command -v jq &>/dev/null || _ensure_pkg jq jq
    command -v curl &>/dev/null || _ensure_pkg curl curl
    local models_json
    models_json=$(curl -fsS --max-time 10 "${LM_URL}/api/v0/models" 2>/dev/null) \
        || { warn "LM Studio's server is not answering at ${LM_URL} (service-enable, or start it in the app)."; return 0; }

    local cpus load1 wine busy=false
    cpus=$(nproc 2>/dev/null || echo 0)
    load1=$(cut -d' ' -f1 "$LM_LOADAVG" 2>/dev/null || echo 0)
    wine=$(pgrep -fl '\.exe( |$)' 2>/dev/null | awk '{print $2}' | sort -u | paste -sd, - || true)
    if [[ -n "$wine" ]] || awk -v l="$load1" -v c="$cpus" 'BEGIN {exit !(l > c / 8)}'; then
        busy=true
        warn "The host is not idle: load ${load1} on ${cpus} CPUs${wine:+; running under Wine: ${wine}}."
        warn "Figures taken beside other work are not this host's."
        gum confirm "Bench anyway? (the report records it)" --default=false || return 0
    fi

    local -a all chosen
    mapfile -t all < <(jq -r '.data[] | select(.type == "llm" or .type == "vlm") | .id' <<< "$models_json")
    [[ ${#all[@]} -gt 0 ]] || { warn "No generation models installed."; return 0; }
    mapfile -t chosen < <(gum choose --no-limit --header "Models to bench (space selects, enter confirms):" "${all[@]}")
    [[ ${#chosen[@]} -gt 0 && -n "${chosen[0]}" ]] || { info "Nothing chosen."; return 0; }

    local loaded
    loaded=$(jq -r '[.data[] | select(.state == "loaded") | .id] | join(", ")' <<< "$models_json")
    if [[ -n "$loaded" ]]; then
        warn "Loaded now: ${loaded}. The bench unloads every model, one model at a time after it, and leaves none loaded."
        gum confirm "Unload them and bench?" --default=false || return 0
    fi

    local ctx repeats sizes
    ctx=$(gum input --value 32768 --header "Context length to load each model with:") || return 0
    repeats=$(gum input --value 3 --header "Timed runs of each measurement (the median is reported):") || return 0
    sizes=$(gum input --value "4000 16000" --header "Prefill prompt sizes, in tokens (a RAG-sized context):") || return 0
    [[ "$ctx" =~ ^[1-9][0-9]*$ && "$repeats" =~ ^[1-9][0-9]*$ && "$sizes" =~ ^[0-9\ ]+$ ]] \
        || { warn "Not numbers: ${ctx} / ${repeats} / ${sizes}"; return 0; }

    local inventory host when report work
    inventory=$(_lms ls --json 2>/dev/null || echo '[]')
    host="$(hostname -s 2>/dev/null || hostname)"
    when="$(date +%Y%m%d-%H%M)"
    report="${LM_BENCH_OUT}/lmstudio-bench-${host}-${when}.json"
    work="$(mktemp -d)"
    _lm_text 64 > "$work/gen.txt"; printf '%s' "$LM_GEN_PROMPT" >> "$work/gen.txt"

    local model t0 load_s line tok ttft pt med gtt size params arch size_n results="" err
    local -a gens pres
    for model in "${chosen[@]}"; do
        info "${model}: loading at ${ctx} context..."
        _lms unload --all >/dev/null 2>&1 || true
        t0=$(date +%s.%N)
        if ! err=$(_lms load "$model" --context-length "$ctx" --gpu max -y 2>&1); then
            warn "${model}: load failed"
            # The end of the message: ${err: -300} is empty when it is shorter.
            results+="${results:+,}$(jq -nc --arg m "$model" --arg e "$(tail -c 300 <<< "$err")" '{model: $m, error: ("load: " + $e)}')"
            continue
        fi
        load_s=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
        _lm_chat "$model" "$work/gen.txt" 32 >/dev/null || true      # warm-up, untimed

        gens=()
        for ((i = 1; i <= repeats; i++)); do
            { printf '[%s-%s] ' "$RANDOM$RANDOM" "$i"; cat "$work/gen.txt"; } > "$work/p.txt"
            line=$(_lm_chat "$model" "$work/p.txt" 300) || { warn "${model}: generation run ${i} failed"; continue; }
            read -r tok ttft pt _ <<< "$line"
            [[ "$tok" != null ]] && gens+=("$tok")
        done
        local gen_med="null"
        [[ ${#gens[@]} -gt 0 ]] && gen_med=$(printf '%s\n' "${gens[@]}" | _lm_median)

        local prefill="" n
        for n in $sizes; do
            pres=(); local ptok="null"
            for ((i = 1; i <= repeats; i++)); do
                { printf '[%s-%s]\nContext:\n' "$RANDOM$RANDOM" "$i"; _lm_text "$n"; printf '\n\nQuestion: in one sentence, what is this text about?'; } > "$work/p.txt"
                line=$(_lm_chat "$model" "$work/p.txt" 16) || { warn "${model}: prefill ${n} run ${i} failed"; continue; }
                read -r tok ttft pt _ <<< "$line"
                [[ "$ttft" != null && "$pt" != null ]] || continue
                ptok="$pt"
                pres+=("$(awk -v p="$pt" -v t="$ttft" 'BEGIN {if (t > 0) printf "%.1f", p / t}')")
            done
            med="null"; [[ ${#pres[@]} -gt 0 ]] && med=$(printf '%s\n' "${pres[@]}" | _lm_median)
            prefill+="${prefill:+,}$(jq -nc --argjson n "$n" --argjson pt "$ptok" --argjson m "$med" '{target_tokens: $n, prompt_tokens: $pt, tokens_per_second: $m}')"
            success "${model}: prefill ${ptok} tokens at ${med} tokens/s"
        done
        gtt=$(_lm_gtt_used_gib)
        size=$(jq -r --arg m "$model" '[.[] | select(.modelKey == $m)][0].sizeBytes // "null"' <<< "$inventory")
        params=$(jq -r --arg m "$model" '[.[] | select(.modelKey == $m)][0].paramsString // ""' <<< "$inventory")
        arch=$(jq -r --arg m "$model" '[.[] | select(.modelKey == $m)][0].architecture // ""' <<< "$inventory")
        size_n="$size"; [[ "$size_n" =~ ^[0-9]+$ ]] || size_n=null
        success "${model}: generation ${gen_med} tokens/s (median of ${#gens[@]}), load ${load_s} s, GTT ${gtt} GiB"
        results+="${results:+,}$(jq -nc --arg m "$model" --arg a "$arch" --arg p "$params" --argjson s "$size_n" \
            --argjson l "$load_s" --argjson g "$gen_med" --argjson runs "[$(IFS=,; echo "${gens[*]}")]" \
            --argjson pre "[$prefill]" --argjson gtt "$gtt" \
            '{model: $m, architecture: $a, params: $p, size_bytes: $s, load_seconds: $l,
              generation: {tokens_per_second: $g, runs: $runs},
              prefill: $pre, gtt_used_gib: $gtt,
              gb_per_second_if_dense: (if ($s != null and $g != null) then ($s * $g / 1e9 * 10 | round / 10) else null end)}')"
    done
    _lms unload --all >/dev/null 2>&1 || true
    rm -rf "$work"

    jq -n --arg schema "$LM_BENCH_SCHEMA" --arg host "$host" --arg when "$(date -Iseconds)" --arg url "$LM_URL" \
        --argjson cpus "${cpus:-0}" --argjson load1 "${load1:-0}" --arg wine "$wine" --argjson busy "$busy" \
        --argjson ctx "$ctx" --argjson repeats "$repeats" --argjson models "[$results]" \
        '{schema: $schema, host: $host, when: $when, server: $url,
          conditions: {cpus: $cpus, load1: $load1, wine: $wine, not_idle: $busy},
          context_length: $ctx, repeats: $repeats,
          note: "size_bytes is the model on disk, a vision projector included; gb_per_second_if_dense = size x generation rate, the bandwidth a dense model actually used (an MoE reads only its active experts, so for one it is not a bandwidth)",
          models: $models}' > "$report"
    success "Report: ${report}"
}

# -----------------------------------------------------------------------------
# cmd: uninstall
# -----------------------------------------------------------------------------

cmd_uninstall() {
    header "LM Studio — Uninstall"
    cfg_load

    gum confirm "This stops the headless service (if any) and removes the LM Studio Flatpak app. Continue?" \
        || { info "Cancelled."; return; }

    systemctl --user stop lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    systemctl --user disable lmstudio.service lmstudio-xvfb.service 2>/dev/null || true
    rm -f "$XVFB_UNIT" "$APP_UNIT" "$WRAPPER_SCRIPT"
    systemctl --user daemon-reload 2>/dev/null || true

    if _app_installed; then
        flatpak uninstall -y "$APP_ID" 2>/dev/null \
            || sudo flatpak uninstall -y "$APP_ID" \
            || warn "flatpak uninstall failed — remove manually."
    fi

    if [[ -d "$LMSTUDIO_HOME" ]]; then
        warn "Model files and data live at ${LMSTUDIO_HOME} (can be large)."
        if gum confirm "Delete ${LMSTUDIO_HOME} too?"; then
            rm -rf "$LMSTUDIO_HOME"
            success "Removed ${LMSTUDIO_HOME}."
        fi
    fi

    rm -f "$CONFIG_FILE"
    success "LM Studio uninstalled."
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install)          cmd_install ;;
            uninstall)        cmd_uninstall ;;
            status)           cmd_status ;;
            fix-rocm)         cmd_fix_rocm ;;
            service-enable)   cmd_service_enable ;;
            service-disable)  cmd_service_disable ;;
            bench)            cmd_bench ;;
            *) error_exit "Unknown command: $1 (expected: install|uninstall|status|fix-rocm|service-enable|service-disable|bench)" ;;
        esac
        exit 0
    fi

    while true; do
        header "LM Studio Manager"
        local action
        action=$(gum choose \
            "install" "status" "bench" "fix-rocm" "service-enable" "service-disable" "uninstall" "quit" \
            --header "Choose an action:") || true

        [[ -z "$action" || "$action" == "quit" ]] && { gum style --faint "Bye."; exit 0; }

        case "$action" in
            install)         cmd_install ;;
            status)          cmd_status ;;
            bench)           cmd_bench ;;
            fix-rocm)        cmd_fix_rocm ;;
            service-enable)  cmd_service_enable ;;
            service-disable) cmd_service_disable ;;
            uninstall)       cmd_uninstall ;;
        esac

        echo ""
        gum confirm "Back to main menu?" || { gum style --faint "Bye."; exit 0; }
    done
}

main "$@"

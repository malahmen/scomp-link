#!/usr/bin/env bash
# The Speaches front-end, driven through the gum stub. No network and nothing
# real is touched: podman, docker, systemctl, loginctl, journalctl, curl,
# firewall-cmd, sudo, kubectl, kind and uname are recording stubs, and the
# Quadlet and settings directories point into a temporary folder.
#
# What it protects:
#   - the podman target is opt-in, offered on Linux even before podman is
#     installed, and never on macOS;
#   - install writes the Quadlet unit, enables lingering, downloads exactly the
#     missing default models and offers to open the firewall port;
#   - a closed firewalld port reads as closed - firewall-cmd exits 1 on "no";
#   - settings survive a run and reach the unit; uninstall keeps the model
#     cache unless asked;
#   - the renderers: Quadlet, Kubernetes manifests and docker run arguments;
#   - bench (item 68): a busy host is said so and benches only if asked; the
#     cold run is on the smallest recording, after an unload, and the load is
#     cold minus warm on that file; medians, real-time factors and the TTS
#     audio length (from the WAV) reach a report that is valid JSON; a model
#     that cannot be unloaded leaves the load unmeasured, with the reason;
#     Whisper not loaded at all (404, and absent from /api/ps) counts as
#     cold; a short command spoken by Kokoro takes the cold run;
#   - status lists loaded models from 0.8.3's {"models": [...]}.
# shellcheck disable=SC2016
# Single-quoted heredoc stubs expand their own $1/$@ at run time, on purpose.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/speaches/speaches.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] && echo "kept: $T" || rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

# ---- stubs --------------------------------------------------------------------
mkdir -p "$T/bin" "$T/state"
for cmd in podman systemctl loginctl journalctl sudo kubectl kind docker; do
    cat > "$T/bin/$cmd" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
echo "$name $*" >> "$STUB_LOG"
case "$name $*" in
    "docker info"*)                      exit 1 ;;   # no Docker daemon: one target left
    "kubectl config get-contexts"*)      exit 0 ;;   # no contexts
    "kind get clusters"*)                exit 0 ;;
    "podman version"*)                   echo "5.2.0" ;;
    "loginctl show-user"*)               [[ -f "$STUB_STATE/linger" ]] && echo yes || echo no ;;
    "loginctl enable-linger"*)           : > "$STUB_STATE/linger" ;;
    "systemctl is-active --quiet firewalld") exit 0 ;;
    "systemctl --user is-active"*)       echo active ;;
    "sudo -n true")                      exit 0 ;;
    "sudo firewall-cmd --permanent --add-port"*) : > "$STUB_STATE/port-open" ;;
    "sudo "*)                            exit 0 ;;
esac
exit 0
EOF
done
cat > "$T/bin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
echo "firewall-cmd $*" >> "$STUB_LOG"
# The real one prints no and exits 1 for a closed port.
if [[ -f "$STUB_STATE/port-open" ]]; then echo yes; exit 0; fi
echo no; exit 1
EOF
cat > "$T/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_UNAME:-Linux}"
EOF
# curl answers like Speaches, keeping the installed models in a file.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
method=GET url="" out="" wfmt="" data=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w) wfmt="$2"; shift 2 ;;
        -d) data="$2"; shift 2 ;;
        -F|-H|--max-time) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
models="$STUB_STATE/models"; touch "$models"
case "$method $url" in
    "GET "*/health)        exit 0 ;;
    "GET "*/v1/models)     printf '{"data":['; sed 's/.*/{"id":"&","object":"model"}/' "$models" | paste -sd, -; printf ']}\n' ;;
    "POST "*/v1/models/*)  echo "${url#*/v1/models/}" >> "$models" ;;
    "DELETE "*/v1/models/*) grep -vxF "${url#*/v1/models/}" "$models" > "$models.new"; mv "$models.new" "$models" ;;
    # As 0.8.3 answers: plain strings, and only Whisper's models.
    "GET "*/api/ps)        printf '{"models":['; sed 's/.*/"&"/' "$STUB_STATE/loaded" 2>/dev/null | paste -sd, -; printf ']}\n' ;;
    # 204 for a loaded model, 404 "Model not found" for one that is not;
    # no-unload: a 500 that leaves it loaded.
    "DELETE "*/api/ps/*)
        model="${url#*/api/ps/}"; code=404
        if [[ -f "$STUB_STATE/no-unload" ]]; then code=500
        elif grep -qxF "$model" "$STUB_STATE/loaded" 2>/dev/null; then
            grep -vxF "$model" "$STUB_STATE/loaded" > "$STUB_STATE/loaded.new"; mv "$STUB_STATE/loaded.new" "$STUB_STATE/loaded"; code=204
        fi
        printf '%s' "$code"; exit 0 ;;
    # A transcription is 10 s while Whisper is not loaded, 2 s once it is.
    *"/v1/audio/transcriptions")
        echo '{"text":"hello there","language":"en","duration":60.0,"segments":[]}' > "$out"
        grep -qxF deepdml/faster-whisper-large-v3-turbo-ct2 "$STUB_STATE/loaded" 2>/dev/null \
            || { echo deepdml/faster-whisper-large-v3-turbo-ct2 >> "$STUB_STATE/loaded"; : > "$STUB_STATE/cold"; } ;;
    *"/v1/audio/speech")
        echo "$data" >> "$STUB_STATE/speech-requests"
        # one second of 24 kHz mono 16-bit, under a streamed header's maximal sizes
        { printf 'RIFF\xff\xff\xff\xffWAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\xc0\x5d\x00\x00\x80\xbb\x00\x00\x02\x00\x10\x00data\xff\xff\xff\xff'
          head -c 48000 /dev/zero; } > "$out" ;;
    *)                     exit 22 ;;
esac
[[ -n "$out" && "$out" != /dev/null && ! -s "$out" ]] && printf 'RIFF' > "$out"
if [[ -n "$wfmt" ]]; then
    if [[ -f "$STUB_STATE/cold" ]]; then rm -f "$STUB_STATE/cold"; printf '10.0'; else printf '2.0'; fi
fi
exit 0
EOF
# What the bench sees of the host: a game under Wine only when asked to be.
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -f "$STUB_STATE/wine" ]] && echo "4242 swtor.exe"
exit 0
EOF
printf '#!/usr/bin/env bash\necho 32\n' > "$T/bin/nproc"
printf '#!/usr/bin/env bash\necho corelia\n' > "$T/bin/hostname"
chmod +x "$T/bin/"*

export PATH="${TEST_DIR}/stubs:$T/bin:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/gumstate" STUB_LOG="$T/calls" STUB_STATE="$T/state"
export SCOMP_SPEACHES_CONFIG_DIR="$T/config" SCOMP_SPEACHES_QUADLET_DIR="$T/quadlet"
export SCOMP_SPEACHES_BENCH_OUT="$T/bench" SCOMP_SPEACHES_LOADAVG="$T/loadavg"
mkdir -p "$T/bench" "$T/audio"
echo "0.50 0.40 0.30 1/500 1" > "$T/loadavg"
head -c 1000 /dev/zero > "$T/audio/short.wav"; head -c 9000 /dev/zero > "$T/audio/long.mp3"
UNIT="$T/quadlet/speaches.container"

# The report a bench run wrote. Only at the top of $T/bench: the transcripts
# beside it are .json too, and find lists files in whatever order the
# filesystem keeps them - CI's picked a transcript.
bench_report() { find "$T/bench" -maxdepth 1 -name 'speaches-bench-*.json' | head -1; }

# run <answer>... - run the TUI with scripted gum answers.
run() {
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"
    bash "$FRONT" > "$T/out" 2>&1
}

# ---- target selection ---------------------------------------------------------
echo "target"
STUB_UNAME=Darwin run "← back"
check "macOS: podman is not offered (no systemd for Quadlet)" lacks "Podman  (rootless" "$T/out"
check "macOS: with no Docker and no cluster, nothing to pick" has "No deployment targets found" "$T/out"
run "← back"
check "Linux: podman is offered, and picked as the only target" has "Single target available: Podman" "$T/out"

# ---- install --------------------------------------------------------------------
echo "install"
run install yes yes yes "← back"
check "the Quadlet unit is written" test -f "$UNIT"
check "it pins the stable CPU image" has "Image=ghcr.io/speaches-ai/speaches:0.8.3-cpu" "$UNIT"
check "it publishes the port" has "PublishPort=8000:8000" "$UNIT"
check "the model cache is a named volume" has "Volume=speaches-hf-cache:/home/ubuntu/.cache/huggingface/hub" "$UNIT"
check "the idle time is set for 0.8 and 0.9 alike" has "Environment=WHISPER__TTL=300" "$UNIT"
check "Whisper's threads are Speaches' default until changed" has "Environment=WHISPER__CPU_THREADS=0" "$UNIT"
check "...and so is its compute type" has "Environment=WHISPER__COMPUTE_TYPE=default" "$UNIT"
check "...including text-to-speech (0.9)" has "Environment=TTS_MODEL_TTL=300" "$UNIT"
check "no GPU device on a CPU image" lacks "AddDevice" "$UNIT"
check "it starts at boot" has "WantedBy=default.target" "$UNIT"
check "systemd reloads and (re)starts the unit" has "systemctl --user restart speaches.service" "$T/calls"
check "lingering is enabled" has "loginctl enable-linger" "$T/calls"
check "Whisper turbo is downloaded" has "-X POST http://127.0.0.1:8000/v1/models/deepdml/faster-whisper-large-v3-turbo-ct2" "$T/calls"
check "Kokoro is downloaded" has "/v1/models/speaches-ai/Kokoro-82M-v1.0-ONNX" "$T/calls"
check "the English Piper voice is downloaded" has "/v1/models/speaches-ai/piper-en_US-lessac-medium" "$T/calls"
check "the closed port is offered, and opened" has "sudo firewall-cmd --permanent --add-port=8000/tcp" "$T/calls"
check "the settings are saved" test -f "$T/config/speaches.conf"

run install yes "← back"
check "a second install downloads nothing already there" lacks "-X POST" "$T/calls"
check "...and asks nothing about an open port" lacks "add-port" "$T/calls"
check "...nor about lingering, already on" lacks "Enable lingering" "$T/out"

# ---- status -----------------------------------------------------------------------
echo "status"
run status "← back"
check "status reports health" has "Health: ok" "$T/out"
check "status lists installed models" has "speaches-ai/Kokoro-82M-v1.0-ONNX" "$T/out"
check "status reports the open port" has "8000/tcp open" "$T/out"
check "status reports lingering" has "Linger: on" "$T/out"
rm -f "$T/state/port-open"
run status "← back"
check "a closed port reads as closed, not unknown" has "8000/tcp closed" "$T/out"
: > "$T/state/port-open"

# ---- bench ------------------------------------------------------------------------
echo "bench"
run bench "$T/audio" 3 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "an idle host is not questioned" lacks "not idle" "$T/out"
check "a report is written, named for the host" test -n "$REPORT"
check "...and is valid JSON" python3 -m json.tool "${REPORT:-/dev/null}" /dev/null
check "Whisper is unloaded before the cold run" has "-X DELETE http://127.0.0.1:8000/api/ps/deepdml/faster-whisper-large-v3-turbo-ct2" "$T/calls"
check "...and, not loaded at all (404), counts as cold" lacks "could not unload deepdml" "${REPORT:-/dev/null}"
check "Kokoro speaks a short command first" has "Turn off the lights" "$T/state/speech-requests"
check "...which takes the cold run" test "$(grep -m1 -o 'file=@[^ ]*' "$T/calls")" = "file=@${REPORT%.json}/spoken-command.wav"
check "...and is reported with what was said" has '"file":"spoken-command.wav","spoken_text":"Turn off the lights' "${REPORT:-/dev/null}"
check "...then the recordings, smallest first" test "$(grep -o 'file=@[^ ]*' "$T/calls" | sed -n 5p)" = "file=@$T/audio/short.wav"
check "the load is cold minus the warm median" has '"cold_seconds":10.0,"load_seconds":8.00' "${REPORT:-/dev/null}"
check "each recording runs the asked number of times" has '"runs_seconds":[2.0,2.0,2.0]' "${REPORT:-/dev/null}"
check "the real-time factor is median over audio length" has '"realtime_factor":0.0333' "${REPORT:-/dev/null}"
check "the model and its settings are recorded" has '"stt":{"model":"deepdml/faster-whisper-large-v3-turbo-ct2","cpu_threads":0,"compute_type":"default",' "${REPORT:-/dev/null}"
check "the conditions are recorded" has '"conditions":{"cpus":32,"load1":0.50,"wine":"","not_idle":false}' "${REPORT:-/dev/null}"
check "the transcripts are kept" test -f "${REPORT%.json}/long.mp3.json"
check "text to speech: the WAV's length, not its streamed header's" has '"audio_seconds":1.000' "${REPORT:-/dev/null}"
check "...made at 0.5x real time" has '"audio_per_second":0.50' "${REPORT:-/dev/null}"
check "Piper is asked for the voice its package names" has '"voice":"en_US-lessac-medium"' "$T/state/speech-requests"

rm -rf "${T:?}/bench"/*; : > "$T/state/wine"
run bench no "← back"
check "a game under Wine is named" has "running under Wine: swtor.exe" "$T/out"
check "...and declining benches nothing" test -z "$(ls -A "$T/bench")"
run bench yes "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
check "benching anyway says so in the report" has '"not_idle":true' "$(bench_report)"
rm -f "$T/state/wine"

rm -rf "${T:?}/bench"/*; : > "$T/state/no-unload"
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "a model that will not unload leaves the load unmeasured" has '"load_seconds":null' "${REPORT:-/dev/null}"
check "...and says why, with the HTTP status" has "could not unload deepdml/faster-whisper-large-v3-turbo-ct2 (DELETE /api/ps: HTTP 500)" "${REPORT:-/dev/null}"
check "...and text to speech is primed untimed, so its runs are warm" test "$(grep -c '/v1/audio/speech' "$T/calls")" -eq 5
rm -f "$T/state/no-unload"

rm -rf "${T:?}/bench"/*
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "a loaded Whisper is unloaded (204), and the cold run timed" has '"cold_seconds":10.0,"load_seconds":8.00' "${REPORT:-/dev/null}"

rm -rf "${T:?}/bench"/*; cp "$T/state/models" "$T/state/models.all"
grep -vxF speaches-ai/Kokoro-82M-v1.0-ONNX "$T/state/models.all" > "$T/state/models"
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "without Kokoro, no command - and says so" has "No short command to time" "$T/out"
check "...the recordings still run, the smallest cold" has '"file":"short.wav","spoken_text":null' "${REPORT:-/dev/null}"
mv "$T/state/models.all" "$T/state/models"

# Another Whisper, not installed: offered for download, then benched.
rm -rf "${T:?}/bench"/*
run bench "$T/audio" 1 Systran/faster-whisper-small yes "← back"
REPORT="$(bench_report)"
check "a model not installed is downloaded first" has "-X POST http://127.0.0.1:8000/v1/models/Systran/faster-whisper-small" "$T/calls"
check "...and is the one transcribing" has "model=Systran/faster-whisper-small" "$T/calls"
check "...and the one reported" has '"model":"Systran/faster-whisper-small"' "${REPORT:-/dev/null}"
check "...while the default model is not touched" lacks "model=deepdml/faster-whisper-large-v3-turbo-ct2" "$T/calls"
rm -rf "${T:?}/bench"/*
run bench "$T/audio" 1 Systran/faster-whisper-base no "← back"
check "declining the download benches nothing" test -z "$(ls -A "$T/bench")"

run status "← back"
check "status lists the loaded models, from 0.8.3's answer" has "Loaded now: deepdml/faster-whisper-large-v3-turbo-ct2" "$T/out"

# ---- settings ----------------------------------------------------------------------
echo "settings"
run config port 8010 "done" yes yes "← back"
check "a changed port is saved" has "SP_PORT=8010" "$T/config/speaches.conf"
check "re-applying rewrites the unit with it" has "PublishPort=8010:8000" "$UNIT"
run config "cpu threads" 16 "compute type" int8 "done" yes yes "← back"
check "threads are saved" has "SP_CPU_THREADS=16" "$T/config/speaches.conf"
check "...and reach the unit" has "Environment=WHISPER__CPU_THREADS=16" "$UNIT"
check "the compute type reaches the unit" has "Environment=WHISPER__COMPUTE_TYPE=int8" "$UNIT"
run config "cpu threads" lots "done" "← back"
check "a thread count that is not a number is refused" has "Not a thread count: lots" "$T/out"
run config "reset to defaults" yes "done" no "← back"
check "reset brings the defaults back" has "SP_PORT=8000" "$T/config/speaches.conf"
check "...threads included" has "SP_CPU_THREADS=0" "$T/config/speaches.conf"

# ---- uninstall ---------------------------------------------------------------------
echo "uninstall"
run uninstall yes no "← back"
check "the unit is removed" test ! -f "$UNIT"
check "the model cache is kept unless asked" lacks "podman volume rm" "$T/calls"

# ---- renderers -----------------------------------------------------------------------
echo "renderers"
(
    # shellcheck disable=SC1090
    source "$FRONT"
    set +e
    cfg_defaults
    render_quadlet "ghcr.io/speaches-ai/speaches:0.8.3-cuda" > "$T/cuda.unit"
    TARGET_TYPE=k8s render_k8s "$(TARGET_TYPE=k8s sp_image)" > "$T/k8s.yaml"
    SP_K8S_STORAGE_CLASS=local-path render_k8s "x" > "$T/k8s-class.yaml"
    sp_docker_run_args "ghcr.io/speaches-ai/speaches:0.8.3-cpu" > "$T/docker.args"
    sp_docker_run_args "ghcr.io/speaches-ai/speaches:0.8.3-cuda" > "$T/docker-cuda.args"
)
check "a CUDA image gets the GPU device" has "AddDevice=nvidia.com/gpu=all" "$T/cuda.unit"
check "k8s: auto means the CPU image" has "image: ghcr.io/speaches-ai/speaches:0.8.3-cpu" "$T/k8s.yaml"
check "k8s: Recreate, since one pod owns the cache" has "strategy: {type: Recreate}" "$T/k8s.yaml"
check "k8s: the cache is writable by the image's user" has "fsGroup: 1000" "$T/k8s.yaml"
check "k8s: no storage class unless set" lacks "storageClassName" "$T/k8s.yaml"
check "k8s: a set storage class is used" has "storageClassName: local-path" "$T/k8s-class.yaml"
check "k8s: ready only when /health answers" has "httpGet: {path: /health, port: 8000}" "$T/k8s.yaml"
check "docker: restarts unless stopped" has "unless-stopped" "$T/docker.args"
check "docker: no GPU flag on CPU" lacks "--gpus=all" "$T/docker.args"
check "docker: the GPU flag on CUDA" has "--gpus=all" "$T/docker-cuda.args"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"

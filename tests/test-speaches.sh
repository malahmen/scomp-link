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
#     cold minus warm on that file - and nothing is ever unloaded (it froze
#     Speaches 0.8.3 on corelia); medians, real-time factors and the TTS
#     audio length (from the WAV) reach a report that is valid JSON; a
#     Whisper already loaded leaves the load unmeasured, with the reason;
#     a short command spoken by Kokoro takes the cold run;
#   - status lists loaded models from 0.8.3's {"models": [...]}, and
#     installed models without the voices nested in them;
#   - where the port is published (Kamino 235): every interface by default -
#     a LAN service, deliberately, and the install says so - or where
#     SCOMP_BIND_ADDR says, with the URLs, the firewall offer and status
#     following it;
#   - the settings file is parsed, never sourced, and a value a setting may
#     not hold (there or typed under 'config') keeps the default (Kamino 235).
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
        # As curl reads -F: an unquoted , or ; in a file name is form syntax,
        # and curl fails to open the shortened name (26).
        -F) if [[ "$2" == file=@* && "${2#file=@}" != \"* && "${2#file=@}" == *[,\;]* ]]; then exit 26; fi
            shift 2 ;;
        -H|--max-time) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
models="$STUB_STATE/models"; touch "$models"
case "$method $url" in
    "GET "*/health)        exit 0 ;;
    # Each entry with a voice nested in it, as Kokoro's and Piper's have.
    "GET "*/v1/models)     printf '{"data":['; sed 's/.*/{"id":"&","object":"model","voices":[{"id":"af_heart","name":"af_heart"}]}/' "$models" | paste -sd, -; printf ']}\n' ;;
    "POST "*/v1/models/*)  echo "${url#*/v1/models/}" >> "$models" ;;
    "DELETE "*/v1/models/*) grep -vxF "${url#*/v1/models/}" "$models" > "$models.new"; mv "$models.new" "$models" ;;
    # As 0.8.3 answers: plain strings, and only Whisper's models.
    "GET "*/api/ps)        printf '{"models":['; sed 's/.*/"&"/' "$STUB_STATE/loaded" 2>/dev/null | paste -sd, -; printf ']}\n' ;;
    # A transcription is 10 s while Whisper is not loaded, 2 s once it is.
    *"/v1/audio/transcriptions")
        if [[ -f "$STUB_STATE/bare-reply" ]]; then echo '{"text":"hello there","segments":[]}' > "$out"
        else echo '{"text":"hello there","language":"en","duration":60.0,"segments":[]}' > "$out"; fi
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
unset SCOMP_BIND_ADDR

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
check "it publishes the port, on every interface: a LAN service (Kamino 235)" has "PublishPort=0.0.0.0:8000:8000" "$UNIT"
check "...and says so" has "every interface: this is a LAN service" "$T/out"
check "the model cache is a named volume" has "Volume=speaches-hf-cache:/home/ubuntu/.cache/huggingface/hub" "$UNIT"
check "the idle time is set for 0.8 and 0.9 alike" has "Environment=WHISPER__TTL=300" "$UNIT"
check "Whisper gets corelia's measured threads" has "Environment=WHISPER__CPU_THREADS=16" "$UNIT"
check "...and compute type" has "Environment=WHISPER__COMPUTE_TYPE=int8" "$UNIT"
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
check "...without the voices nested in them" lacks "af_heart" "$T/out"
check "status reports the open port" has "8000/tcp open" "$T/out"
check "status reports lingering" has "Linger: on" "$T/out"
rm -f "$T/state/port-open"
run status "← back"
check "a closed port reads as closed, not unknown" has "8000/tcp closed" "$T/out"
: > "$T/state/port-open"

# ---- where the port is published (Kamino 235) -------------------------------------
echo "bind address"
SCOMP_BIND_ADDR=127.0.0.1 run install yes "← back"
check "SCOMP_BIND_ADDR=127.0.0.1: published on loopback only" has "PublishPort=127.0.0.1:8000:8000" "$UNIT"
check "...it says it is not reachable from the LAN" has "not reachable from the LAN" "$T/out"
check "...no LAN URL is offered" lacks "From the LAN" "$T/out"
check "...and no firewall port is touched" bash -c '! grep -q "firewall-cmd" "$1"' _ "$T/calls"
check "...the address is saved for status" has "SP_BIND_ADDR=127.0.0.1" "$T/config/speaches.conf"
run status "← back"
check "status, without SCOMP_BIND_ADDR, still says loopback only" has "Published on 127.0.0.1 only" "$T/out"
check "...and skips the firewall" lacks "Firewall" "$T/out"
SCOMP_BIND_ADDR=192.0.2.7 run install yes "← back"
check "SCOMP_BIND_ADDR=192.0.2.7: published there" has "PublishPort=192.0.2.7:8000:8000" "$UNIT"
check "...said, with SCOMP_BIND_ADDR named" has "Published on 192.0.2.7 (SCOMP_BIND_ADDR)" "$T/out"
check "...Speaches is reached at that address" has "curl -fsS --max-time 10 http://192.0.2.7:8000/v1/models" "$T/calls"
check "...which is the LAN URL" has "From the LAN: http://192.0.2.7:8000/v1" "$T/out"
SCOMP_BIND_ADDR=nope run install yes "← back"
check "a SCOMP_BIND_ADDR that is not an address stops before anything" bash -c 'grep -q "is not an IPv4 address" "$1" && ! grep -q "podman pull" "$2"' _ "$T/out" "$T/calls"
run install yes "← back"
check "unset again: every interface" has "PublishPort=0.0.0.0:8000:8000" "$UNIT"
check "...and the address saved follows" has "SP_BIND_ADDR=0.0.0.0" "$T/config/speaches.conf"

# ---- bench ------------------------------------------------------------------------
echo "bench"
run bench "$T/audio" 3 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "an idle host is not questioned" lacks "not idle" "$T/out"
check "a report is written, named for the host" test -n "$REPORT"
check "...and is valid JSON" python3 -m json.tool "${REPORT:-/dev/null}" /dev/null
check "Whisper not loaded counts as cold" lacks "already loaded" "${REPORT:-/dev/null}"
check "nothing is unloaded, ever" lacks "-X DELETE" "$T/calls"
check "Kokoro speaks a short command first" has "Turn off the lights" "$T/state/speech-requests"
check "...which takes the cold run" test "$(grep -m1 -o 'file=@[^ ]*' "$T/calls" | tr -d '"')" = "file=@${REPORT%.json}/spoken-command.wav"
check "...and is reported with what was said" has '"file":"spoken-command.wav","spoken_text":"Turn off the lights' "${REPORT:-/dev/null}"
check "...then the recordings, smallest first" test "$(grep -o 'file=@[^ ]*' "$T/calls" | sed -n 5p | tr -d '"')" = "file=@$T/audio/short.wav"
check "the load is cold minus the warm median" has '"cold_seconds":10.0,"load_seconds":8.00' "${REPORT:-/dev/null}"
check "each recording runs the asked number of times" has '"runs_seconds":[2.0,2.0,2.0]' "${REPORT:-/dev/null}"
check "the real-time factor is median over audio length" has '"realtime_factor":0.0333' "${REPORT:-/dev/null}"
check "the model and its settings are recorded" has '"stt":{"model":"deepdml/faster-whisper-large-v3-turbo-ct2","cpu_threads":16,"compute_type":"int8",' "${REPORT:-/dev/null}"
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

# Whisper is loaded now (the runs above loaded it in the stub).
rm -rf "${T:?}/bench"/*
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "a Whisper already loaded is not unloaded" lacks "-X DELETE" "$T/calls"
check "...its load is left unmeasured" has '"load_seconds":null' "${REPORT:-/dev/null}"
check "...and the report says why" has "was already loaded - the load is not measured" "${REPORT:-/dev/null}"
check "...and how to measure it" has "restart Speaches" "$T/out"
check "text to speech is primed untimed, so its runs are warm" test "$(grep -c '/v1/audio/speech' "$T/calls")" -eq 5

# After Speaches' own idle unload (or a restart): cold again.
rm -rf "${T:?}/bench"/*; : > "$T/state/loaded"
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "once Speaches has unloaded it, the cold run is timed" has '"cold_seconds":10.0,"load_seconds":8.00' "${REPORT:-/dev/null}"

rm -rf "${T:?}/bench"/*; cp "$T/state/models" "$T/state/models.all"
grep -vxF speaches-ai/Kokoro-82M-v1.0-ONNX "$T/state/models.all" > "$T/state/models"
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "without Kokoro, no command - and says so" has "No short command to time" "$T/out"
check "...the recordings still run, the smallest cold" has '"file":"short.wav","spoken_text":null' "${REPORT:-/dev/null}"
mv "$T/state/models.all" "$T/state/models"

# Item 103: a , or ; in a recording's name, and a reply without duration or
# language.
rm -rf "${T:?}/bench"/*; mkdir -p "$T/audio2"
head -c 1000 /dev/zero > "$T/audio2/Dickinson, Because I could not; stop.wav"
run bench "$T/audio2" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "a recording with a comma and a semicolon in its name is benched (item 103)" has '"file":"Dickinson, Because I could not; stop.wav","spoken_text":null,"audio_seconds":60.0' "${REPORT:-/dev/null}"
check "...not failed" lacks "every run failed" "${REPORT:-/dev/null}"
rm -rf "${T:?}/bench"/*; : > "$T/state/bare-reply"
run bench "$T/audio" 1 deepdml/faster-whisper-large-v3-turbo-ct2 "← back"
REPORT="$(bench_report)"
check "a reply without duration or language still gives a report" test -n "$REPORT"
check "...with the length unknown, not invented" has '"file":"short.wav","spoken_text":null,"audio_seconds":null' "${REPORT:-/dev/null}"
rm -f "$T/state/bare-reply"

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
check "re-applying rewrites the unit with it" has "PublishPort=0.0.0.0:8010:8000" "$UNIT"
run config "cpu threads" 8 "compute type" float32 "done" yes yes "← back"
check "threads are saved" has "SP_CPU_THREADS=8" "$T/config/speaches.conf"
check "...and reach the unit" has "Environment=WHISPER__CPU_THREADS=8" "$UNIT"
check "the compute type reaches the unit" has "Environment=WHISPER__COMPUTE_TYPE=float32" "$UNIT"
run config "cpu threads" lots "done" "← back"
check "a thread count that is not a number is refused" has "Not a thread count: lots" "$T/out"
# Version and cache volume (Kamino 196): both reach the unit, docker run and
# the k8s manifest as typed, so they are checked like the numbers.
run config version "0.9.0-rc.1" "cache volume" "sp_cache-2.x" "done" yes yes "← back"
check "an image tag is saved" has "SP_VERSION=0.9.0-rc.1" "$T/config/speaches.conf"
check "...and is the unit's image" has "Image=ghcr.io/speaches-ai/speaches:0.9.0-rc.1-" "$UNIT"
check "a volume name is saved" has "SP_VOLUME=sp_cache-2.x" "$T/config/speaches.conf"
check "...and is the unit's volume" has "Volume=sp_cache-2.x:" "$UNIT"
cp "$T/config/speaches.conf" "$T/conf.before"
run config version "-x" version ".x" version "0.8 --privileged" "done" "← back"
check "a tag starting with - is refused" has "Not an image tag: -x" "$T/out"
check "...one starting with ." has "Not an image tag: .x" "$T/out"
check "...one with a space" has "Not an image tag: 0.8 --privileged" "$T/out"
run config "cache volume" "/" "cache volume" "../etc" "cache volume" 'v\nExec=/bin/sh' "cache volume" "x" "done" "← back"
check "a path as the volume is refused (a bind mount)" has "Not a volume name: /" "$T/out"
check "...a relative one" has "Not a volume name: ../etc" "$T/out"
check "...a newline (a line of its own in the unit)" has "Not a volume name: v" "$T/out"
check "...one character (podman and docker want two)" has "Not a volume name: x" "$T/out"
check "nothing refused was saved" cmp -s "$T/config/speaches.conf" "$T/conf.before"
# The settings file is parsed, not sourced (Kamino 235): a $(...) in it ran
# as code. Each value is checked like a typed one; a bad one keeps the default.
cp "$T/config/speaches.conf" "$T/conf.good"
{ cat "$T/conf.good"
  printf '%s\n' "SP_VERSION=\$(touch $T/pwned)" 'SP_MODELS=not-a-repo' "SP_K8S_STORAGE=20Gi\\ --privileged" \
      'SP_K8S_STORAGE_CLASS=Bad_Class' 'SP_PORT=99999' 'SP_VOLUME=/etc' 'SP_TTL=-5' 'SP_BIND_ADDR=lan'; } > "$T/config/speaches.conf"
run "← back"
check "a \$(...) in the settings file does not run" test ! -e "$T/pwned"
for k in SP_VERSION SP_MODELS SP_K8S_STORAGE SP_K8S_STORAGE_CLASS SP_PORT SP_VOLUME SP_TTL SP_BIND_ADDR; do
    check "a bad ${k} is ignored, with a warning" has "Ignoring ${k}" "$T/out"
done
(
    # shellcheck disable=SC1090
    source "$FRONT"
    set +e
    cfg_load 2>/dev/null
    TARGET_TYPE=k8s render_k8s "$(TARGET_TYPE=k8s sp_image)" > "$T/k8s-bad.yaml"
    printf '%s\n' "$SP_MODELS" > "$T/models-bad"
)
check "...and the line before it, or the default, is used: the image" grep -qxE '          image: ghcr.io/speaches-ai/speaches:[0-9][A-Za-z0-9.-]*-cpu' "$T/k8s-bad.yaml"
check "...the PVC size" has "storage: 20Gi" "$T/k8s-bad.yaml"
check "...no storage class" lacks "storageClassName" "$T/k8s-bad.yaml"
check "...the models" has "deepdml/faster-whisper-large-v3-turbo-ct2" "$T/models-bad"
cp "$T/conf.good" "$T/config/speaches.conf"
cp "$T/config/speaches.conf" "$T/conf.before"
run config models "not-a-repo" models "a/b *" "k8s storage" "lots" "k8s storage" "20Gi --x" "k8s storage class" "Bad_Class" "done" "← back"
check "a model that is not owner/name is refused" has "Not a model list: not-a-repo" "$T/out"
check "...a glob" has "Not a model list: a/b *" "$T/out"
check "a PVC size that is not a quantity" has "Not a PVC size: lots" "$T/out"
check "...or with a flag after it" has "Not a PVC size: 20Gi --x" "$T/out"
check "a StorageClass that is not a DNS name" has "Not a StorageClass name: Bad_Class" "$T/out"
check "nothing refused was saved" cmp -s "$T/config/speaches.conf" "$T/conf.before"
run config models "a/b   org/m-2.x" "k8s storage" "40Gi" "k8s storage class" "local-path" "done" no "← back"
check "a model list is saved, one space between" has "SP_MODELS=a/b\\ org/m-2.x" "$T/config/speaches.conf"
check "a PVC size" has "SP_K8S_STORAGE=40Gi" "$T/config/speaches.conf"
check "a StorageClass" has "SP_K8S_STORAGE_CLASS=local-path" "$T/config/speaches.conf"
cp "$T/conf.before" "$T/config/speaches.conf"
run config "reset to defaults" yes "done" no "← back"
check "reset brings the defaults back" has "SP_PORT=8000" "$T/config/speaches.conf"
check "...threads included" has "SP_CPU_THREADS=16" "$T/config/speaches.conf"
check "...and the compute type" has "SP_COMPUTE_TYPE=int8" "$T/config/speaches.conf"

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
check "docker: published on every interface by default (Kamino 235)" grep -qxF "0.0.0.0:8000:8000" "$T/docker.args"
check "docker: no GPU flag on CPU" lacks "--gpus=all" "$T/docker.args"
check "docker: the GPU flag on CUDA" has "--gpus=all" "$T/docker-cuda.args"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"

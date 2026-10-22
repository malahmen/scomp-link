#!/usr/bin/env bash
# The LM Studio front-end's bench (Kamino item 15), driven through the gum
# stub. No network and no LM Studio: curl answers like its server and lms is a
# recording stub, so nothing real is loaded.
#
# What it protects:
#   - a busy host (a game under Wine) is said so and benches only if asked;
#   - models already loaded are named and unloaded only if asked;
#   - each chosen model is loaded alone, at the context asked for and fully
#     on the GPU, after an unload of everything, and none is left loaded;
#   - generation is the median of the timed runs (the warm-up is not one of
#     them), prefill is prompt tokens / time to first token, and the dense
#     bandwidth is size x generation rate;
#   - a model that fails to load is recorded and the rest still bench;
#   - the report is valid JSON with the conditions it was taken in;
#   - lms is found in the Flatpak's own sandbox and run with HOME there, as on
#     corelia, where ~/.lmstudio does not exist.
# shellcheck disable=SC2016
# Single-quoted heredoc stubs expand their own $1/$@ at run time, on purpose.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/lmstudio/lmstudio.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

T="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] && echo "kept: $T" || rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

mkdir -p "$T/bin" "$T/state" "$T/home" "$T/bench"
# curl answers like LM Studio's server: the model list from a file, and chat
# completions whose figures the test can predict.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; for a in "$@"; do [[ "$a" == http* ]] && url="$a"; done
case "$url" in
    */api/v0/models) cat "$STUB_STATE/models.json" ;;
    */api/v0/chat/completions)
        req="$(cat)"; model="$(jq -r .model <<< "$req")"; max="$(jq -r .max_tokens <<< "$req")"
        echo "chat ${model} ${max}" >> "$STUB_LOG"
        if [[ "$max" == 300 ]]; then
            # generation: 70, 74, 72 tokens/s in turn -> median 72
            n=$(( $(cat "$STUB_STATE/gen-$$-count" 2>/dev/null || cat "$STUB_STATE/gen-count" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$STUB_STATE/gen-count"
            tok=$(( 70 + ( (n - 1) % 3 ) * 4 )); [[ $(( (n - 1) % 3 )) == 1 ]] && tok=74; [[ $(( (n - 1) % 3 )) == 2 ]] && tok=72
            printf '{"stats":{"tokens_per_second":%s,"time_to_first_token":0.1},"usage":{"prompt_tokens":40,"completion_tokens":300}}\n' "$tok"
        else
            # prefill: 1000 prompt tokens per second, whatever the size
            pt=$(( $(jq -r '.messages[0].content | length' <<< "$req") / 4 ))
            printf '{"stats":{"tokens_per_second":20,"time_to_first_token":%s},"usage":{"prompt_tokens":%s,"completion_tokens":16}}\n' \
                "$(awk -v p="$pt" 'BEGIN {printf "%.4f", p / 1000}')" "$pt"
        fi ;;
    *) exit 22 ;;
esac
EOF
# lms: records each call and the HOME it ran with.
cat > "$T/bin/lms-stub" <<'EOF'
#!/usr/bin/env bash
echo "lms $* [HOME=$HOME]" >> "$STUB_LOG"
case "$1" in
    ls)     cat "$STUB_STATE/inventory.json" ;;
    load)   [[ "$2" == bad/model ]] && { echo "Error: out of memory" >&2; exit 1; } ;;
esac
exit 0
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ -f "$STUB_STATE/wine" ]] && echo "4242 Wow.exe"
exit 0
EOF
printf '#!/usr/bin/env bash\necho 32\n' > "$T/bin/nproc"
printf '#!/usr/bin/env bash\necho corelia\n' > "$T/bin/hostname"
chmod +x "$T/bin/"*

cat > "$T/state/inventory.json" <<'EOF'
[{"modelKey":"google/gemma-4-31b-qat","sizeBytes":18000000000,"architecture":"gemma4","paramsString":"31B"},
 {"modelKey":"qwen/qwen3.6-35b-a3b","sizeBytes":22000000000,"architecture":"qwen35moe","paramsString":"35B-A3B"}]
EOF
models_json() {  # models_json <loaded model or "">
    jq -n --arg l "$1" '{data: [
      {id: "google/gemma-4-31b-qat", type: "vlm", state: (if $l == "google/gemma-4-31b-qat" then "loaded" else "not-loaded" end)},
      {id: "qwen/qwen3.6-35b-a3b", type: "vlm", state: "not-loaded"},
      {id: "bad/model", type: "llm", state: "not-loaded"},
      {id: "text-embedding-bge-m3", type: "embeddings", state: "not-loaded"}]}' > "$T/state/models.json"
}

export PATH="${TEST_DIR}/stubs:$T/bin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/config"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/gumstate" STUB_LOG="$T/calls" STUB_STATE="$T/state"
export SCOMP_LMSTUDIO_BENCH_OUT="$T/bench" SCOMP_LMSTUDIO_LOADAVG="$T/loadavg"
echo "0.50 0.40 0.30 1/500 1" > "$T/loadavg"
# lms where corelia's Flatpak keeps it, and NOT ~/.lmstudio
SANDBOX="$HOME/.var/app/ai.lmstudio.lm-studio"
mkdir -p "$SANDBOX/.lmstudio/bin"; cp "$T/bin/lms-stub" "$SANDBOX/.lmstudio/bin/lms"

report() { find "$T/bench" -maxdepth 1 -name 'lmstudio-bench-*.json' | head -1; }
run() {   # run <answer>... - the bench, with scripted gum answers
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$STUB_LOG"; rm -f "$T/state/gen-count" "$T"/bench/*
    bash "$FRONT" bench > "$T/out" 2>&1
}

echo "busy host"
models_json ""; : > "$T/state/wine"
run no
check "a game under Wine is named" has "running under Wine: Wow.exe" "$T/out"
check "declined, nothing is loaded" lacks "lms load" "$T/calls"
rm -f "$T/state/wine"

echo "a model already loaded"
models_json "google/gemma-4-31b-qat"
run 'google/gemma-4-31b-qat' no
check "the loaded model is named" has "Loaded now: google/gemma-4-31b-qat" "$T/out"
check "declined, nothing is unloaded or loaded" lacks "lms " "$T/calls"

echo "a bench of two models and one that fails to load"
models_json ""
run 'google/gemma-4-31b-qat\nbad/model\nqwen/qwen3.6-35b-a3b' 32768 3 "4000 16000"
R="$(report)"
check "a report is written" test -n "$R"
check "it is valid JSON" bash -c "jq -e . '$R' >/dev/null"
check "lms is the sandbox's, run with HOME there" has "lms ls --json [HOME=$SANDBOX]" "$T/calls"
check "each model loads at the context asked, fully on the GPU" \
    has "lms load google/gemma-4-31b-qat --context-length 32768 --gpu max -y" "$T/calls"
check "everything is unloaded before each model" \
    test "$(grep -c '^lms unload --all' "$T/calls")" -ge 4
check "...and the last call leaves none loaded" bash -c "tail -1 '$T/calls' | grep -q '^lms unload --all'"
check "three timed generation runs per model, plus one warm-up" \
    test "$(grep -c '^chat google/gemma-4-31b-qat 300' "$T/calls")" -eq 3 -a "$(grep -c '^chat google/gemma-4-31b-qat 32' "$T/calls")" -eq 1
check "generation is the median of the runs (70, 74, 72 -> 72)" \
    test "$(jq '.models[] | select(.model == "google/gemma-4-31b-qat") | .generation.tokens_per_second' "$R")" = 72
check "prefill is prompt tokens / time to first token" \
    jq -e '[.models[] | select(.model == "google/gemma-4-31b-qat") | .prefill[].tokens_per_second] | length == 2 and all(. == 1000)' "$R"
check "prefill reaches about the size asked" \
    test "$(jq '.models[] | select(.model == "google/gemma-4-31b-qat") | .prefill[1].prompt_tokens' "$R")" -ge 15000
check "the dense bandwidth is size x rate (18 GB x 72 = 1296 GB/s)" \
    test "$(jq '.models[] | select(.model == "google/gemma-4-31b-qat") | .gb_per_second_if_dense' "$R")" = 1296
check "the MoE's active parameters are recorded" \
    test "$(jq -r '.models[] | select(.model == "qwen/qwen3.6-35b-a3b") | .params' "$R")" = "35B-A3B"
check "the failed load is recorded with its reason" \
    bash -c "jq -r '.models[] | select(.model == \"bad/model\") | .error' '$R' | grep -q 'out of memory'"
check "...and the model after it still benches" \
    test "$(jq '.models[] | select(.model == "qwen/qwen3.6-35b-a3b") | .generation.tokens_per_second' "$R")" = 72
check "embedding models are not offered" lacks "<option> text-embedding-bge-m3" "$T/out"
check "the conditions are recorded" \
    test "$(jq -c '.conditions | [.cpus, .not_idle]' "$R")" = "[32,false]"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }

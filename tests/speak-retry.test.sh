#!/usr/bin/env bash
# tests/speak-retry.test.sh — DIVE-7247.
#
# Microsoft's free voice service drops calls in bursts, and 5dive-speak called
# edge-tts once, threw its error away and told the agent the paid backend was
# "the supported path". These arms grade the local half with stand-ins for
# edge-tts and ffmpeg: a service that fails twice and then answers gives a voice
# note, and so does one that fails 5 times (the live bursts ran 4-5 failures);
# one that never answers fails after exactly 6 tries, 1, 2, 4, 8 and 8 s apart,
# says why, and does not send the owner to paid voice as the fix. A `sleep`
# stand-in records the waits, so the shipped default backoff is what is graded.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-speak-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

SPEAK="$ROOT/voice/lib/5dive-speak.sh"
mkdir -p "$T/bin"

# edge-tts stand-in: fails the first $EDGE_FAILS calls the way the real client
# does (a traceback ending in NoAudioReceived), then writes the mp3.
cat > "$T/bin/edge-tts" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "$T/calls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/calls"
out=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == --write-media ]] && out="\$2"; shift; done
if (( n <= \${EDGE_FAILS:-0} )); then
  printf 'Traceback (most recent call last):\n  File "edge_tts", line 1\nedge_tts.exceptions.NoAudioReceived: No audio was received\n\n' >&2
  exit 1
fi
printf 'fake-mp3' > "\$out"
STUB
# ffmpeg stand-in: the output file is its last argument.
cat > "$T/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
printf 'OggS-fake' > "${@: -1}"
STUB
# sleep stand-in: records each wait instead of taking it.
cat > "$T/bin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s ' "\$1" >> "$T/waits"
STUB
chmod +x "$T/bin/edge-tts" "$T/bin/ffmpeg" "$T/bin/sleep"

speak() {
  : > "$T/calls"; : > "$T/waits"; rm -f "$T/out.ogg"
  PATH="$T/bin:$PATH" VOICE_LIB="$ROOT/voice/lib/voice-backend.sh" \
    VOICE_CONFIG="$T/none" VOICE_PLUGINS_JSON="$T/none.json" \
    bash "$SPEAK" --backend=local --voice=ru-RU-DmitryNeural --out="$T/out.ogg" "Привет, это проверка."
}

echo "== the service fails twice, then answers =="
out=$(EDGE_FAILS=2 speak 2>"$T/err"); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "edge-tts was called 3 times" "$(cat "$T/calls")" "3"
t_eq "the .ogg path is printed" "$out" "$T/out.ogg"
[[ -s "$T/out.ogg" ]] && t_ok "the .ogg was written" || t_fail "the .ogg was written"
t_eq "nothing on stderr" "$(cat "$T/err")" ""

t_eq "it waited 1 s, then 2 s" "$(cat "$T/waits")" "1 2 "

echo "== the service fails 5 times, then answers =="
out=$(EDGE_FAILS=5 speak 2>"$T/err"); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "edge-tts was called 6 times" "$(cat "$T/calls")" "6"
t_eq "the .ogg path is printed" "$out" "$T/out.ogg"
[[ -s "$T/out.ogg" ]] && t_ok "the .ogg was written" || t_fail "the .ogg was written"
t_eq "nothing on stderr" "$(cat "$T/err")" ""

echo "== the service answers at once =="
EDGE_FAILS=0 speak >/dev/null 2>&1; rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "edge-tts was called once" "$(cat "$T/calls")" "1"

echo "== NEGATIVE CONTROL: the service never answers =="
out=$(EDGE_FAILS=99 speak 2>"$T/err"); rc=$?
err=$(cat "$T/err")
[[ "$rc" != 0 ]] && t_ok "rc non-zero ($rc)" || t_fail "rc non-zero" "got 0"
t_eq "edge-tts was called exactly 6 times" "$(cat "$T/calls")" "6"
t_eq "it waited 1, 2, 4, 8 and 8 s between them (~23 s)" "$(cat "$T/waits")" "1 2 4 8 8 "
t_eq "no path printed" "$out" ""
[[ ! -e "$T/out.ogg" || ! -s "$T/out.ogg" ]] && t_ok "no .ogg written" || t_fail "no .ogg written"
t_has "the message carries edge-tts's own last error line" "$err" "edge_tts.exceptions.NoAudioReceived: No audio was received"
t_has "the message says the tries" "$err" "failed 6 times"
t_has "the message says it is for now" "$err" "failing for now"
t_has "paid voice is named as an option" "$err" "paid OpenRouter voice is an option"
t_no "paid voice is not called the supported path" "$err" "supported path"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))

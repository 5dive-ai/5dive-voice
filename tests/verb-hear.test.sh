#!/usr/bin/env bash
# tests/verb-hear.test.sh — DIVE-6544.
#
# `5dive voice hear <path>` is how the web chat gets a voice note's transcript:
# the browser lands the note under /home/claude/chat-uploads/ and asks the box,
# over the exec route (which runs `sudo 5dive …`), to hear it. These arms grade
# the verb's half: the answer's shape (the dashboard parses an {ok,data} envelope),
# and that root only ever hears a regular file under the uploads root. The
# transcriber is a stand-in; hearing itself is graded in the engine's own tests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-hear-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

VOICE="$ROOT/voice/bin/voice"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

mkdir -p "$T/uploads/theo" "$T/outside"
printf 'OggS-fake-audio' > "$T/uploads/theo/1-voice.webm"
printf 'secret' > "$T/outside/secret.txt"
: > "$T/uploads/theo/empty.webm"
ln -s "$T/outside/secret.txt" "$T/uploads/theo/link.webm"

# The stand-in transcriber: records what it was asked to hear, answers a fixed line.
cat > "$T/transcribe" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == -- ]] && shift
printf '%s\n' "\$1" >> "$T/heard"
printf '  Hello Theo,\n  book the flight.  \n'
STUB
chmod +x "$T/transcribe"
cat > "$T/deaf" <<'STUB'
#!/usr/bin/env bash
echo "whisper-service did not answer" >&2
exit 3
STUB
chmod +x "$T/deaf"

hear() { VOICE_HEAR_ROOT="$T/uploads" VOICE_TRANSCRIBE_BIN="${BIN:-$T/transcribe}" "$VOICE" hear "$@"; }

echo "== a note under the uploads root is heard =="
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo/1-voice.webm" 2>/dev/null); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "the envelope is {ok:true,data:{text}} (agent-exec-envelope.ts reads .data)" "$(jq -r '.ok' <<<"$out")" "true"
t_eq "the transcript is one line, trimmed" "$(jq -r '.data.text' <<<"$out")" "Hello Theo, book the flight."
t_eq "the transcriber was handed the resolved path" "$(tail -n1 "$T/heard")" "$(realpath "$T/uploads/theo/1-voice.webm")"
out=$(hear --json "$T/uploads/theo/1-voice.webm" 2>/dev/null)
t_eq "--json on argv works too (a seat calling the verb directly)" "$(jq -r '.data.text' <<<"$out")" "Hello Theo, book the flight."
out=$(hear "$T/uploads/theo/1-voice.webm" 2>/dev/null)
t_eq "without JSON mode it prints the transcript alone" "$out" "Hello Theo, book the flight."

echo "== root never hears a path outside the uploads root =="
: > "$T/heard"
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/outside/secret.txt" 2>/dev/null); rc=$?
t_eq "outside → refused" "$(jq -r '.error.class' <<<"$out")" "refused"
t_eq "outside → rc 1" "$rc" "1"
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo/../../outside/secret.txt" 2>/dev/null)
t_eq "a ../ escape → refused" "$(jq -r '.error.class' <<<"$out")" "refused"
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo/link.webm" 2>/dev/null)
t_eq "a symlink inside the root pointing out → refused" "$(jq -r '.error.class' <<<"$out")" "refused"
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo" 2>/dev/null)
t_eq "a directory → refused" "$(jq -r '.error.class' <<<"$out")" "refused"
t_eq "the transcriber never ran on any of them" "$(wc -c < "$T/heard" | tr -d ' ')" "0"

echo "== the failures a browser can meet, each with its own class =="
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo/nope.webm" 2>/dev/null)
t_eq "missing note → not_found" "$(jq -r '.error.class' <<<"$out")" "not_found"
out=$(FIVEDIVE_JSON_MODE=1 hear "$T/uploads/theo/empty.webm" 2>/dev/null)
t_eq "empty note → empty" "$(jq -r '.error.class' <<<"$out")" "empty"
out=$(FIVEDIVE_JSON_MODE=1 VOICE_HEAR_MAX_BYTES=4 hear "$T/uploads/theo/1-voice.webm" 2>/dev/null)
t_eq "over the cap → too_big" "$(jq -r '.error.class' <<<"$out")" "too_big"
out=$(FIVEDIVE_JSON_MODE=1 BIN="$T/absent" hear "$T/uploads/theo/1-voice.webm" 2>/dev/null)
t_eq "no engine → engine_missing" "$(jq -r '.error.class' <<<"$out")" "engine_missing"
t_has "no engine → names the install command" "$(jq -r '.error.message' <<<"$out")" "sudo 5dive voice setup"
out=$(FIVEDIVE_JSON_MODE=1 BIN="$T/deaf" hear "$T/uploads/theo/1-voice.webm" 2>/dev/null); rc=$?
t_eq "the transcriber failing → unheard" "$(jq -r '.error.class' <<<"$out")" "unheard"
t_has "unheard → says why" "$(jq -r '.error.message' <<<"$out")" "whisper-service did not answer"
t_eq "unheard → rc 1" "$rc" "1"
t_eq "every failure is still a parseable envelope with an error object" "$(jq -r '.error | type' <<<"$out")" "object"
out=$(FIVEDIVE_JSON_MODE=1 hear 2>/dev/null); rc=$?
t_eq "no path → usage" "$(jq -r '.error.class' <<<"$out")" "usage"
t_eq "no path → rc 64" "$rc" "64"
out=$(VOICE_HEAR_ROOT="$T/no-such-root" VOICE_TRANSCRIBE_BIN="$T/transcribe" FIVEDIVE_JSON_MODE=1 "$VOICE" hear "$T/uploads/theo/1-voice.webm" 2>/dev/null)
t_eq "no uploads root yet → not_found" "$(jq -r '.error.class' <<<"$out")" "not_found"

echo "== the help names it =="
t_has "voice --help lists hear" "$("$VOICE" --help)" "5dive voice hear <path>"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

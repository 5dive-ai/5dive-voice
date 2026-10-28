#!/usr/bin/env bash
# tests/verb-as-root.test.sh — DIVE-7172.
#
# A change to the box's voice settings is a root act. An agent that HOLDS the
# grant must get it made without knowing the word sudo, and one that does not
# must be told which colleague can, never to hand its owner a command (the owner
# has no terminal). These arms are the NON-ROOT paths, so as root (which CI is)
# the battery re-runs itself as nobody. sudo and 5dive are fakes that record
# what they were asked: offline, no box, no real sudo.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $EUID -eq 0 && -z "${VOICE_AS_ROOT_INNER:-}" ]]; then
  T="$(mktemp -d /tmp/voice-asroot-test.XXXXXX)"
  trap 'rm -rf "$T"' EXIT
  cp -a "$ROOT/voice" "$ROOT/tests" "$T/"
  chmod -R a+rX "$T"
  runuser -u nobody -- env VOICE_AS_ROOT_INNER=1 bash "$T/tests/verb-as-root.test.sh"
  exit $?
fi

T="$(mktemp -d /tmp/voice-asroot-run.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

command -v jq >/dev/null || { echo "jq required"; exit 2; }
VOICE="$ROOT/voice/bin/voice"
LIB="$ROOT/voice/lib/voice-backend.sh"

export VOICE_STATE_DIR="$T/state/voice" VOICE_CONNECTORS_DIR="$T/conn"
mkdir -p "$VOICE_STATE_DIR" "$VOICE_CONNECTORS_DIR"
CFG="$VOICE_STATE_DIR/config"
LOG="$T/calls.log"

# Fake sudo: `-n -l <cmd...>` answers from FAKE_GRANT, `-n <cmd...>` records.
cat > "$T/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -n ]] || { echo "fake sudo: called without -n: $*" >> "$FAKE_LOG"; exit 9; }
shift
if [[ "$1" == -l ]]; then shift; echo "probe $*" >> "$FAKE_LOG"; [[ "$FAKE_GRANT" == yes ]]; exit; fi
echo "run $*" >> "$FAKE_LOG"
EOF
# Fake 5dive: the colleague list any seat may read.
cat > "$T/5dive" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "agent list --json" ]] && { cat "$FAKE_AGENTS"; exit 0; }
echo "5dive $*" >> "$FAKE_LOG"; exit 1
EOF
chmod +x "$T/sudo" "$T/5dive"

cat > "$T/agents-team.json" <<'EOF'
{"ok":true,"data":[
 {"name":"gone","active":"inactive","sudo":{"impliedIsolation":"admin"}},
 {"name":"broke","active":"failed","sudo":{"impliedIsolation":"beyond-admin"}},
 {"name":"ann","active":"active","sudo":{"impliedIsolation":"standard"}},
 {"name":"marcus","active":"active","sudo":{"impliedIsolation":"admin"}},
 {"name":"bob","active":"active","sudo":{"impliedIsolation":"standard"}}
]}
EOF
cat > "$T/agents-alone.json" <<'EOF'
{"ok":true,"data":[{"name":"ann","active":"active","sudo":{"impliedIsolation":"standard"}}]}
EOF

run() {
  : > "$LOG"
  USER=agent-ann VOICE_LIB="$LIB" VOICE_SUDO="$T/sudo" FIVEDIVE_BIN="$T/5dive" \
    FAKE_LOG="$LOG" FAKE_GRANT="$1" FAKE_AGENTS="$T/agents-$2.json" "$VOICE" "${@:3}"
}

echo "== an agent that holds the grant gets the change made, no sudo typed =="
out=$(run yes team config set stt_language ru 2>&1); rc=$?
t_eq "config set without sudo succeeds" "$rc" "0"
t_has "...it asked sudo about the EXACT command first" "$(cat "$LOG")" "probe $T/5dive voice config set stt_language ru"
t_has "...then re-ran that same command through sudo -n" "$(cat "$LOG")" "run $T/5dive voice config set stt_language ru"
t_no "...and never told the agent it lacks root" "$out" "needs root"
out=$(run yes team backend local 2>&1); rc=$?
t_eq "the backend switch is re-run the same way" "$(cat "$LOG" | tail -1)" "run $T/5dive voice backend local"

echo "== an agent without it is told who can, never to hand the owner a command =="
out=$(run no team config set stt_language ru 2>&1); rc=$?
t_eq "refused" "$rc" "1"
t_eq "...sudo was only asked, never run" "$(grep -c '^run ' "$LOG")" "0"
t_has "...says the owner has no terminal" "$out" "they have no terminal"
t_has "...names the active admin colleague" "$out" "(marcus)"
t_no "...not the inactive one listed before it" "$out" "gone"
t_no "...nor a failed one" "$out" "broke"
t_no "...nor a standard one" "$out" "bob"
t_has "...and hands over the message to send" "$out" "5dive agent send marcus \"My owner asked to change a voice setting. Please run: sudo 5dive voice config set stt_language ru\""
t_eq "...and nothing was written" "$([[ -f "$CFG" ]] && echo wrote || echo clean)" "clean"
out=$(run no alone config set stt_language ru 2>&1)
t_has "with no admin colleague, the owner is pointed at the app, not a command" "$out" "voice settings of the 5dive app"
out=$(run no team backend openrouter 2>&1); rc=$?
t_eq "the backend switch is refused the same way" "$rc" "1"
t_has "...with its own command in the message" "$out" "Please run: sudo 5dive voice backend openrouter"

echo "== a box's first config (config init) takes the same two paths =="
out=$(run yes team config init stt_language=ru 2>&1); rc=$?
t_eq "init by a seat with the grant succeeds" "$rc" "0"
t_eq "...re-run through sudo -n" "$(tail -1 "$LOG")" "run $T/5dive voice config init stt_language=ru"
out=$(run no team config init stt_language=ru 2>&1); rc=$?
t_eq "init by a seat without it is refused" "$rc" "1"
t_has "...naming the colleague, not a command for the owner" "$out" "5dive agent send marcus"
t_no "...and never the old 'Run: sudo' line" "$out" "Run: sudo"

echo "== a bad value is refused before sudo is even asked =="
out=$(run yes team config set stt_language russian 2>&1); rc=$?
t_eq "rc 2" "$rc" "2"
t_eq "...and sudo was never asked" "$(wc -l < "$LOG" | tr -d ' ')" "0"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]

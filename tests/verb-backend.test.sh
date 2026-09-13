#!/usr/bin/env bash
# tests/verb-backend.test.sh — DIVE-4439.
#
# The verb owns exactly one decision that can hurt someone: whether this box's
# voice audio leaves it. These arms grade that decision and nothing else —
# offline, no box, no credential, no spend. The engine half (the wrappers that
# actually call OpenRouter) is graded in 5dive-api's
# scripts/test-voice-backend.test.sh; duplicating it here would be a second
# definition of the same answer, which is the thing this design is avoiding.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-verb-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

VOICE="$ROOT/voice/bin/voice"
[[ -x "$VOICE" ]] || { echo "voice/bin/voice is not executable — the dispatcher would refuse it"; exit 2; }

echo "== the manifest =="
M="$ROOT/voice/.claude-plugin/plugin.json"
command -v jq >/dev/null || { echo "jq required"; exit 2; }
t_eq "the manifest declares the verb capability (contract §2: an undeclared surface is inert)" \
  "$(jq -r '[.fivedive.capabilities[]] | index("verb") != null' "$M")" "true"
t_eq "the declared verb name matches the file the dispatcher will look for" \
  "$(jq -r '.fivedive.verbs[0].name' "$M")" "voice"
# Contract §4: the install path is keyed on version, so a shipped change that
# does not bump it fetches NOTHING on an already-installed box. This arm is the
# reason that is not a thing you have to remember.
t_no "the version is no longer 1.0.0 — an unbumped manifest installs nothing (contract §4)" \
  "$(jq -r '.version' "$M")" "1.0.0"

echo "== without the engine installed, the verb says so instead of guessing =="
out=$(VOICE_LIB="$T/absent.sh" "$VOICE" backend 2>&1); rc=$?
t_has "no engine → names the install command" "$out" "sudo 5dive-setup-voice"
t_eq "no engine → non-zero" "$rc" "1"
t_no "no engine → does NOT invent a backend answer" "$out" "openrouter"

echo "== with the engine present =="
mkdir -p "$T/state/voice" "$T/conn"
# The real library from 5dive-api is not in this repo (and must not be copied
# here — one copy, in the engine). A faithful stand-in is built from the
# contract this verb relies on; the arms below grade the VERB's behaviour given
# that contract, which is the only half this repo ships.
cat > "$T/lib.sh" <<LIB
VOICE_STATE_DIR="$T/state/voice"
VOICE_CONFIG="\$VOICE_STATE_DIR/config"
voice_config_get() { local k="\$1" d="\${2:-}" v=""; [[ -r "\$VOICE_CONFIG" ]] && v=\$(grep -m1 "^\${k}=" "\$VOICE_CONFIG" | cut -d= -f2-); printf '%s\n' "\${v:-\$d}"; }
voice_backend_configured() { local b; b=\$(voice_config_get backend local); case "\$b" in openrouter) echo openrouter;; *) echo local;; esac; }
voice_openrouter_key() { [[ -f "$T/conn/key" ]] && { cat "$T/conn/key"; return 0; }; return 1; }
voice_key_fix_line() { printf 'no OpenRouter key on this box. Fix:\n  sudo 5dive-write-connector openrouter.env\n'; }
voice_effective_backend() { local w; w=\$(voice_backend_configured); [[ "\$w" != openrouter ]] && { echo local; return; }; voice_openrouter_key >/dev/null 2>&1 && { echo openrouter; return; }; echo "falling back to the local engine" >&2; echo local; }
voice_stt_model() { voice_config_get stt_model openai/whisper-large-v3-turbo; }
voice_tts_model() { voice_config_get tts_model microsoft/mai-voice-2-flash; }
LIB

run() { VOICE_LIB="$T/lib.sh" "$VOICE" "$@"; }

rm -f "$T/state/voice/config" "$T/conn/key"
t_eq "an unconfigured box reads as local" "$(run backend 2>/dev/null)" "local"

echo "== changing it is a root act, reading it is not =="
out=$(run backend openrouter 2>&1); rc=$?
if [[ $EUID -eq 0 ]]; then
  t_ok "(running as root — the non-root refusal arm is not applicable)"
else
  t_has "a non-root seat is told to use sudo, not half-applied" "$out" "sudo 5dive voice backend openrouter"
  t_eq "...and refuses" "$rc" "1"
  t_eq "...and wrote nothing" "$([[ -f "$T/state/voice/config" ]] && echo wrote || echo clean)" "clean"
fi

echo "== the refusal that matters: openrouter without a key =="
# Root is needed to exercise the write path; where the harness is not root, the
# arm is declared skipped rather than quietly dropped.
if [[ $EUID -ne 0 ]]; then
  echo "  skip write-path arms (not root) — run as root to grade them"
else
  rm -f "$T/conn/key"
  out=$(run backend openrouter 2>&1); rc=$?
  t_has "refuses the switch and names the fix, rather than failing at the first voice note" "$out" "5dive-write-connector"
  t_eq "...and refuses" "$rc" "1"
  t_eq "...and the box is still local" "$(run backend 2>/dev/null)" "local"

  printf 'sk-or-test\n' > "$T/conn/key"
  out=$(run backend openrouter 2>&1)
  t_has "with a key, the switch lands" "$out" "backend: openrouter"
  t_has "...and says plainly what now leaves the box" "$out" "AUDIO and REPLY TEXT"
  t_eq "...and it reads back" "$(run backend 2>/dev/null)" "openrouter"

  printf '# a comment the installer wrote\nstt_model=meta/muse-voice-transcribe-1.0\nbackend=openrouter\n' > "$T/state/voice/config"
  run backend local >/dev/null 2>&1
  t_has "switching back preserves the rest of the config" "$(cat "$T/state/voice/config")" "stt_model=meta/muse-voice-transcribe-1.0"
  t_has "...and the comment" "$(cat "$T/state/voice/config")" "# a comment the installer wrote"
  t_eq "...and there is exactly ONE backend= line, not an appended second" \
    "$(grep -c '^backend=' "$T/state/voice/config")" "1"
  t_eq "...reading local" "$(run backend 2>/dev/null)" "local"
fi

echo "== the help text carries the caveat a user cannot discover alone =="
h=$(run --help 2>&1)
t_has "help names the Russian/Ukrainian gap in the most accurate English model" "$h" "Ukrainian"
t_has "help says the default model does cover Russian" "$h" "Russian"
t_has "help is honest that 'local' speaking is not local" "$h" "Microsoft"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# tests/quiet-setup.test.sh — DIVE-7034.
#
# `sudo 5dive voice setup` printed ~950 lines on a fresh box (apt and dpkg,
# mostly) for six steps. The rule: one line per step and the result on the
# terminal, the rest in a log, --verbose for all of it, a failure in full, and no
# internal row id in any of it.
#
# The steps themselves install onto the box (apt, systemd, /usr/local), so they
# are replaced by stubs that print the way they do. What is graded is the
# installer's own main, output helpers and exit trap, as shipped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-quiet-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }
t_le()   { (( $2 <= $3 )) && t_ok "$1" || t_fail "$1" "$2 > $3"; }

INSTALLER="$ROOT/voice/bin/5dive-setup-voice"
[[ "$(tail -n1 "$INSTALLER")" == 'main "$@"' ]] || { echo "the installer no longer ends in main \"\$@\""; exit 2; }

# run <stub-defs> <args...> — the installer's main with its steps stubbed, as a
# non-root caller (require_root stubbed too), logging to $T/setup.log.
run() {
  local defs="$1"; shift
  VOICE_SETUP_LOG="${VOICE_SETUP_LOG:-$T/setup.log}" PAYLOAD_DIR="$ROOT/voice/lib" bash -c '
    . <(sed "\$d" "$1")
    require_root() { :; }
    noise() { local i; for ((i = 1; i <= 200; i++)); do echo "Selecting previously unselected package lib$i."; done; }
    eval "$2"
    shift 2
    main "$@"' _ "$INSTALLER" "$defs" "$@" 2>&1
}

OKSTEPS='
step_apt()      { say "Step 1/6 — ffmpeg (apt)"; noise; ok "ffmpeg installed"; }
step_pip()      { say "Step 2/6 — faster-whisper + edge-tts (pip, claude venv)"; noise; ok "faster-whisper + edge-tts installed"; }
step_service()  { say "Step 3/6 — whisper-service (warm HTTP, port 8765, model=base)"; noise; ok "whisper-service ready at http://127.0.0.1:8765"; }
step_wrapper()  { say "Step 4/6 — voice-backend lib + 5dive-transcribe / 5dive-speak wrappers"; noise; ok "5dive-speak installed at /usr/local/bin/5dive-speak"; }
step_state()    { say "Step 5/6 — backend state dir"; ok "wrote config (backend=local)"; }
step_claudemd() { say "Step 6/6 — Append Voice section"; ok "Voice section appended."; }
'

echo "== a successful run is short =="
rm -f "$T/setup.log"
out=$(run "$OKSTEPS" all); rc=$?
t_eq "rc 0" "$rc" "0"
t_le "at most 15 lines on the terminal (got $(wc -l <<<"$out"))" "$(wc -l <<<"$out")" 15
for n in 1 2 3 4 5 6; do t_has "...step $n/6 has its line" "$out" "Step $n/6"; done
t_has "...each line ends with what the step reported" "$out" "whisper-service ready at http://127.0.0.1:8765"
t_has "...and the result is said" "$out" "Voice is set up"
t_has "...and where the details went" "$out" "$T/setup.log"
t_no "...none of the steps' own output" "$out" "Selecting previously unselected"
t_no "...no ANSI colour when the terminal is not a tty" "$out" $'\e['
t_eq "...no internal row id" "$(grep -cE 'DIVE-[0-9]+' <<<"$out")" "0"
t_eq "the log has all of it" "$(grep -c 'Selecting previously unselected' "$T/setup.log")" "800"
t_has "...headed with the run" "$(cat "$T/setup.log")" "5dive voice setup all"

echo "== --verbose prints it all, as before =="
out=$(run "$OKSTEPS" all --verbose); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "every line of the steps' output is on the terminal" "$(grep -c 'Selecting previously unselected' <<<"$out")" "800"
t_has "...with the step headers" "$out" "== Step 1/6"
out=$(run "$OKSTEPS" --verbose all); t_eq "--verbose before the step works too" "$(grep -c 'Selecting previously unselected' <<<"$out")" "800"
out=$(VOICE_SETUP_VERBOSE=1 run "$OKSTEPS" all); t_eq "...and VOICE_SETUP_VERBOSE=1" "$(grep -c 'Selecting previously unselected' <<<"$out")" "800"

echo "== a command that fails is printed in full =="
FAILSTEP="$OKSTEPS"'
step_pip() { say "Step 2/6 — faster-whisper + edge-tts (pip, claude venv)"; noise; echo "ERROR: No matching distribution found for faster-whisper"; false; }
'
rm -f "$T/setup.log"
out=$(run "$FAILSTEP" all); rc=$?
t_no "rc is not 0" "$rc" "0"
t_has "the failing step is named" "$out" "Step 2/6 — faster-whisper + edge-tts (pip, claude venv) failed"
t_has "...its error is on the terminal" "$out" "ERROR: No matching distribution found for faster-whisper"
t_has "...and the full log is named" "$out" "Full log: $T/setup.log"
t_no "...the steps after it did not run" "$out" "Step 3/6"
t_no "...nothing claims it was set up" "$out" "Voice is set up"
t_eq "...no internal row id" "$(grep -cE 'DIVE-[0-9]+' <<<"$out")" "0"
t_le "...and it is still not the whole log (got $(wc -l <<<"$out"))" "$(wc -l <<<"$out")" 40

echo "== the installer's own refusal is printed in full =="
DIESTEP="$OKSTEPS"'
step_service() { say "Step 3/6 — whisper-service"; noise; die "could not work out which whisper model this box should load"; }
'
out=$(run "$DIESTEP" all); rc=$?
t_eq "rc 1" "$rc" "1"
t_has "the message is on the terminal" "$out" "✗ could not work out which whisper model this box should load"
t_has "...with the log named" "$out" "Full log:"
t_no "...and not the log's tail on top of it" "$out" "Selecting previously unselected"

echo "== a warning gets its own line =="
WARNSTEP="$OKSTEPS"'
step_service() { say "Step 3/6 — whisper-service"; noise; warn "whisper-service not healthy after 6min — check: journalctl -u whisper-service"; }
'
out=$(run "$WARNSTEP" all); rc=$?
t_eq "rc 0" "$rc" "0"
t_has "the warning is on the terminal" "$out" "! whisper-service not healthy after 6min"
t_no "...and that step is not also ticked" "$out" "✓ done"

echo "== one step on its own: one line, nothing else =="
out=$(run 'step_model() { say "Hearing model"; echo "Loading \"small\"..."; ok "whisper-service hears on small"; }' model); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "the owner's switch prints one line" "$out" "Hearing model … ✓ whisper-service hears on small"

echo "== no log to write: everything is printed, the install is not failed =="
out=$(VOICE_SETUP_LOG=/proc/nope/setup.log run "$OKSTEPS" all); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "the steps' output is printed instead" "$(grep -c 'Selecting previously unselected' <<<"$out")" "800"

echo "== nothing the installer prints carries an internal row id =="
# Comments name rows on purpose; a line of code that prints never should.
t_eq "no DIVE-<n> outside a comment" "$(grep -vE '^[[:space:]]*#' "$INSTALLER" | grep -cE 'DIVE-[0-9]+')" "0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

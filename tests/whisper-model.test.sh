#!/usr/bin/env bash
# tests/whisper-model.test.sh — DIVE-5897.
#
# Which whisper model hearing loads used to be `small`: 9-12 s for a note on
# a Start box, still 6-8 s on a Pro Plus one, where base takes 3-4 s. base is
# now the default on every box, an owner can switch it with
# `sudo 5dive voice config set whisper_model`, and a later run (the nightly)
# re-applies the default unless a person chose the model.
#
# These arms run the REAL installer's steps and the REAL verb against scratch
# paths: the unit file, the service binary, the voice config and CLAUDE.md are
# all under $T, and systemctl and curl are stubs that record what was asked and
# answer /health with whatever model the last restart loaded. Memory is faked
# through VOICE_MEMINFO.
#
# Most arms need NO root: the installer's steps are run by sourcing it without
# its final `main "$@"` line, which is the only place it checks for root. The
# verb's `config set` refuses a non-root caller by design, so those arms run
# only as root (CI runs this with sudo) and say so when they skip.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-whisper-model-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

command -v jq >/dev/null || { echo "jq required"; exit 2; }

INSTALLER="$ROOT/voice/bin/5dive-setup-voice"
VOICE="$ROOT/voice/bin/voice"
LIB="$ROOT/voice/lib/voice-backend.sh"

mkdir -p "$T/bin" "$T/state"
# systemctl: is-active answers from a flag file; restart (and `enable --now` of
# a stopped service) "loads" the unit's model into the file /health reads;
# everything is logged.
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/systemctl.log"
case "\$1" in
  is-active) [[ -e "$T/active" ]] ;;
  restart|try-restart|enable)
    [[ "\$1" == try-restart && ! -e "$T/active" ]] && exit 0
    [[ "\$1" == enable && ( "\$2" != --now || -e "$T/active" ) ]] && exit 0
    sed -n 's/^Environment=WHISPER_MODEL=//p' "$T/unit" > "$T/loaded"; touch "$T/active" ;;
  *) exit 0 ;;
esac
EOF
# curl: only /health is ever fetched by the code under test.
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
[[ -e "$T/active" ]] || exit 7
printf '{"ok": true, "model": "%s", "accepts": ["path", "language", "beam_size"]}\n' "\$(cat "$T/loaded" 2>/dev/null)"
EOF
chmod 755 "$T/bin/systemctl" "$T/bin/curl"

mem() { printf 'MemTotal:       %s kB\nMemFree:        100000 kB\n' "$1" > "$T/meminfo"; }
export PATH="$T/bin:$PATH" VOICE_MEMINFO="$T/meminfo" VOICE_STATE_DIR="$T/state" \
  WHISPER_UNIT="$T/unit" WHISPER_SERVICE_BIN="$T/whisper-service" WHISPER_WAIT_SECS=4 \
  VOICE_LIB="$LIB"
unset WHISPER_MODEL VOICE_CONFIG
CFG="$T/state/config"
# step <name> — one installer step, as main would run it but without its root
# check. PAYLOAD_DIR is passed because a sourced file has no path of its own.
step() {
  ( PAYLOAD_DIR="$ROOT/voice/lib"
    # shellcheck source=/dev/null
    . <(sed '$d' "$INSTALLER")
    "step_$1" )
}
[[ "$(tail -n1 "$INSTALLER")" == 'main "$@"' ]] || { echo "the installer no longer ends in main \"\$@\" — fix step()"; exit 2; }

reset() { rm -f "$T/unit" "$T/whisper-service" "$T/active" "$T/loaded" "$T/systemctl.log" "$CFG"; }
legacy_unit() {  # a unit as every installer before this row wrote it
  printf '[Service]\nType=simple\nUser=claude\nEnvironment=WHISPER_MODEL=%s\nEnvironment=WHISPER_COMPUTE_TYPE=int8\n' "$1" > "$T/unit"
}
unit_model()  { sed -n 's/^Environment=WHISPER_MODEL=//p' "$T/unit" 2>/dev/null; }
unit_source() { sed -n 's/^# whisper-model-source: //p' "$T/unit" 2>/dev/null; }
setup()  { step service >/dev/null 2>&1; }
apply()  { step model >"$T/out" 2>&1; }
restarts() { grep -c '^restart\|^try-restart' "$T/systemctl.log" 2>/dev/null || true; }

echo "== setup picks base on every box =="
mem 3880000; reset; setup
t_eq "a 4 GB box: base" "$(unit_model)" "base"
t_eq "...recorded as 5dive's default" "$(unit_source)" "default"
mem 32000000; reset; setup
t_eq "a 32 GB box: base too" "$(unit_model)" "base"
mem 3880000

echo "== an explicit WHISPER_MODEL always wins =="
reset; WHISPER_MODEL=small step service >/dev/null 2>&1
t_eq "WHISPER_MODEL=small is kept" "$(unit_model)" "small"
t_eq "...recorded as set for that run" "$(unit_source)" "env"
apply
t_eq "...and a later run without it does not flip it back" "$(unit_model)" "small"

echo "== existing boxes: the next run re-applies the default (the nightly's path) =="
reset; legacy_unit small; touch "$T/active"; echo small > "$T/loaded"
apply; rc=$?
t_eq "a box on the old default small moves to base" "$(unit_model) $(unit_source)" "base default"
t_eq "...the running service is restarted onto it" "$(restarts)" "1"
t_eq "...and /health answers base" "$(curl -s x | jq -r .model)" "base"
t_eq "...rc 0" "$rc" "0"
: > "$T/systemctl.log"; apply
t_eq "...and the next run leaves it alone" "$(restarts)" "0"
reset; legacy_unit base; touch "$T/active"; echo base > "$T/loaded"
apply
t_eq "a unit someone set to base by hand stays base" "$(unit_model)" "base"
t_eq "...is NOT restarted for gaining its source line" "$(restarts)" "0"
reset; legacy_unit medium; touch "$T/active"; echo medium > "$T/loaded"
apply
t_eq "a unit someone set by hand (medium) is kept" "$(unit_model)" "medium"
t_eq "...and remembered as kept" "$(unit_source)" "kept"
t_eq "...no restart" "$(restarts)" "0"
reset; mkdir -p "$T/state"; printf 'whisper_model=small\n' > "$CFG"; legacy_unit small; touch "$T/active"; echo small > "$T/loaded"
apply
t_eq "an owner's whisper_model=small survives the nightly" "$(unit_model) $(unit_source)" "small owner"
t_eq "...no restart" "$(restarts)" "0"
printf 'whisper_model=auto\n' > "$CFG"; apply
t_eq "an owner's auto goes back to the default" "$(unit_model) $(unit_source)" "base default"

echo "== the step that applies a choice says so when the service never comes back on it =="
reset; printf 'whisper_model=small\n' > "$CFG"; legacy_unit base; touch "$T/active"; echo base > "$T/loaded"
cp "$T/bin/curl" "$T/curl.real"
printf '#!/usr/bin/env bash\nprintf "{\\"model\\": \\"stale\\"}\\n"\n' > "$T/bin/curl"
apply; rc=$?
t_eq "rc is non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
t_has "...and it names where to look" "$(cat "$T/out")" "journalctl -u whisper-service"
cp "$T/curl.real" "$T/bin/curl"

if [[ $EUID -ne 0 ]]; then
  echo "== the owner's switch: SKIPPED, not root — \`config set\` refuses a non-root caller by design; run: sudo -E bash $0"
else
echo "== the owner's switch: 5dive voice config set whisper_model =="
reset; mem 3880000; setup; touch "$T/active"; unit_model > "$T/loaded"
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "set small on a 4 GB box → rc 0" "$rc" "0"
t_eq "...the config records the owner's choice" "$(grep '^whisper_model=' "$CFG")" "whisper_model=small"
t_eq "...the unit loads it, as the owner's" "$(unit_model) $(unit_source)" "small owner"
t_eq "...and /health reports it" "$(curl -s x | jq -r .model)" "small"
t_has "...and the owner is told" "$out" "hears on small"
t_eq "get answers it" "$("$VOICE" config get whisper_model 2>/dev/null)" "small"
out=$("$VOICE" config set whisper_model base 2>&1); rc=$?
t_eq "set base → rc 0" "$rc" "0"
t_eq "...switches both ways" "$(curl -s x | jq -r .model)" "base"
"$VOICE" config set whisper_model auto >/dev/null 2>&1
t_eq "auto goes back to the default" "$(unit_model) $(unit_source)" "base default"
t_eq "...and the form reads auto" "$("$VOICE" config --json | jq -r .values.whisper_model)" "auto"

echo "== below the memory floor, small is refused =="
mem 1900000; cp "$CFG" "$T/cfg.before"
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "a 2 GB box refuses small (rc 1)" "$rc" "1"
t_has "...with the reason" "$out" "needs about"
t_eq "...and nothing was written" "$(cmp -s "$CFG" "$T/cfg.before" && echo same)" "same"
"$VOICE" config set whisper_model large >/dev/null 2>&1
t_eq "a model the form does not offer is refused (rc 2)" "$?" "2"
mem 3880000

echo "== no service on the box: the choice is kept for when there is one =="
reset
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "...no unit is invented" "$([[ -e "$T/unit" ]] && echo present || echo absent)" "absent"
setup
t_eq "...and setup then loads the owner's model" "$(unit_model) $(unit_source)" "small owner"
fi

echo "== the agent's guidance: offer the accurate model, warn it is slower =="
# The rendered section, not the installer's source: what an agent on the box
# actually reads. A v6 box (DIVE-5869) is rewritten, and a section a later
# release appended below it stays.
MD="$T/CLAUDE.md"
printf '# host\n\n<!-- 5dive-setup-voice: voice section v6 -->\n# Voice\n- old\n<!-- /5dive-setup-voice: voice section -->\n\n# Later section\n' > "$MD"
CLAUDE_MD="$MD" step claudemd >/dev/null 2>&1
sec=$(sed -n '/voice section v7 -->/,/\/5dive-setup-voice: voice section/p' "$MD")
t_has "a v6 box gets the v7 section" "$sec" "voice section v7"
t_no  "...the v6 one is gone" "$(cat "$MD")" "voice section v6"
t_has "...and the section below it stays" "$(cat "$MD")" "# Later section"
t_has "on a misheard note, the agent offers the more accurate model" "$sec" "offer the more accurate model"
t_has "...names a garbled or cut-off transcript as the other trigger" "$sec" "garbled or cut off"
t_has "...warns that hearing will be slower" "$sec" "2-3 times slower"
t_has "...with the exact switch" "$sec" "sudo 5dive voice config set whisper_model small"
t_has "...only on the owner's yes" "$sec" "Switch only after they say yes"
t_has "the reverse: hearing too slow → offer base" "$sec" "whisper_model base"
CLAUDE_MD="$MD" step claudemd >/dev/null 2>&1
t_eq "a second run does not append it twice" "$(grep -c 'voice section v7' "$MD")" "1"

# ---- the service itself (no root) -------------------------------------------
# whisper-service.py is run for real with a stub faster_whisper whose
# WhisperModel records what it was given and stops the script; a
# sitecustomize fakes the core count. The row's rule: base when the unit sets
# nothing, cpu_threads=min(cores, 8), WHISPER_CPU_THREADS overrides.
echo "== whisper-service.py: fallback model and cpu_threads"
SVC="$ROOT/voice/lib/whisper-service.py"
mkdir -p "$T/py/faster_whisper"
cat > "$T/py/faster_whisper/__init__.py" <<'PY'
import json, os
class WhisperModel:
    def __init__(self, name, **kw):
        with open(os.environ["STUB_OUT"], "w") as f:
            json.dump({"model": name, **kw}, f)
        raise SystemExit(0)
PY
cat > "$T/py/sitecustomize.py" <<'PY'
import os
n = os.environ.get("FAKE_NPROC")
if n:
    os.sched_getaffinity = lambda pid: set(range(int(n)))
    os.cpu_count = lambda: int(n)
PY
svc_run() { # <env...> — what WhisperModel was given, as JSON
  rm -f "$T/stub.json"
  env -u WHISPER_MODEL -u WHISPER_CPU_THREADS PYTHONPATH="$T/py" STUB_OUT="$T/stub.json" "$@" python3 "$SVC" >/dev/null 2>&1
  cat "$T/stub.json" 2>/dev/null || echo '{}'
}
if command -v python3 >/dev/null; then
  out=$(svc_run FAKE_NPROC=2)
  t_eq "no WHISPER_MODEL in the unit: the service loads base, not small" "$(jq -r .model <<<"$out")" "base"
  t_eq "a 2-core box: 2 threads (the library's 4 would oversubscribe)" "$(jq -r '.cpu_threads // "missing"' <<<"$out")" "2"
  t_eq "a 16-core box: capped at 8" "$(jq -r '.cpu_threads // "missing"' <<<"$(svc_run FAKE_NPROC=16)")" "8"
  t_eq "a 6-core box: 6" "$(jq -r '.cpu_threads // "missing"' <<<"$(svc_run FAKE_NPROC=6)")" "6"
  t_eq "WHISPER_CPU_THREADS overrides" "$(jq -r '.cpu_threads // "missing"' <<<"$(svc_run FAKE_NPROC=16 WHISPER_CPU_THREADS=12)")" "12"
  t_eq "an explicit WHISPER_MODEL=small is loaded as is" "$(jq -r .model <<<"$(svc_run FAKE_NPROC=4 WHISPER_MODEL=small)")" "small"
  t_has "/health reports the threads" "$(cat "$SVC")" '"threads": CPU_THREADS'
else
  t_fail "python3 is required for the service arms"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

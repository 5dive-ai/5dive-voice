#!/usr/bin/env bash
# tests/whisper-model.test.sh — DIVE-5897.
#
# Which whisper model hearing loads used to be the constant `small`. On a
# 2-vCPU / 4 GB box (5dive's Start) that hears a note in 9-12 s where base
# takes 3-4 s, so the default now follows the box's hardware, an owner can
# switch it with `sudo 5dive voice config set whisper_model`, and a later run
# (the nightly, a resize) re-applies the rule unless a person chose the model.
#
# These arms run the REAL installer and the REAL verb against scratch paths:
# the unit file, the service binary and the voice config are all under $T, and
# systemctl and curl are stubs that record what was asked and answer /health
# with whatever model the last restart loaded. The hardware is faked through
# VOICE_NPROC and VOICE_MEMINFO. Root is required (the installer refuses
# without it), as for the other write-path batteries; CI runs it with sudo.
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

if [[ $EUID -ne 0 ]]; then
  echo "skip: the installer refuses to run without root — run: sudo -E bash $0"
  exit 0
fi
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
box() {  # box <cpus> <MemTotal kB>
  export VOICE_NPROC="$1"; mem "$2"
}
export PATH="$T/bin:$PATH" VOICE_MEMINFO="$T/meminfo" VOICE_STATE_DIR="$T/state" \
  WHISPER_UNIT="$T/unit" WHISPER_SERVICE_BIN="$T/whisper-service" WHISPER_WAIT_SECS=4 \
  VOICE_LIB="$LIB"
unset WHISPER_MODEL
CFG="$T/state/config"

reset() { rm -f "$T/unit" "$T/whisper-service" "$T/active" "$T/loaded" "$T/systemctl.log" "$CFG"; }
legacy_unit() {  # a unit as every installer before this row wrote it
  printf '[Service]\nType=simple\nUser=claude\nEnvironment=WHISPER_MODEL=%s\nEnvironment=WHISPER_COMPUTE_TYPE=int8\n' "$1" > "$T/unit"
}
unit_model()  { sed -n 's/^Environment=WHISPER_MODEL=//p' "$T/unit" 2>/dev/null; }
unit_source() { sed -n 's/^# whisper-model-source: //p' "$T/unit" 2>/dev/null; }
setup()  { "$INSTALLER" service >/dev/null 2>&1; }
apply()  { "$INSTALLER" model >"$T/out" 2>&1; }
restarts() { grep -c '^restart\|^try-restart' "$T/systemctl.log" 2>/dev/null || true; }

echo "== setup picks the model from the box's own hardware =="
reset; box 2 3880000; setup
t_eq "2 vCPU / 4 GB (Start): base" "$(unit_model)" "base"
t_eq "...recorded as the box's rule" "$(unit_source)" "box"
reset; box 4 7800000; setup
t_eq "4 vCPU / 8 GB (Start Plus): small" "$(unit_model)" "small"
reset; box 4 3880000; setup
t_eq "4 vCPU but 4 GB: base (memory alone decides it)" "$(unit_model)" "base"
reset; box 2 16000000; setup
t_eq "2 vCPU with 16 GB: base (CPUs alone decide it)" "$(unit_model)" "base"
reset; export VOICE_NPROC=8; VOICE_MEMINFO="$T/absent" setup
t_eq "a box whose memory cannot be read: base, the one that cannot be slow" "$(unit_model)" "base"

echo "== an explicit WHISPER_MODEL always wins =="
reset; box 2 3880000; WHISPER_MODEL=small "$INSTALLER" service >/dev/null 2>&1
t_eq "WHISPER_MODEL=small on a 2 vCPU / 4 GB box is kept" "$(unit_model)" "small"
t_eq "...recorded as set for that run" "$(unit_source)" "env"
apply
t_eq "...and a later run without it does not flip it back" "$(unit_model)" "small"

echo "== existing boxes: the next run re-applies the rule (the nightly's path) =="
reset; box 2 3880000; legacy_unit small; touch "$T/active"; echo small > "$T/loaded"
apply; rc=$?
t_eq "a Start box on the old default small moves to base" "$(unit_model)" "base"
t_eq "...the running service is restarted onto it" "$(restarts)" "1"
t_eq "...and /health answers base" "$(curl -s x | jq -r .model)" "base"
t_eq "...rc 0" "$rc" "0"
reset; box 4 7800000; legacy_unit small; touch "$T/active"; echo small > "$T/loaded"
apply
t_eq "a bigger box on small stays on small" "$(unit_model)" "small"
t_eq "...gains the source line" "$(unit_source)" "box"
t_eq "...and is NOT restarted for it" "$(restarts)" "0"
reset; box 2 3880000; legacy_unit medium; touch "$T/active"; echo medium > "$T/loaded"
apply
t_eq "a unit someone set by hand (medium) is kept" "$(unit_model)" "medium"
t_eq "...and remembered as kept" "$(unit_source)" "kept"
t_eq "...no restart" "$(restarts)" "0"

echo "== a resized box follows its new size, unless a person chose =="
reset; box 2 3880000; setup; touch "$T/active"; unit_model > "$T/loaded"
box 4 7800000; apply
t_eq "Start → Start Plus: base becomes small" "$(unit_model)" "small"
box 2 3880000; apply
t_eq "...and back down: small becomes base" "$(unit_model)" "base"

echo "== the owner's switch: 5dive voice config set whisper_model =="
reset; box 2 3880000; setup; touch "$T/active"; unit_model > "$T/loaded"
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "set small on a 4 GB box → rc 0" "$rc" "0"
t_eq "...the config records the owner's choice" "$(grep '^whisper_model=' "$CFG")" "whisper_model=small"
t_eq "...the unit loads it, as the owner's" "$(unit_model) $(unit_source)" "small owner"
t_eq "...and /health reports it" "$(curl -s x | jq -r .model)" "small"
t_has "...and the owner is told" "$out" "hears on small"
apply
t_eq "a later nightly keeps the owner's small on a Start box" "$(unit_model)" "small"
t_eq "get answers it" "$("$VOICE" config get whisper_model 2>/dev/null)" "small"
out=$("$VOICE" config set whisper_model base 2>&1); rc=$?
t_eq "set base → rc 0" "$rc" "0"
t_eq "...switches both ways" "$(curl -s x | jq -r .model)" "base"
box 4 7800000; "$VOICE" config set whisper_model auto >/dev/null 2>&1
t_eq "auto goes back to the box's rule (here: small)" "$(unit_model) $(unit_source)" "small box"
t_eq "...and the form reads auto" "$("$VOICE" config --json | jq -r .values.whisper_model)" "auto"

echo "== below the memory floor, small is refused =="
box 2 1900000; cp "$CFG" "$T/cfg.before"
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "a 2 GB box refuses small (rc 1)" "$rc" "1"
t_has "...with the reason" "$out" "needs about"
t_eq "...and nothing was written" "$(cmp -s "$CFG" "$T/cfg.before" && echo same)" "same"
"$VOICE" config set whisper_model large >/dev/null 2>&1
t_eq "a model the form does not offer is refused (rc 2)" "$?" "2"

echo "== the switch says so when the service never comes back on the new model =="
box 4 7800000; "$VOICE" config set whisper_model base >/dev/null 2>&1
printf '#!/usr/bin/env bash\nprintf "{\\"model\\": \\"stale\\"}\\n"\n' > "$T/bin/curl"
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "rc is non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
t_has "...and it names where to look" "$out" "journalctl -u whisper-service"

echo "== no service on the box: the choice is kept for when there is one =="
reset; box 2 3880000
out=$("$VOICE" config set whisper_model small 2>&1); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "...no unit is invented" "$([[ -e "$T/unit" ]] && echo present || echo absent)" "absent"
setup
t_eq "...and setup then loads the owner's model" "$(unit_model) $(unit_source)" "small owner"

echo "== the agent's guidance: offer the accurate model, warn it is slower =="
# The rendered section, not the installer's source: what an agent on the box
# actually reads. A v6 box (DIVE-5869) is rewritten, and a section a later
# release appended below it stays.
MD="$T/CLAUDE.md"
printf '# host\n\n<!-- 5dive-setup-voice: voice section v6 -->\n# Voice\n- old\n<!-- /5dive-setup-voice: voice section -->\n\n# Later section\n' > "$MD"
CLAUDE_MD="$MD" "$INSTALLER" claudemd >/dev/null 2>&1
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
CLAUDE_MD="$MD" "$INSTALLER" claudemd >/dev/null 2>&1
t_eq "a second run does not append it twice" "$(grep -c 'voice section v7' "$MD")" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

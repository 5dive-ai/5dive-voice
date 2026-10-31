#!/usr/bin/env bash
# tests/edge-heal.test.sh — DIVE-7409.
#
# edge-tts-heal is what 5dive-speak runs when Microsoft refuses the box's
# edge-tts. It must upgrade edge-tts, say whether the version changed (the only
# case worth a retry), and try at most once an hour so a box whose voice stays
# broken does not run pip on every reply. A stand-in pip in a scratch venv
# records each install and "upgrades" to $NEXT.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-heal-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

HEAL="$ROOT/voice/lib/edge-tts-heal.sh"
V="$T/venv"; mkdir -p "$V/bin"
printf '#!/bin/sh\n' > "$V/bin/edge-tts"
cat > "$V/bin/pip" <<STUB
#!/usr/bin/env bash
case "\$1" in
  show) echo "Name: edge-tts"; echo "Version: \$(cat "$T/ver")" ;;
  install) echo "\$*" >> "$T/installs"; [[ "\${PIP_RC:-0}" == 0 ]] || exit "\$PIP_RC"
           [[ -z "\${NEXT:-}" ]] || echo "\$NEXT" > "$T/ver" ;;
esac
STUB
chmod +x "$V/bin/edge-tts" "$V/bin/pip"

heal() { VOICE_VENV="$V" VOICE_HEAL_STATE="$T/state/heal" bash "$HEAL" 2>/dev/null; }
reset() { rm -rf "$T/state" "$T/installs"; : > "$T/installs"; echo 7.3.1 > "$T/ver"; }

echo "== a newer edge-tts is on PyPI =="
reset
NEXT=7.4.0 heal; rc=$?
t_eq "rc 0: the version changed, retry the reply" "$rc" "0"
t_eq "pip ran once" "$(wc -l < "$T/installs")" "1"
t_eq "it asked for the floor, upgraded" "$(cat "$T/installs")" "install --quiet --disable-pip-version-check --upgrade edge-tts>=7.3.1"
t_eq "edge-tts is now the new one" "$(cat "$T/ver")" "7.4.0"

echo "== another reply fails a minute later =="
NEXT=7.5.0 heal; rc=$?
t_eq "rc 0: that upgrade just happened, retry with it" "$rc" "0"
t_eq "pip did not run again" "$(wc -l < "$T/installs")" "1"

echo "== already the newest =="
reset
heal; rc=$?
t_eq "rc 1: nothing changed, do not retry" "$rc" "1"
t_eq "pip ran once" "$(wc -l < "$T/installs")" "1"
heal; rc=$?
t_eq "rc 75 within the hour" "$rc" "75"
t_eq "pip did not run again" "$(wc -l < "$T/installs")" "1"

echo "== an hour later it tries again =="
printf '%s 0\n' "$(( $(date +%s) - 3601 ))" > "$T/state/heal"
NEXT=7.4.0 heal; rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "pip ran a second time" "$(wc -l < "$T/installs")" "2"

echo "== an upgrade that changed the version, but long ago =="
printf '%s 1\n' "$(( $(date +%s) - 900 ))" > "$T/state/heal"
heal; rc=$?
t_eq "rc 75: not a fresh upgrade, do not retry" "$rc" "75"

echo "== PyPI is unreachable =="
reset
PIP_RC=1 NEXT=7.4.0 heal; rc=$?
t_eq "rc 1" "$rc" "1"
t_eq "the old edge-tts is kept" "$(cat "$T/ver")" "7.3.1"
heal; rc=$?
t_eq "the failed try still counts for the hour (rc 75)" "$rc" "75"

echo "== no edge-tts venv on this box =="
VOICE_VENV="$T/nowhere" VOICE_HEAL_STATE="$T/state/heal" bash "$HEAL" 2>/dev/null; rc=$?
t_eq "rc 2, nothing installed" "$rc" "2"

echo "== it takes no arguments into pip =="
reset
NEXT=7.4.0 VOICE_VENV="$V" VOICE_HEAL_STATE="$T/state/heal" bash "$HEAL" 'evil==1.0' 2>/dev/null
t_eq "an argument never reaches pip" "$(cat "$T/installs")" "install --quiet --disable-pip-version-check --upgrade edge-tts>=7.3.1"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))

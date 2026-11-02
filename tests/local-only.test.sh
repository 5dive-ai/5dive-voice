#!/usr/bin/env bash
# tests/local-only.test.sh — DIVE-7559.
#
# Local-only mode (/etc/5dive/local-only EXISTS, written by `sudo 5dive config
# local-only on`) means nothing may leave the office network. Both voices are
# online services: the "local" voice, edge-tts, is Microsoft's, and OpenRouter
# is a cloud. So under the flag:
#   - 5dive-speak refuses (exit 3, "text only") and calls NEITHER voice;
#   - hearing runs on this box even when the config says openrouter;
#   - edge-tts-heal never runs pip;
#   - `5dive voice backend openrouter` is refused (root arm);
#   - `5dive voice` status says speaking is off.
# Every arm has its flag-absent control beside it, so a green is not vacuous.
# FIVE_LOCAL_ONLY_FILE points the flag at a temp path (the CLI's own seam).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-local-only-test.XXXXXX)"
trap 'rc=$?; rm -rf "$T"; exit $rc' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

LIB="$ROOT/voice/lib/voice-backend.sh"
SPEAK="$ROOT/voice/lib/5dive-speak.sh"
HEAL="$ROOT/voice/lib/edge-tts-heal.sh"
VERB="$ROOT/voice/bin/voice"
FLAG="$T/local-only"; : > "$FLAG"
NOFLAG="$T/no-such-flag"

# Stand-ins that count: edge-tts (Microsoft), curl (OpenRouter), ffmpeg.
mkdir -p "$T/bin" "$T/conn"
cat > "$T/bin/edge-tts" <<STUB
#!/usr/bin/env bash
echo x >> "$T/edge-calls"
out=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == --write-media ]] && out="\$2"; shift; done
printf 'fake-mp3' > "\$out"
STUB
cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
echo x >> "$T/curl-calls"; exit 7
STUB
cat > "$T/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
printf 'OggS-fake' > "${@: -1}"
STUB
chmod +x "$T/bin/"*
printf 'OPENROUTER_API_KEY=sk-or-v1-0123456789abcdef\n' > "$T/conn/openrouter.env"
printf 'backend=openrouter\n' > "$T/config-or"

speak() {  # speak <flag-path> [--backend=...]
  : > "$T/edge-calls"; : > "$T/curl-calls"; rm -f "$T/out.ogg"
  PATH="$T/bin:$PATH" VOICE_LIB="$LIB" FIVE_LOCAL_ONLY_FILE="$1" \
    VOICE_CONFIG="$T/none" VOICE_PLUGINS_JSON="$T/none.json" VOICE_EDGE_HEAL="$T/no-heal" \
    bash "$SPEAK" "${@:2}" --voice=en-US-AriaNeural --out="$T/out.ogg" "Hello from the office."
}
calls() { wc -l < "$1" | tr -d ' '; }

echo "== speaking: flag absent (control) =="
out=$(speak "$NOFLAG" --backend=local 2>"$T/err"); rc=$?
t_eq "rc 0" "$rc" "0"
t_eq "edge-tts (Microsoft) was called" "$(calls "$T/edge-calls")" "1"
t_eq "the .ogg path is printed" "$out" "$T/out.ogg"

echo "== speaking: local-only on =="
for b in local openrouter; do
  out=$(speak "$FLAG" --backend=$b 2>"$T/err"); rc=$?
  t_eq "[$b] rc 3: voice replies are off" "$rc" "3"
  t_eq "[$b] edge-tts (Microsoft) was NOT called" "$(calls "$T/edge-calls")" "0"
  t_eq "[$b] curl (OpenRouter) was NOT called" "$(calls "$T/curl-calls")" "0"
  t_eq "[$b] no path printed" "$out" ""
  t_has "[$b] the agent is told to answer in text" "$(cat "$T/err")" "Answer in text only"
  t_has "[$b] ... and why" "$(cat "$T/err")" "local-only mode"
done

echo "== hearing: a box configured for openrouter =="
eff() {  # eff <flag-path> <fn>
  ( FIVE_LOCAL_ONLY_FILE="$1" VOICE_CONFIG="$T/config-or" VOICE_CONNECTORS_DIR="$T/conn" \
      VOICE_SEEDED_ACCOUNT_ENV="$T/none.env"; . "$LIB"; "$2" ) 2>"$T/err"
}
t_eq "flag absent: hearing runs on openrouter (control)" "$(eff "$NOFLAG" voice_effective_stt_backend)" "openrouter"
t_eq "flag absent: speaking runs on openrouter (control)" "$(eff "$NOFLAG" voice_effective_backend)" "openrouter"
t_eq "local-only: hearing runs on this box" "$(eff "$FLAG" voice_effective_stt_backend)" "local"
t_has "local-only: ... and says why" "$(cat "$T/err")" "local-only mode is on"
t_eq "local-only: the backend reads local" "$(eff "$FLAG" voice_effective_backend)" "local"

echo "== edge-tts-heal: no pip under local-only =="
V="$T/venv"; mkdir -p "$V/bin"
printf '#!/bin/sh\n' > "$V/bin/edge-tts"
cat > "$V/bin/pip" <<STUB
#!/usr/bin/env bash
case "\$1" in
  show) echo "Version: 7.3.1" ;;
  install) echo "\$*" >> "$T/pip-installs" ;;
esac
STUB
chmod +x "$V/bin/edge-tts" "$V/bin/pip"
heal() { : > "$T/pip-installs"; rm -rf "$T/state"; FIVE_LOCAL_ONLY_FILE="$1" VOICE_VENV="$V" VOICE_HEAL_STATE="$T/state/heal" bash "$HEAL" 2>/dev/null; }
heal "$NOFLAG"
t_eq "flag absent: pip ran (control)" "$(calls "$T/pip-installs")" "1"
heal "$FLAG"; rc=$?
t_eq "local-only: rc 2 (nothing to heal)" "$rc" "2"
t_eq "local-only: pip never ran" "$(calls "$T/pip-installs")" "0"

echo "== setup: no edge-tts under local-only =="
pipstep=$(sed -n '/^step_pip() {/,/^}/p' "$ROOT/voice/bin/5dive-setup-voice")
branch=$(sed -n '/local-only/,/return 0/p' <<<"$pipstep")
t_has "the pip step has a local-only branch" "$branch" 'install --quiet --upgrade faster-whisper'
[[ "$branch" != *edge-tts\>=* ]] && t_ok "... which installs no edge-tts" || t_fail "... which installs no edge-tts" "$branch"
[[ $(grep -n 'FIVE_LOCAL_ONLY_FILE' <<<"$pipstep" | head -1 | cut -d: -f1) -lt $(grep -n "'edge-tts>=" <<<"$pipstep" | head -1 | cut -d: -f1) ]] \
  && t_ok "... and it comes before the edge-tts install" || t_fail "... and it comes before the edge-tts install"

echo "== the verb's status =="
st() { FIVE_LOCAL_ONLY_FILE="$1" VOICE_LIB="$LIB" VOICE_CONFIG="$T/none" PATH="$T/bin:$PATH" bash "$VERB" 2>&1; }
t_has "local-only: status says speaking is off" "$(st "$FLAG")" "speaking: off (local-only mode)"
[[ "$(st "$NOFLAG")" != *"speaking: off"* ]] && t_ok "flag absent: status is unchanged (control)" || t_fail "flag absent: status is unchanged (control)"

if [[ $EUID -eq 0 ]]; then
  echo "== root: switching to openrouter =="
  out=$(FIVE_LOCAL_ONLY_FILE="$FLAG" VOICE_LIB="$LIB" VOICE_STATE_DIR="$T/state-root" VOICE_CONFIG="$T/cfg-root" VOICE_CONNECTORS_DIR="$T/conn" \
        VOICE_SEEDED_ACCOUNT_ENV="$T/none.env" bash "$VERB" backend openrouter 2>&1); rc=$?
  t_eq "local-only: refused" "$rc" "1"
  t_has "local-only: ... saying why" "$out" "local-only mode is on"
  [[ ! -s "$T/cfg-root" ]] && t_ok "local-only: the config was not written" || t_fail "local-only: the config was not written" "$(cat "$T/cfg-root")"
  out=$(FIVE_LOCAL_ONLY_FILE="$NOFLAG" VOICE_LIB="$LIB" VOICE_STATE_DIR="$T/state-root" VOICE_CONFIG="$T/cfg-root" VOICE_CONNECTORS_DIR="$T/conn" \
        VOICE_SEEDED_ACCOUNT_ENV="$T/none.env" bash "$VERB" backend openrouter 2>&1); rc=$?
  t_eq "flag absent: the switch goes through (control)" "$rc" "0"
  t_has "flag absent: ... and is written" "$(cat "$T/cfg-root" 2>/dev/null)" "backend=openrouter"
else
  echo "  skip root arm (run under sudo -E for the backend switch)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

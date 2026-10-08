#!/usr/bin/env bash
# tests/verb-setup.test.sh — DIVE-4495.
#
# The row: `voice` was a listed, installable, official-review plugin whose HOST
# HALF could not be installed on a box that 5dive did not provision itself. The
# manifest pointed at a bare `5dive-setup-voice`, and that program is written by
# 5dive-api's own box installer (scripts/install/users.sh) and by nothing else —
# so `plugin add` said installed, `5dive voice` reported MISSING forever, and
# both the terminal hint and the dashboard button named a command that was not
# there.
#
# These arms grade the property that fixes it: THE PLUGIN CARRIES ITS OWN
# INSTALLER, and the command the manifest names is reachable from what
# `plugin add` puts on the box. They are offline and argv-only; the engine's
# behaviour (what the wrappers do once installed) is graded in 5dive-api's
# scripts/test-voice-backend.test.sh and is deliberately not restated here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-setup-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

VOICE="$ROOT/voice/bin/voice"
INSTALLER="$ROOT/voice/bin/5dive-setup-voice"
M="$ROOT/voice/.claude-plugin/plugin.json"
command -v jq >/dev/null || { echo "jq required"; exit 2; }

echo "== the plugin ships the installer =="
[[ -f "$INSTALLER" ]] && t_ok "voice/bin/5dive-setup-voice exists in the plugin tree" \
  || t_fail "voice/bin/5dive-setup-voice exists in the plugin tree" "the host half is unshippable again"
[[ -x "$INSTALLER" ]] && t_ok "...and is executable, so the copy plugin add makes can run" \
  || t_fail "...and is executable" "plugin add preserves the mode; a 644 installer cannot be exec'd"

# THE ARM THAT IS THE ROW. `setup.command`'s program must be something that is
# on a box before this plugin's own files are — otherwise the manifest is naming
# a program only 5dive's provisioner writes, which is exactly the defect.
echo "== the manifest names a command that is actually reachable =="
cmd=$(jq -r '.fivedive.setup.command' "$M")
t_no "setup.command no longer names the bare program nothing installs" "$cmd" "sudo 5dive-setup-voice"
# The program a line would exec: drop a leading sudo and its flags, take the
# next word. (The same resolution DIVE-4491's preflight does, restated here at
# argv level because THIS repo cannot import the CLI's.)
prog=$(awk '{ i=1; if ($i=="sudo") { i++; while ($i ~ /^-/) i++ } print $i }' <<<"$cmd")
t_eq "the program it would exec is the 5dive CLI itself, which every box has" "$prog" "5dive"
t_has "and it self-elevates, per the DIVE-4475 contract (written for a non-root caller)" "$cmd" "sudo "
# Contract §4: an unbumped version fetches nothing on an already-installed box,
# so the fix would ship to no one.
t_no "the version is bumped past the release that shipped no installer" "$(jq -r '.version' "$M")" "1.1.0"
t_no "...and past the one before it" "$(jq -r '.version' "$M")" "1.0.0"
t_has "the hint tells the reader the installer comes with the plugin" "$(jq -r '.fivedive.setup.hint' "$M")" "ships the installer"

echo "== the verb routes setup to the sibling installer =="
out=$("$VOICE" setup --help 2>&1); rc=$?
t_eq "'voice setup' is a known subcommand, not exit 64" "$rc" "0"
t_has "...and what answered is the installer, not the verb's own help" "$out" "all|apt|pip|service|wrapper|state|claudemd"
t_has "...whose usage names the command a user was told to paste" "$out" "sudo 5dive voice setup"
t_no "...and never the old bare name" "$out" "sudo 5dive-setup-voice"

# An incomplete install must say which file is missing and how to repair it,
# because the symptom without this is identical to the bug the row closed.
echo "== an incomplete plugin tree refuses, and names the repair =="
mkdir -p "$T/half/bin"; cp "$VOICE" "$T/half/bin/voice"
out=$("$T/half/bin/voice" setup --help 2>&1); rc=$?
t_eq "verb with no installer beside it → non-zero" "$rc" "1"
t_has "...and names the missing file" "$out" "5dive-setup-voice"
t_has "...and the repair" "$out" "plugin upgrade voice"

echo "== every payload the installer writes is actually shipped =="
# Derived from the installer's own source, not from a hand-kept list: a payload
# added there and not added to voice/lib/ is the failure this arm exists for.
# The leading [A-Za-z0-9_] is load-bearing: the installer documents the helper
# as `payload <name>`, and a looser pattern matches that placeholder and then
# fails on a file called "".
mapfile -t payloads < <(grep -oE 'payload [A-Za-z0-9_][A-Za-z0-9_.-]*' "$INSTALLER" | awk '{print $2}' | sort -u)
t_no "the installer references at least one payload" "${#payloads[@]}" "0"
for f in "${payloads[@]}"; do
  [[ -f "$ROOT/voice/lib/$f" ]] && t_ok "voice/lib/$f is shipped" \
    || t_fail "voice/lib/$f is shipped" "the installer reads it at run time and it is not in the tree"
done
t_has "the installer reads them from a sibling dir, not from an @include pass this repo has no preprocessor for" \
  "$(cat "$INSTALLER")" 'PAYLOAD_DIR'
# Anchored at line start: an @-include that survived the port is a directive on
# its own line, and a substring match would red on prose that merely names it.
t_eq "no unexpanded @-include directive survived the port" \
  "$(grep -cE '^[[:space:]]*# @include' "$INSTALLER")" "0"

echo "== the installer is written for a non-root caller =="
if [[ $EUID -ne 0 ]]; then
  out=$("$INSTALLER" all 2>&1); rc=$?
  t_eq "run without root → refuses" "$rc" "1"
  t_has "...naming the line to paste" "$out" "sudo 5dive voice setup"
else
  echo "  skip (running as root — the non-root refusal arm needs an unprivileged uid)"
fi

echo "== a missing payload is refused BEFORE anything is installed =="
# The preflight is after require_root, so this arm needs root. It is the one
# that matters: half an engine (service enabled, wrappers absent) reports
# MISSING from `5dive voice` and looks exactly like the bug this row closed.
if [[ $EUID -eq 0 ]]; then
  mkdir -p "$T/broken/bin" "$T/broken/lib"
  cp "$INSTALLER" "$T/broken/bin/"
  cp "$ROOT"/voice/lib/* "$T/broken/lib/"
  rm -f "$T/broken/lib/5dive-transcribe.sh"
  # `apt` is the FIRST step and the cheapest to observe: on a box that already
  # has ffmpeg it is a no-op that prints "already present", so if the preflight
  # is absent this arm sees success rather than a slow install.
  out=$("$T/broken/bin/5dive-setup-voice" apt 2>&1); rc=$?
  t_eq "a payload missing from the tree → refuses" "$rc" "1"
  t_has "...naming the file" "$out" "5dive-transcribe.sh"
  t_has "...and the repair" "$out" "plugin upgrade voice"
  t_no "...and step 1 never ran" "$out" "Step 1/6"
else
  echo "  skip (needs root — the preflight sits behind require_root)"
fi

echo "== the pip step holds PyAV below 19 (2026-10-02) =="
# PyAV 19 dropped av.open(metadata_errors=), which faster-whisper 1.2.1 passes:
# with av unpinned every transcribe on a fresh box 500s.
pipline=$(grep -E 'pip" install .*faster-whisper' "$INSTALLER")
t_has "the faster-whisper install pins av<19" "$pipline" "'av<19'"

echo "== the agent section asks for a voice reply only when the user spoke (DIVE-5397) =="
# v4 said "ALWAYS send the text reply first ... then the voice attachment", so
# agents sent a voice note after every reply, typed messages included. The v4 to
# v5 and v5 to v6 upgrades are graded in 5dive-api's scripts/test-voice-backend.test.sh.
inst=$(cat "$INSTALLER")
t_no  "the 'ALWAYS ... voice attachment' wording is gone" "$inst" "ALWAYS send the text reply first"
t_has "a typed message gets text only" "$inst" "a typed message gets a text reply only — no voice note"
t_has "the section is v6, so a v4 or v5 box is rewritten" "$inst" 'MARKER="<!-- 5dive-setup-voice: voice section v6 -->"'
t_has "...and it names the hearing settings, so an agent points at them instead of patching the plugin (DIVE-5869)" "$inst" "sudo 5dive voice config set stt_fast 1"

echo "== a venv left with no pip is rebuilt on the next run (DIVE-5614) =="
# solar-shell, 2026-10-05: the first run's `python3 -m venv` failed at ensurepip
# (no python3-venv) after making the directory, and step_pip only created a venv
# whose DIRECTORY was missing — so every retry ran a pip that did not exist.
# The same arms as 5dive-api scripts/test-voice-backend.test.sh, on this copy.
# python3, the venv's python and pip are stubs; "ensurepip present" is a flag
# file, the way python3-venv being installed is on a real box.
VF="$T/venvfix"; mkdir -p "$VF/bin"
cat > "$VF/bin/python3" <<'FAKEPY'
#!/usr/bin/env bash
vf=@VF@
echo "python3 $*" >> "$vf/calls.log"
if [[ "$1" == -c ]]; then [[ -e "$vf/ensurepip" ]]; exit; fi
if [[ "$1 $2" == "-m venv" ]]; then
  shift 2
  if [[ "$1" == --clear ]]; then shift; rm -rf "${1:?}"/*; fi
  mkdir -p "$1/bin"; cp "$vf/venvpython" "$1/bin/python"
  [[ -e "$vf/ensurepip" ]] || exit 1
  cp "$vf/venvpip" "$1/bin/pip"
fi
FAKEPY
cat > "$VF/venvpython" <<'FAKEPY'
#!/usr/bin/env bash
vf=@VF@
echo "venv-python $*" >> "$vf/calls.log"
[[ "$*" == "-m ensurepip"* && -e "$vf/ensurepip" ]] && cp "$vf/venvpip" "$(dirname "$0")/pip"
FAKEPY
printf '#!/usr/bin/env bash\necho "pip $*" >> @VF@/calls.log\n' > "$VF/venvpip"
printf '#!/usr/bin/env bash\necho "apt-get $*" >> @VF@/calls.log\n[[ "$*" == *"install -y -qq python3-venv"* ]] && touch @VF@/ensurepip\nexit 0\n' > "$VF/bin/apt-get"
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$VF/bin/runuser"
sed -i "s#@VF@#$VF#g" "$VF/bin/python3" "$VF/venvpython" "$VF/venvpip" "$VF/bin/apt-get"
chmod 755 "$VF/bin/"* "$VF/venvpython" "$VF/venvpip"
venv_run() {  # <ensurepip: yes|no> -> runs step_pip once against $VF/venv in a subshell
  rm -f "$VF/calls.log" "$VF/ensurepip"; [[ "$1" == yes ]] && touch "$VF/ensurepip"
  ( set -euo pipefail
    PATH="$VF/bin:$PATH"; VENV="$VF/venv"
    eval "$(grep -E '^B=' "$INSTALLER")"
    eval "$(sed -n '/^say()/p; /^ok()/p; /^warn()/p; /^die()/p' "$INSTALLER")"
    eval "$(awk '/^as_claude\(\)/,/^}$/' "$INSTALLER")"
    eval "$(awk '/^step_pip\(\)/,/^}$/' "$INSTALLER")"
    step_pip ) >/dev/null 2>&1
}
# The box as the journal shows it: the directory, nothing usable in it, and no python3-venv.
rm -rf "$VF/venv"; mkdir -p "$VF/venv/lib"
venv_run no; rc=$?
calls="$(cat "$VF/calls.log" 2>/dev/null)"
t_eq  "A VENV DIRECTORY WITH NO pip IS REBUILT: step_pip exits 0" "$rc" "0"
t_has "...python3-venv is installed first" "$calls" "apt-get install -y -qq python3-venv"
t_has "...the venv is recreated over the half-made directory" "$calls" "python3 -m venv --clear $VF/venv"
t_has "...and faster-whisper is installed into it" "$calls" "pip install --quiet --upgrade faster-whisper edge-tts av<19"
# A venv whose python works but whose pip is gone gets pip back in place, and
# keeps whatever is installed in it.
rm -rf "$VF/venv"; mkdir -p "$VF/venv/bin"; cp "$VF/venvpython" "$VF/venv/bin/python"; touch "$VF/venv/kept"
venv_run yes; rc=$?
calls="$(cat "$VF/calls.log" 2>/dev/null)"
t_eq  "a venv with python but no pip: exit 0" "$rc" "0"
t_has "...pip is restored in place" "$calls" "venv-python -m ensurepip --upgrade --default-pip"
t_no  "...without wiping the venv" "$calls" "--clear"
[[ -e "$VF/venv/kept" ]] && t_ok "...whose contents survive" || t_fail "...whose contents survive" "the venv was cleared"
t_no  "...and no apt when ensurepip is already there" "$calls" "apt-get"
# A healthy venv costs nothing but the pip install.
venv_run yes; rc=$?
calls="$(cat "$VF/calls.log" 2>/dev/null)"
t_no  "a healthy venv is not recreated" "$calls" "-m venv"
t_no  "...nor its pip reinstalled" "$calls" "ensurepip --upgrade"
t_has "...it only gets the pip install" "$calls" "pip install --quiet"
# If python3-venv still cannot be had, say so instead of exec'ing a missing pip.
rm -rf "$VF/venv"; mkdir -p "$VF/venv"
printf '#!/usr/bin/env bash\necho "apt-get $*" >> %s/calls.log\nexit 0\n' "$VF" > "$VF/bin/apt-get"
venv_run no; rc=$?
calls="$(cat "$VF/calls.log" 2>/dev/null)"
t_no  "a venv still with no pip after creation fails the step" "$rc" "0"
t_no  "...before running a pip that is not there" "$calls" "pip install"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

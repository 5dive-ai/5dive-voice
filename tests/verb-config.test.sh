#!/usr/bin/env bash
# tests/verb-config.test.sh — DIVE-4875.
#
# `5dive voice config` is what the dashboard's settings form reads and writes,
# so these arms grade the protocol the manifest's `fivedive.settings` promises:
# `config --json` answers every declared key with the value the engine will
# actually use, and `config set` refuses anything the declaration does not allow
# before a byte is written. Offline: no box, no credential, no spend.
#
# Unlike verb-backend.test.sh this runs against the REAL engine library
# (voice/lib/voice-backend.sh, in this repo since DIVE-4495), pointed at a
# throwaway state and connector directory — so a default that drifts between
# the manifest and the engine is caught here, not on a box.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/voice-config-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
t_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
t_fail() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; FAIL=$((FAIL+1)); }
t_has()  { [[ "$2" == *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] lacks [$3]"; }
t_no()   { [[ "$2" != *"$3"* ]] && t_ok "$1" || t_fail "$1" "[$2] unexpectedly has [$3]"; }
t_eq()   { [[ "$2" == "$3" ]] && t_ok "$1" || t_fail "$1" "want [$3] got [$2]"; }

command -v jq >/dev/null || { echo "jq required"; exit 2; }
VOICE="$ROOT/voice/bin/voice"
M="$ROOT/voice/.claude-plugin/plugin.json"
LIB="$ROOT/voice/lib/voice-backend.sh"
[[ -x "$VOICE" ]] || { echo "voice/bin/voice is not executable"; exit 2; }

export VOICE_STATE_DIR="$T/state/voice" VOICE_CONNECTORS_DIR="$T/conn"
mkdir -p "$VOICE_STATE_DIR" "$VOICE_CONNECTORS_DIR"
CFG="$VOICE_STATE_DIR/config"
run() { VOICE_LIB="$LIB" "$VOICE" "$@"; }

echo "== the declaration the dashboard draws its form from =="
t_eq "settings are reached through a verb this plugin actually declares" \
  "$(jq -r '.fivedive.settings.verb as $v | [.fivedive.verbs[].name] | index($v) != null' "$M")" "true"
t_eq "the seven knobs are declared, backend first" \
  "$(jq -r '[.fivedive.settings.fields[].key] | join(",")' "$M")" "backend,stt_backend,stt_language,stt_fast,stt_model,tts_model,tts_voice"
t_eq "every field carries a key, a label and a known type" \
  "$(jq -r '[.fivedive.settings.fields[] | (.key|type)=="string" and (.label|type)=="string" and (.type=="enum" or .type=="string")] | all' "$M")" "true"
t_eq "every enum names its options" \
  "$(jq -r '[.fivedive.settings.fields[] | select(.type=="enum") | (.options|length) > 0] | all' "$M")" "true"
t_eq "the OpenRouter key is NOT a setting — it is a secret and lives in the connector store" \
  "$(jq -r '[.fivedive.settings.fields[].key | test("key|token|secret"; "i")] | any' "$M")" "false"
# The manifest's `default` is what the form shows before anything is set; the
# engine's default is what actually runs. One of them drifting is a form that
# lies about the box, so they are pinned to each other here.
( . "$LIB"
  for pair in "stt_model:$VOICE_DEFAULT_STT_MODEL" "tts_model:$VOICE_DEFAULT_TTS_MODEL" "tts_voice:$VOICE_DEFAULT_TTS_VOICE" "backend:local"; do
    k="${pair%%:*}"; want="${pair#*:}"
    got=$(jq -r --arg k "$k" '.fivedive.settings.fields[] | select(.key==$k) | .default' "$M")
    [[ "$got" == "$want" ]] && echo "ok $k" || echo "DRIFT $k manifest=$got engine=$want"
  done ) > "$T/defaults"
t_no "manifest defaults equal the engine's defaults" "$(cat "$T/defaults")" "DRIFT"

echo "== without the engine, --json still answers in JSON, and says why =="
out=$(VOICE_LIB="$T/absent.sh" "$VOICE" config --json 2>/dev/null); rc=$?
t_eq "no engine → non-zero" "$rc" "1"
t_eq "no engine → parseable, ok:false" "$(jq -r '.ok' <<<"$out" 2>/dev/null)" "false"
t_eq "...with a reason the dashboard can act on" "$(jq -r '.reason' <<<"$out" 2>/dev/null)" "engine_missing"

echo "== reading =="
rm -f "$CFG"
out=$(run config --json 2>/dev/null); rc=$?
t_eq "an unconfigured box answers rc=0" "$rc" "0"
t_eq "...ok:true" "$(jq -r '.ok' <<<"$out")" "true"
t_eq "...backend local" "$(jq -r '.values.backend' <<<"$out")" "local"
t_eq "...the engine's default hearing model" "$(jq -r '.values.stt_model' <<<"$out")" "openai/whisper-large-v3-turbo"
t_eq "...the engine's default voice" "$(jq -r '.values.tts_voice' <<<"$out")" "alloy"
t_eq "...every declared key and nothing else" "$(jq -r '.values | keys | join(",")' <<<"$out")" "backend,stt_backend,stt_fast,stt_language,stt_model,tts_model,tts_voice"
t_eq "...and no notices" "$(jq -r '.notices | length' <<<"$out")" "0"
# DIVE-5869: unset, hearing detects the language and uses five beams; the form
# must show exactly that, and its defaults must be the manifest's.
t_eq "...language auto, fast off" "$(jq -r '"\(.values.stt_language) \(.values.stt_fast)"' <<<"$out")" "auto 0"
t_eq "...which are the manifest's defaults" \
  "$(jq -r '[.fivedive.settings.fields[] | select(.key=="stt_language" or .key=="stt_fast") | .default] | join(" ")' "$M")" "auto 0"
t_eq "get reads one key" "$(run config get backend 2>/dev/null)" "local"
run config get nope >/dev/null 2>&1; t_eq "get refuses an undeclared key" "$?" "2"
t_has "the plain form lists key=value" "$(run config 2>/dev/null)" "tts_model=microsoft/mai-voice-2-flash"
run config frobnicate >/dev/null 2>&1; t_eq "an unknown subcommand is a usage error" "$?" "64"

# DIVE-4985. Through the CLI the verb never sees `--json`: `5dive` strips it
# from argv before dispatch and exports FIVEDIVE_JSON_MODE=1 instead (DIVE-4893).
# That is the exact path the dashboard's form takes, so it is graded here as the
# dispatcher would call it — no flag, only the mode.
echo "== the dispatcher's JSON mode, with --json already stripped (DIVE-4985) =="
out=$(FIVEDIVE_JSON_MODE=1 run config 2>/dev/null); rc=$?
t_eq "FIVEDIVE_JSON_MODE=1 with no flag → rc=0" "$rc" "0"
t_eq "...answers the JSON object the form parses" "$(jq -r '.ok' <<<"$out" 2>/dev/null)" "true"
t_eq "...with every declared key" "$(jq -r '.values | keys | join(",")' <<<"$out" 2>/dev/null)" "backend,stt_backend,stt_fast,stt_language,stt_model,tts_model,tts_voice"
out=$(FIVEDIVE_JSON_MODE=1 VOICE_LIB="$T/absent.sh" "$VOICE" config 2>/dev/null)
t_eq "...and without the engine it still says why, in JSON" "$(jq -r '.reason' <<<"$out" 2>/dev/null)" "engine_missing"
t_has "FIVEDIVE_JSON_MODE=0 (the dispatcher's default) keeps the plain form" "$(FIVEDIVE_JSON_MODE=0 run config 2>/dev/null)" "backend=local"
t_eq "get is not changed by the mode" "$(FIVEDIVE_JSON_MODE=1 run config get backend 2>/dev/null)" "local"

echo "== writing is a root act; refusals write nothing =="
if [[ $EUID -ne 0 ]]; then
  out=$(run config set tts_voice nova 2>&1); rc=$?
  t_eq "a non-root seat is refused" "$rc" "1"
  t_has "...and told the sudo line" "$out" "sudo 5dive voice config set tts_voice nova"
  t_eq "...and nothing was written" "$([[ -f "$CFG" ]] && echo wrote || echo clean)" "clean"
  echo "  skip write-path arms (not root) — run as root to grade them"
else
  t_ok "(running as root — the non-root refusal arm is not applicable)"

  printf '# a comment the installer wrote\nbackend=local\n' > "$CFG"
  for bad in 'a b' '-x' 'nova;id' '$(id)' "$(printf 'a\nbackend=openrouter')" "$(printf 'x%.0s' {1..200})"; do
    run config set tts_voice "$bad" >/dev/null 2>&1; rc=$?
    t_eq "refuses tts_voice=[${bad:0:20}] (rc 2)" "$rc" "2"
  done
  t_eq "...and not one of them reached the file" "$(cat "$CFG")" "$(printf '# a comment the installer wrote\nbackend=local')"
  run config set backend bogus >/dev/null 2>&1; t_eq "an enum refuses a value it does not declare" "$?" "2"
  run config set api_key sk-or-x >/dev/null 2>&1; t_eq "an undeclared key cannot be set" "$?" "2"
  run config set tts_voice >/dev/null 2>&1; t_eq "a missing value is a usage error" "$?" "64"
  t_no "...and none of those wrote" "$(cat "$CFG")" "api_key"

  out=$(run config set tts_voice nova 2>&1); rc=$?
  t_eq "a valid string lands" "$rc" "0"
  t_eq "...and reads back through --json" "$(run config --json | jq -r '.values.tts_voice')" "nova"
  run config set tts_voice shimmer >/dev/null 2>&1
  t_eq "a second set REPLACES the line, it does not append" "$(grep -c '^tts_voice=' "$CFG")" "1"
  t_has "...the comment survives" "$(cat "$CFG")" "# a comment the installer wrote"
  t_has "...and so does backend" "$(cat "$CFG")" "backend=local"
  t_eq "no temp file is left beside the config (the write is a rename)" \
    "$(find "$VOICE_STATE_DIR" -name '.config.*' | wc -l | tr -d ' ')" "0"
  run config set stt_model meta/muse-voice-transcribe-1.0 >/dev/null 2>&1
  t_eq "a model id with a slash is a valid string" "$(run config get stt_model)" "meta/muse-voice-transcribe-1.0"

  echo "== backend goes through the backend verb's own refusal =="
  rm -f "$VOICE_CONNECTORS_DIR/openrouter.env"
  out=$(run config set backend openrouter 2>&1); rc=$?
  t_eq "openrouter without a key is refused" "$rc" "1"
  t_has "...naming the existing way to add one" "$out" "5dive-write-connector openrouter.env"
  t_eq "...and the box stays local" "$(run config get backend)" "local"
  printf 'OPENROUTER_API_KEY=sk-or-%s\n' "$(printf 'a%.0s' {1..30})" > "$VOICE_CONNECTORS_DIR/openrouter.env"
  out=$(run config set backend openrouter 2>&1); rc=$?
  t_eq "with a key it lands" "$rc" "0"
  t_has "...and says what now leaves the box" "$out" "AUDIO and REPLY TEXT"
  out=$(run config --json)
  t_eq "--json reads openrouter" "$(jq -r '.values.backend' <<<"$out")" "openrouter"
  t_eq "...with no notice while the key is there" "$(jq -r '.notices | length' <<<"$out")" "0"
  t_eq "exactly one backend= line" "$(grep -c '^backend=' "$CFG")" "1"

  echo "== a key that goes away after the switch is SAID, not hidden =="
  rm -f "$VOICE_CONNECTORS_DIR/openrouter.env"
  out=$(run config --json 2>/dev/null)
  t_eq "the configured value is still openrouter (the form shows what was chosen)" "$(jq -r '.values.backend' <<<"$out")" "openrouter"
  t_eq "...and one notice, on backend" "$(jq -r '[.notices[].key] | join(",")' <<<"$out")" "backend"
  t_eq "...naming the connector that fixes it" "$(jq -r '.notices[0].connector' <<<"$out")" "openrouter.env"
  t_no "...and the notice never carries a key" "$out" "sk-or-"

  echo "== stt_backend moves hearing alone (DIVE-5189) =="
  printf 'OPENROUTER_API_KEY=sk-or-%s\n' "$(printf 'a%.0s' {1..30})" > "$VOICE_CONNECTORS_DIR/openrouter.env"
  t_eq "unset, hearing follows backend" "$(run config get stt_backend)" "openrouter"
  out=$(run config set stt_backend local 2>&1); rc=$?
  t_eq "stt_backend=local lands" "$rc" "0"
  t_eq "...hearing reads local" "$(run config get stt_backend)" "local"
  t_eq "...speaking stays openrouter" "$(run config get backend)" "openrouter"
  t_eq "...and the engine agrees on both halves" \
    "$(. "$LIB"; voice_effective_stt_backend 2>/dev/null) $(. "$LIB"; voice_effective_backend 2>/dev/null)" "local openrouter"
  run config set stt_backend elsewhere >/dev/null 2>&1
  t_eq "a value outside the enum is refused" "$?" "2"
  run config set backend local >/dev/null 2>&1
  rm -f "$VOICE_CONNECTORS_DIR/openrouter.env"
  out=$(run config set stt_backend openrouter 2>&1); rc=$?
  t_eq "moving hearing to openrouter without a key is refused" "$rc" "1"
  t_has "...naming the fix" "$out" "5dive-write-connector openrouter.env"
  t_eq "...and hearing stays local" "$(run config get stt_backend)" "local"

  echo "== hearing's language and fast mode (DIVE-5869) =="
  # A fake whisper-service whose /health predates beam_size, so the verb's
  # "not on yet" note is graded without touching a real service on :8765.
  python3 - "$T/oldws.port" <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        out = json.dumps({"ok": True, "model": "small"}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
srv = HTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_address[1])); srv.serve_forever()
PY
  OLDWS_PID=$!
  for _ in $(seq 1 50); do [[ -s "$T/oldws.port" ]] && break; sleep 0.1; done
  export VOICE_SERVICE_PORT=9   # nothing listens: no note, no failure
  out=$(run config set stt_language ru 2>&1); rc=$?
  t_eq "stt_language=ru lands" "$rc:$out" "0:stt_language: ru"
  t_eq "...reads back" "$(run config get stt_language)" "ru"
  t_eq "...and the engine sends it" "$(. "$LIB"; voice_stt_language)" "ru"
  for bad in Russian RU r ru-RU 'ru;id' russ; do
    out=$(run config set stt_language "$bad" 2>&1); rc=$?
    t_eq "refuses stt_language=[$bad] (rc 2)" "$rc" "2"
  done
  t_has "...naming what a language code looks like" "$out" "a code such as ru, en or uk"
  t_eq "...and the file still says ru" "$(grep '^stt_language=' "$CFG")" "stt_language=ru"
  run config set stt_language auto >/dev/null 2>&1
  t_eq "auto turns detection back on" "$(run config get stt_language) [$(. "$LIB"; voice_stt_language)]" "auto []"
  run config set stt_fast 2 >/dev/null 2>&1; t_eq "stt_fast refuses 2" "$?" "2"
  run config set stt_fast yes >/dev/null 2>&1; t_eq "...and yes" "$?" "2"
  out=$(run config set stt_fast 1 2>&1); rc=$?
  t_eq "stt_fast=1 lands, quietly when no service answers" "$rc:$out" "0:stt_fast: 1"
  t_eq "...reads back" "$(run config --json | jq -r '.values.stt_fast')" "1"
  t_eq "...and the engine reads it" "$(. "$LIB"; voice_stt_fast)" "1"
  out=$(VOICE_SERVICE_PORT="$(cat "$T/oldws.port")" run config set stt_fast 1 2>&1); rc=$?
  t_eq "a running service that predates fast mode: still rc 0" "$rc" "0"
  t_has "...and the owner is told it is not on until setup runs" "$out" "sudo 5dive voice setup"
  out=$(VOICE_SERVICE_PORT="$(cat "$T/oldws.port")" run config set stt_fast 0 2>&1)
  t_no "...turning it off needs no such note" "$out" "voice setup"
  t_eq "one line per key, however often it is set" "$(grep -c '^stt_fast=' "$CFG"):$(grep -c '^stt_language=' "$CFG")" "1:1"
  kill "$OLDWS_PID" 2>/dev/null
  unset VOICE_SERVICE_PORT

  echo "== config init writes a box's FIRST config and never a second =="
  rm -f "$CFG"
  out=$(VOICE_LIB="$T/absent.sh" "$VOICE" config init backend=openrouter stt_backend=local tts_model=google/gemini-3.8-flash-tts tts_voice=Kore 2>&1); rc=$?
  t_eq "init runs with NO engine installed yet (it precedes setup)" "$rc" "0"
  t_eq "...and says it wrote" "$out" "config: written"
  t_has "...backend" "$(cat "$CFG")" "backend=openrouter"
  t_has "...stt_backend" "$(cat "$CFG")" "stt_backend=local"
  t_has "...tts_voice" "$(cat "$CFG")" "tts_voice=Kore"
  t_eq "...mode 644 (every seat reads it)" "$(stat -c %a "$CFG")" "644"
  printf 'backend=local\n# the customer chose this\n' > "$CFG"
  out=$(run config init backend=openrouter stt_backend=local 2>&1); rc=$?
  t_eq "a second init exits 0" "$rc" "0"
  t_eq "...says kept" "$out" "config: kept"
  t_eq "...and the customer's file is byte-for-byte untouched" "$(cat "$CFG")" "$(printf 'backend=local\n# the customer chose this')"
  out=$(FIVEDIVE_JSON_MODE=1 run config init backend=openrouter 2>&1)
  t_eq "--json answers kept" "$(jq -r '.config' <<<"$out" 2>/dev/null)" "kept"
  rm -f "$CFG"
  run config init backend=openrouter tts_voice='bad value' >/dev/null 2>&1; rc=$?
  t_eq "one invalid pair refuses the whole init" "$rc" "2"
  t_eq "...and nothing was written" "$([[ -e "$CFG" ]] && echo present || echo absent)" "absent"
  run config init api_key=sk-or-x >/dev/null 2>&1
  t_eq "an undeclared key is refused" "$?" "2"
  run config init backend >/dev/null 2>&1
  t_eq "a pair with no = is a usage error" "$?" "64"
  t_eq "no temp file is left behind" "$(find "$VOICE_STATE_DIR" -name '.config.*' | wc -l | tr -d ' ')" "0"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

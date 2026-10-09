# 5dive voice

Speak to your agent and hear it talk back.

**By default, hearing runs on your own box and the audio never leaves it.**
Speaking is the half that was never local, and this README used to say
otherwise: the local voice is `edge-tts`, an unofficial client for Microsoft's
online neural voices, so the reply *text* has always gone to Microsoft. That is
corrected below rather than quietly fixed, because a self-hoster chose this
plugin on the strength of the old sentence.

There is now a choice. `5dive voice backend openrouter` moves both halves to
OpenRouter — more accurate, and the audio and reply text leave the box. `local`
stays the default and nothing about an existing box changes until you say so.

## Install

```
5dive plugin add 5dive-ai/5dive-voice     # one command, straight from this repo
sudo 5dive voice setup                    # the host-level engine — you run this, not us
5dive plugin list                         # voice 1.3.0  official  channel,verb
5dive voice                               # the verb the plugin registers
5dive voice backend                       # where hearing and speaking run: local
```

That first line is the whole point of this repo. A plugin lives in its own
repository, carries its own `.claude-plugin/marketplace.json`, and installs with
`5dive plugin add <owner>/<repo>` — no marketplace to add by hand, no central
registry to be published into first. This is the shape a third-party plugin
author copies; voice is simply the first one to do it, in public, on our own
plugin.

## Repo layout

```
.claude-plugin/marketplace.json   the one-entry index; its plugin source is ./voice
voice/
  .claude-plugin/plugin.json      the plugin manifest
  bin/voice                       the executable the `voice` verb resolves to
```

**The plugin lives in `voice/`, not at the repo root, and that is not a
preference.** Contract §1 requires the manifest `name` to equal its *folder*
name. A `"source": "./"` resolves the plugin to the marketplace root, whose
folder name is the marketplace name — derived from the **repo** name — so a
root-level plugin only installs when the plugin and the repo are named the same
thing. Ours are deliberately not (`voice` the plugin, `5dive-voice` the repo),
so the plugin gets its own directory and the index points at it. A publisher
whose plugin and repo share a name can leave it at the root; naming the folder
is the option that always works, and it is what a second plugin should copy.

**Install by the qualified name, not the bare one.** `5dive plugin add voice`
still resolves for boxes that only know the old central registry, but on a box
that has both registered, a bare plugin name is ambiguous across marketplaces
and the CLI cannot tell which copy you meant. `5dive-ai/5dive-voice` is never
ambiguous.

## The installer ships with the plugin

The engine is installed by `voice/bin/5dive-setup-voice`, which is part of this
repository and lands on your box as part of `plugin add`. Nothing has to be
present beforehand, and `sudo 5dive voice setup` is the verb route to it — the
same shape `browser` uses for `sudo 5dive browser setup`.

Before DIVE-4495 the manifest named a bare `5dive-setup-voice`, a program written
only by 5dive's own box installer. On a 5dive-provisioned box that worked; on any
other box the plugin installed cleanly and its host half could not be installed at
all, which is not a state a published plugin should be able to reach.

A setup that fails halfway is retried, not stuck (1.7.1, DIVE-5614). On Ubuntu,
`python3 -m venv` needs the `python3-venv` package, and without it leaves a venv
directory with no pip in it. The installer now installs that package itself and
repairs a venv with no pip on the next run, where it used to skip any venv whose
directory already existed.

A long voice note is heard, not dropped (1.7.2, DIVE-5750). `5dive-transcribe`
used to wait a fixed 120 seconds for the local whisper, which on a CPU box cut
off every note over about 5 minutes while whisper was still working on it. The
wait is now 120 seconds plus the note's own length, a dead service still fails
at once, and a note that does run out of time is reported as too long, not as
one that could not be heard.

Hearing's language and speed are settings (1.8.0, DIVE-5869): `stt_language`
pins the language and `stt_fast` turns on greedy decoding, see "Hearing speed and
language on this box" below. A running `whisper-service` is now restarted onto
new code when setup or the nightly changes it; before, it kept the code it was
first installed with.

Which whisper model hears follows the box (1.9.0, DIVE-5897): `base` on a box
with 2 CPUs or under 6 GB of memory, `small` on a bigger one. It used to be
`small` everywhere, which took 9-12 s on a 2-vCPU / 4 GB box where `base` takes
3-4 s. An owner switches it with `sudo 5dive voice config set whisper_model`,
see "Hearing speed and language on this box" below.

## What the voice runtime actually is

Not a stub. `sudo 5dive voice setup` installs, on your own box:

- **ffmpeg** (apt) for audio conversion;
- **faster-whisper** and **edge-tts** into `/home/claude/.venv`;
- **`whisper-service`**, a warm transcription HTTP service on **port 8765**, as a
  systemd unit — warm because loading the model per utterance is the difference
  between a conversation and a wait;
- **`5dive-transcribe`**, a single wrapper binary so an agent can pre-allow
  `Bash(5dive-transcribe:*)` instead of being prompted for `cp` and `curl` on
  every voice message;
- a Voice section appended to `projects/CLAUDE.md`, so the agent knows it can
  hear and speak.

Incoming speech never leaves the box: whisper runs locally. It is also the same
thing the dashboard offers as the **Voice** connector — this plugin is the CLI
path to it, for the self-hosters who have no dashboard.

**That engine is not in this repo and does not move with it.** It is installed as
root, per box, by the 5dive install path. Moving a plugin to its own repo moves
the *plugin* half only — the box-level half stays where the box installer can
reach it. Take the box half with you and every freshly provisioned box loses the
capability.

## Where hearing and speaking run

```
5dive voice backend                      # what is in force right now
sudo 5dive voice backend local           # the default
sudo 5dive voice backend openrouter      # needs a key; see below
```

| | `local` (default) | `openrouter` |
|---|---|---|
| hearing | faster-whisper on this box, warm on :8765. **Audio never leaves.** | OpenRouter `/audio/transcriptions`. **Audio leaves the box.** |
| speaking | `edge-tts`. **Reply text goes to Microsoft.** | OpenRouter `/audio/speech`. **Reply text goes to OpenRouter.** |
| accuracy | whisper `small`, the weakest tier anyone benchmarks | `whisper-large-v3-turbo` by default; ~12% WER, 99+ languages |
| cost | free | ~$0.00006 to hear a 20-second note, ~$0.0045 to speak a 300-character reply |
| failure mode | breaks whenever Microsoft rotates its token scheme | a normal paid API |

**The trade is privacy, not money.** At our shape the bill is rounding error;
what you are deciding is whether your voice notes go to a vendor.

**Reading the setting is unprivileged; changing it needs root.** That asymmetry
is the design, not an oversight: which backend is in force is something every
seat's transcribe wrapper reads on every utterance, while *changing* it decides
whether this box's audio leaves it — the same class of act as `sudo
5dive voice setup` itself. A non-root seat gets the `sudo` line, never a
half-applied change.

### The key

`openrouter` needs an OpenRouter key, and it reuses the store the box already
has for provider credentials — no new secret location:

```
sudo 5dive-write-connector openrouter.env <<< "OPENROUTER_API_KEY=sk-or-..."
```

If the key is missing, `5dive voice backend openrouter` **refuses**, with that
line, rather than switching into a state that fails later. And if a key that was
present is revoked or removed afterwards, the box **falls back to local with a
warning and still transcribes** — the alternative is dropping a message someone
already sent. The fallback is deliberately one-way: a box configured `local`
never reaches the network, even with a key sitting on disk.

### Hearing speed and language on this box

Only read when hearing runs locally. Left unset, whisper detects the language of
every note and weighs five candidate readings, as it always has. An owner whose
notes are always in one language can pin it, and can trade a little accuracy for
speed (1.8.0, DIVE-5869):

```
sudo 5dive voice config set stt_language ru    # a language code; auto detects again
sudo 5dive voice config set stt_fast 1         # one reading instead of five; 0 turns it off
```

A 20-second Russian note took about 5.2 s on the defaults and about 3.4 s with
both set. `stt_fast` needs a `whisper-service` that reads `beam_size`: setup and
the nightly restart a running service onto new code when it changes, and
`config set stt_fast 1` says so when the running one is older. Do not edit the
plugin's files to get the same effect: the next update replaces them.

Which model hears (1.9.0, DIVE-5897):

```
sudo 5dive voice config set whisper_model small   # more accurate, about 2-3x slower
sudo 5dive voice config set whisper_model base    # the fast one
sudo 5dive voice config set whisper_model auto    # back to the box's default
```

`auto` (or unset) is `base` on a box with 2 CPUs or under 6 GB of memory and
`small` on a bigger one, read from the box itself (`nproc`, `MemTotal`), so it
needs no plan name. Setup, the nightly and a resize re-apply it; a model an owner
chose, one set with `WHISPER_MODEL=` for a run of the installer, or one set by
hand in the unit before 1.9.0 is kept. Setting it rewrites the
`whisper-service` unit, restarts the service and waits until `/health` answers
with the new model. `small` is refused on a box with under ~3 GB of memory: it
peaks at about 0.8 GB while it hears. The agent's Voice section tells it to
offer `small` when a note was misheard (warning that it is slower) and `base`
when hearing is slow, and to switch only on the owner's yes.

### Models

Only read when the backend is `openrouter`. Set them with the verb rather than
by editing the file — it validates the value and writes atomically:

```
5dive voice config                                   # every setting, as key=value
sudo 5dive voice config set stt_model meta/muse-voice-transcribe-1.0
sudo 5dive voice config set tts_voice nova
```

- `stt_model` — default `openai/whisper-large-v3-turbo`. 99+ languages,
  **Russian among them**. `meta/muse-voice-transcribe-1.0` is the most accurate
  option in English (3.1% streaming WER), but **Russian and Ukrainian are not
  among its 25 validated languages** and code-switched speech scores badly on
  it. Pick it only if your audio is English.
- `tts_model` — default `microsoft/mai-voice-2-flash`, the official successor of
  the service `edge-tts` scrapes.
- `tts_voice` — default `alloy`, a voice name the speaking model offers.

### Each agent speaks in its own character's voice

An agent imported from an OpenAgent pack keeps its `persona.yaml` in its own
`~/.claude/`, and a pack can carry `voice.audio.base` (a voice name) and
`voice.audio.style` (how to say things). On `openrouter`, `5dive-speak` run by
that agent speaks in that voice, with the style as the delivery instruction, on
`google/gemini-3.8-flash-lite-tts` — the pack voice names (Charon, Kore, Puck,
Sulafat, Achird, …) are Gemini TTS's prebuilt voices, which no other model has.
It speaks the language of the text it is given. To use a different Gemini TTS
model for character voices, put `persona_tts_model=<model>` in the config file.

An agent with no voice in its pack and an explicit `--voice=` behave exactly as
before. If a character voice call fails, the reply is spoken in the box default
instead, with a line on stderr.

### On `local`, each agent has its own Microsoft voice too

The free backend speaks through Microsoft's edge voices, and each agent gets
its own (DIVE-5443). Before, every agent on a box spoke `en-US-AriaNeural`.

- **A pack voice keeps its character.** Each of the 30 Gemini voice names maps
  to one fixed edge voice of the same gender (Google's genders), closest in tone
  and spread across English accents. No two Gemini voices share an edge voice.
  The table is `VOICE_EDGE_TABLE` in `voice/lib/voice-backend.sh`.
- **An agent with no pack voice** gets a stable pick from its unix name. It
  skips voices another agent on the box already holds, so two agents share a
  voice only when the box has more agents than the pool has voices. A new agent
  never moves an older agent's voice.
- **A Russian or Ukrainian reply** is spoken by that language's voice of the
  agent's gender (`ru-RU-DmitryNeural`/`SvetlanaNeural`,
  `uk-UA-OstapNeural`/`PolinaNeural`). The language comes from the reply text.
- **Precedence:** `--voice=`, then an `edge_voice=` line you write in the config
  file, then the agent's own voice, then Aria. The `# edge_voice=` line that
  setup writes is a comment and counts as unset. Uncomment it to give every
  agent one voice.

The key is the connector above. A box built by a partner that seeds each box its
own OpenRouter key has no connector: its key sits in the `openrouter` account the
agents answer on, and voice reads it from there, last, and only when that account
points at OpenRouter.

The config file is host state and deliberately does **not** live in the plugin's
installed directory: contract §4 keys that path on the manifest version, so an
upgrade would silently reset every box to `local`.

### Turning voice replies off

`sudo 5dive plugin disable voice` switches voice REPLIES off on the box
(1.7.0): while every installed copy of the plugin is disabled, `5dive-speak`
exits 3 without a voice note and tells the agent to answer in text, so a voice
note gets a typed answer. Hearing is not gated, because the agent still has to
understand the note it answers. `5dive plugin enable voice` turns replies back
on. A box with no plugin record at all (an engine installed before the plugin
existed) keeps speaking. The same gate is in 5dive-api's copy of the engine,
which the nightly reinstalls.

### What is not here

No streaming or realtime (OpenRouter's audio API is synchronous only), and no
diarization.

## Settings in the dashboard

The manifest declares its settings under `fivedive.settings` — each one's key,
label, type (`enum` with its options, or `string`), default and help text — and
names the verb that reads and writes them. The 5dive dashboard draws its form
from that declaration and reaches the box only through the verb:

```
5dive voice config --json                 # {"ok":true,"values":{...},"notices":[...]}
sudo 5dive voice config set <key> <value> # one value; refused unless the declaration allows it
```

So the manifest is the one list of what is settable. The verb validates against
it, and the form offers exactly what it declares. **The OpenRouter key is not a
setting and never will be:** it is a secret, it stays in the connector store, and
when the backend is `openrouter` without one, `config --json` returns a notice
naming `openrouter.env` so the dashboard can send you to its own way of adding a
key rather than asking for it in the form.

## Why `plugin add` does not run the setup for you

`fivedive.setup` in the manifest carries a `hint` and a `command`, and `plugin
add` **prints** them. It does not execute them, and it must never learn to.

Executing a string out of a manifest at install time is arbitrary code execution
chosen by the publisher — the exact door contract §5 keeps shut. It would in
fact be *worse* than that door, because it would run before you had seen what you
installed. So the plugin tells you the command and you run it. `voice` is
5dive's own plugin and gets no exception; an exception for the first plugin is
how the rule ends up meaning nothing for the tenth.

## What it declares, and why each line is load-bearing

```json
"fivedive": {
  "contract": "1",
  "capabilities": ["channel", "verb"],
  "verbs": [{"name": "voice", "summary": "talk to your agent by voice; pick where hearing and speaking run", "installs": "channel"}],
  "grants": ["audio-io", "telegram-token"],
  "trust": {"publisher": "5dive", "did": "did:key:5dive", "review": "official"}
}
```

- **`capabilities`** is the whole point. Contract §2: *an undeclared surface is
  inert.* The installer registers what this array names and nothing else. If
  voice later ships an MCP server without adding `"mcp"` here, that server is not
  registered — and `plugin add` says so out loud rather than dropping it silently.
- **`voice/bin/voice`** is where the verb resolves, and 5dive picked that path,
  not the manifest. The manifest names `voice`; it never says what to run. `5dive voice`
  runs the plugin's `bin/voice` with your argv as a vector, and only after every builtin 5dive
  command has had its chance — so a plugin cannot take `5dive task` from you.
- **`grants`** is the consent list, not documentation. `plugin add` prints it
  back in plain English ("your microphone and speakers") and will not install
  until you agree.
- **`trust.review: "official"`** is what makes voice installable today.
- **`version`** is not cosmetic. The install path is keyed on it
  (`…/5dive/plugins/cache/<marketplace>/voice/1.0.0/`), so **a change that does not bump
  `version` cannot arrive.** Bump it in the same commit as the change, every time.

## Moving here from the central registry

Voice was published from `5dive-ai/5dive-plugins` until this repo existed. That
entry stays in place — installed boxes run `plugin add voice` today and must keep
resolving — and is removed only after every reader names this repo instead.
The order, the traps, and what a second plugin has to copy:
`community/wiki/moving-a-plugin-to-its-own-repo-the-voice-migration-guide.md`.

## The full contract

`community/wiki/the-5dive-plugin-contract-v1.md`.

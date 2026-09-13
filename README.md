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
sudo 5dive-setup-voice                    # the host-level engine — you run this, not us
5dive plugin list                         # voice 1.1.0  official  channel,verb
5dive voice                               # the verb the plugin registers
5dive voice backend                       # where hearing and speaking run: local
```

That first line is the whole point of this repo. A plugin lives in its own
repository, carries its own `.claude-plugin/marketplace.json`, and installs with
`5dive plugin add <owner>/<repo>` — no marketplace to add by hand, no central
registry to be published into first. This is the shape a third-party plugin
author copies; voice is simply the first one to do it, in public, on our own
plugin.

**Install by the qualified name, not the bare one.** `5dive plugin add voice`
still resolves for boxes that only know the old central registry, but on a box
that has both registered, a bare plugin name is ambiguous across marketplaces
and the CLI cannot tell which copy you meant. `5dive-ai/5dive-voice` is never
ambiguous.

## What the voice runtime actually is

Not a stub. `5dive-setup-voice` installs, on your own box:

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
5dive-setup-voice` itself. A non-root seat gets the `sudo` line, never a
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

### Models

Set in `/var/lib/5dive/voice/config`; only read when the backend is `openrouter`.

- `stt_model` — default `openai/whisper-large-v3-turbo`. 99+ languages,
  **Russian among them**. `meta/muse-voice-transcribe-1.0` is the most accurate
  option in English (3.1% streaming WER), but **Russian and Ukrainian are not
  among its 25 validated languages** and code-switched speech scores badly on
  it. Pick it only if your audio is English.
- `tts_model` — default `microsoft/mai-voice-2-flash`, the official successor of
  the service `edge-tts` scrapes.

The config file is host state and deliberately does **not** live in the plugin's
installed directory: contract §4 keys that path on the manifest version, so an
upgrade would silently reset every box to `local`.

### What is not here

No streaming or realtime (OpenRouter's audio API is synchronous only), no
diarization, and no dashboard toggle yet — the settings frame it belongs in is
still being built. The CLI is the whole surface for now.

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
- **`bin/voice`** is where the verb resolves, and 5dive picked that path, not the
  manifest. The manifest names `voice`; it never says what to run. `5dive voice`
  runs `bin/voice` with your argv as a vector, and only after every builtin 5dive
  command has had its chance — so a plugin cannot take `5dive task` from you.
- **`grants`** is the consent list, not documentation. `plugin add` prints it
  back in plain English ("your microphone and speakers") and will not install
  until you agree.
- **`trust.review: "official"`** is what makes voice installable today.
- **`version`** is not cosmetic. The install path is keyed on it
  (`…/cache/5dive/<marketplace>/voice/1.0.0/`), so **a change that does not bump
  `version` cannot arrive.** Bump it in the same commit as the change, every time.

## Moving here from the central registry

Voice was published from `5dive-ai/5dive-plugins` until this repo existed. That
entry stays in place — installed boxes run `plugin add voice` today and must keep
resolving — and is removed only after every reader names this repo instead.
The order, the traps, and what a second plugin has to copy:
`community/wiki/moving-a-plugin-to-its-own-repo-the-voice-migration-guide.md`.

## The full contract

`community/wiki/the-5dive-plugin-contract-v1.md`.

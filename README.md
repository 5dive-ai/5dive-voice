# 5dive voice

Speak to your agent and hear it talk back. Speech-to-text and text-to-speech that
run **on your own box** — audio never leaves it.

## Install

```
5dive plugin add 5dive-ai/5dive-voice     # one command, straight from this repo
sudo 5dive-setup-voice                    # the host-level engine — you run this, not us
5dive plugin list                         # voice 1.0.0  official  channel,verb
5dive voice                               # the verb the plugin registers
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

Speech never leaves the box: whisper runs locally. It is also the same thing the
dashboard offers as the **Voice** connector — this plugin is the CLI path to it,
for the self-hosters who have no dashboard.

**That engine is not in this repo and does not move with it.** It is installed as
root, per box, by the 5dive install path. Moving a plugin to its own repo moves
the *plugin* half only — the box-level half stays where the box installer can
reach it. Take the box half with you and every freshly provisioned box loses the
capability.

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
  "verbs": [{"name": "voice", "summary": "talk to your agent by voice", "installs": "channel"}],
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

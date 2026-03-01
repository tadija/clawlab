# clawlab

**local multi-agent setup**

> **powered by**: [openclaw](https://github.com/openclaw/openclaw) | [picoclaw](https://github.com/sipeed/picoclaw) | [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw)

# intro

- manage multiple agents as plain directories
- command multiple agents in a unified way
- native commands get forwarded (ie. help, onboard, status, etc.)

## structure

- [`agents/`](agents/) - working dir per-agent (instances)
- [`shared/`](shared) - shared space for all agents
- [`cfg`](cfg) - general config file
- [`cmd`](cmd) - script for commanding specific agents

## usage

```bash
Usage:
  cmd list
  cmd make <agent-name>
  cmd <agent-id> <command...>

Global commands:
  list    -> list existing agents
  make    -> create agent working dir

Agent commands:
  edit    -> open agent working dir in $EDITOR
  remove  -> remove agent working dir (-y to confirm)
  prompt  -> run <tool> agent -m "<message>" (arg, tty prompt, or stdin)
  start   -> start gateway / daemon (depending on agent)
  stop    -> stop gateway / daemon (depending on agent)

Examples:
  ./cmd list

  ./cmd make 001-openclaw
  ./cmd 001 onboard
  ./cmd 001 prompt
  ./cmd 001 edit
  ./cmd 001 start

  ./cmd make 004-picoclaw
  ./cmd 004 onboard
  ./cmd 004 auth login --provider anthropic
  ./cmd 004 prompt "hello"
  ./cmd 004 stop 

  ./cmd 007 make 007-zeroclaw
  ./cmd 007 onboard 
  ./cmd 007 auth login --provider openai-codex
  ./cmd 007 onboard --channels-only
  ./cmd 007 status
```

## notes

- requires on `$PATH`: `swift`, `openclaw`, `picoclaw`, `zeroclaw`
- toggle version control manually in [`.gitignore`](.gitignore)
- ports are defined in [`cfg`](cfg)

---

`done for fun`


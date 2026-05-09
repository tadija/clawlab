# clawlab

**local multi-agent setup**

> **works on**: macOS | Linux | WSL  
> **docs**: home | [config](config/README.md) | [infra](infra/README.md)  
>  
> **powered by**: [openclaw](https://github.com/openclaw/openclaw) | [picoclaw](https://github.com/sipeed/picoclaw) | [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) | [nanobot](https://github.com/HKUDS/nanobot) | [nullclaw](https://github.com/nullclaw/nullclaw) | [hermes](https://github.com/nousresearch/hermes-agent) | [moltis](https://github.com/moltis-org/moltis) | [mercury](https://github.com/cosmicstack-labs/mercury-agent)  

## intro

- manage multiple agents as plain directories in a single repo
- bootstrap and command multiple unrelated agents in a unified way
- forward native agent commands directly (`help`, `onboard`, `status`, `--tui`, etc.)
- customize the templates freely; bundled agents and services are examples

## recommended host setup
- run managed agents and shared services under a dedicated `agent` user
- clone into the shared host path and make it writable by your user
- create `config/custom/host/.env` file and run `./cmd infra bootstrap`

## structure

- [`agents/`](agents/) holds agent instances: one working directory per agent
- [`config/`](config/) shared definitions: agent kinds, host aliases, shared-service manifests, ports
- [`infra/`](infra/) machine bootstrap and service supervision for Linux/macOS
- [`shared/`](shared/) shared space across agents (e.g. content, knowledge, skills, etc.)
- [`cmd`](cmd) unified CLI for agents and infra commands

example `agents/` tree with two instances per supported kind:

```text
agents/
├── 001-openclaw/
├── 002-openclaw/
├── 003-picoclaw/
├── 004-picoclaw/
├── 005-zeroclaw/
├── 006-zeroclaw/
├── 007-nanobot/
├── 008-nanobot/
├── 009-nullclaw/
├── 010-nullclaw/
├── 011-hermes/
├── 012-hermes/
├── 013-moltis/
├── 014-moltis/
├── 015-mercury/
└── 016-mercury/
```

## cmd tree

```text
cmd
├── list                                      # list all existing agent directories
├── make <agent-id-agent-kind> ...            # create an agent and run native setup
├── remove <agent-id> [-y|--yes]              # remove agent dir + uninstall service
├── <agent-id>
│   ├── bootstrap                             # install runtime/dependencies for the agent
│   ├── edit                                  # open agent dir in configured $EDITOR
│   ├── start ...                             # run agent gateway/daemon in foreground
│   └── <native agent command> ...            # forward to the native agent CLI
└── infra
    ├── bootstrap                             # install host defined agents and services
    ├── install [<target>...]                 # install service-manager artifacts
    ├── uninstall [<target>...]               # remove service-manager artifacts
    ├── start [<target>...]                   # start managed agents/services
    ├── stop [<target>...]                    # stop managed agents/services
    ├── restart [<target>...]                 # restart managed agents/services
    ├── status [<target>...]                  # status managed agents/services
    ├── doctor [<target>...]                  # show diagnostics and short logs
    ├── log [<target>...]                     # tail logs from state directory
    └── render [<all|brew|caddy>]             # render generated infra files
```

> **target** can be explicit as `agents` or `services` (affects all), or an agent id, or a service id; for example: `agents services` or `003 005 007` or `tailscale caddy vibetunnel` (or any combination of those).

## common flows

inspect the local agent list:

```bash
./cmd list
```

create and use an agent interactively (stop a foreground agent run with `Ctrl-C`):

```bash
./cmd make 001-openclaw
./cmd 001 bootstrap
./cmd 001 onboard --skip-daemon
./cmd 001 start

./cmd make 004-picoclaw
./cmd 004 bootstrap
./cmd 004 auth login --provider anthropic
./cmd 004 start

./cmd make 007-zeroclaw
./cmd 007 bootstrap
./cmd 007 auth paste-redirect --provider openai-codex --profile default
./cmd 007 start

./cmd make 011-hermes
./cmd 011 bootstrap
./cmd 011 setup
./cmd 011 --tui
./cmd 011 start
```

open agent directory in `$EDITOR`:

```bash
./cmd 001 edit
```

remove agent directory and its service-manager artifact:

```bash
./cmd remove 011
```

setup custom host `.env` file, for example: [macOS](config/custom/host/.env.example-macos) | [Linux](config/custom/host/.env.example-linux) | [WSL](config/custom/host/.env.example-wsl)

```bash
CLAWLAB_AGENTS="001 002 003 004 005 006 007"
CLAWLAB_SERVICES="tailscale caddy vibetunnel"
```

then manage host-assigned infra targets (omit targets to use all):

```bash
./cmd infra bootstrap
./cmd infra install
./cmd infra start
./cmd infra status agents
./cmd infra log services
./cmd infra stop services
```

or operate on explicit agents and services directly:

```bash
./cmd infra install caddy vibetunnel 000 004 011
./cmd infra start services 003 005
./cmd infra restart caddy 001 002 006
./cmd infra status 000 004 caddy
./cmd infra doctor services 007
./cmd infra log 003 005 caddy
./cmd infra stop 008 vibetunnel
./cmd infra uninstall 011 caddy
```

manually generate infra templates:

```bash
./cmd infra render all
./cmd infra render brew
./cmd infra render caddy
```

## notes

- requires `swift` on `$PATH` since [`cmd`](cmd) is a [Swift](https://github.com/swiftlang/swift) script
- agent kinds are defined in [`config/agents/`](config/agents/)
- shared services are defined in [`config/services/`](config/services/)
- repo-wide parsed config is defined in [`config/custom/repo.ini`](config/custom/repo.ini)
- toggle version control manually in [`.gitignore`](.gitignore)

---

`done for fun`

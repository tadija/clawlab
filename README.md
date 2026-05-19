# clawlab

**homelab multi-agent setup**

> **works on**: macOS | Linux | WSL  
> **docs**: home | [config](config/README.md) | [infra](infra/README.md)  
>  
> **powered by**: [openclaw](https://github.com/openclaw/openclaw) | [picoclaw](https://github.com/sipeed/picoclaw) | [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) | [nullclaw](https://github.com/nullclaw/nullclaw)  
[nanobot](https://github.com/HKUDS/nanobot) | [pi](https://github.com/earendil-works/pi) | [hermes](https://github.com/nousresearch/hermes-agent) | [moltis](https://github.com/moltis-org/moltis) | [mercury](https://github.com/cosmicstack-labs/mercury-agent) | [goose](https://github.com/block/goose)  
[codex](https://github.com/openai/codex) | [claude](https://github.com/anthropics/claude-code) | [gemini](https://github.com/google-gemini/gemini-cli)  

## intro

- manage multiple agents across multiple hosts as plain directories in a single repo
- bootstrap and command multiple unrelated agents from a single place in a unified way
- forward native agent commands directly (`help`, `onboard`, `status`, `--tui`, etc.)
- render web page with current status of all agents and services (built-in http-server)
- access running host shells via web from desktop or mobile (built-in tty-server)
- customize the templates freely; bundled agents and services are examples

## recommended host setup
- run managed agents and shared services under a dedicated `agent` user
- clone this repo into a shared host path and make it writable by `agent` and other groups/users
- make a few agents: `./cmd make 001-codex # repeat for others, ie. 002-claude, 003-gemini, etc.`
- define yours `config/custom/host/.env` file and run `./cmd infra bootstrap && ./cmd infra start`
- when using tailscale prefer the official app or service managed out of clawlab, so `./cmd infra restart` does not restart that very tailscale service which makes you connected to a vps, for example

## structure

- [`agents/`](agents/) holds agent instances: one working directory per agent
- [`config/`](config/) shared definitions: agent kinds, host aliases, shared-service manifests, ports
- [`infra/`](infra/) machine bootstrap and service supervision for Linux/macOS
- [`shared/`](shared/) shared space across agents (e.g. content, knowledge, skills, etc.)
- [`cmd`](cmd) unified CLI for agents and infra commands

## cmd tree

```text
cmd
├── list                                      # list all existing agent directories
├── make <agent-id-agent-kind> ...            # create an agent and run native setup
├── remove <agent-id> [-y|--yes]              # remove agent dir + uninstall service
├── <agent-id>
│   ├── bootstrap                             # install runtime/dependencies for the agent
│   ├── edit                                  # open agent dir in configured $EDITOR
│   ├── setup ...                             # run native setup for the agent
│   ├── start ...                             # run agent gateway/daemon in foreground
│   ├── stop ...                              # stop native gateway/daemon when supported
│   ├── tui ...                               # run native terminal UI when supported
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
    ├── render [<all|brew|caddy|dash>]        # render generated infra files
    └── update [<target>...]                  # pull latest and restart targets
```

> **target** can be explicit as `agents` or `services` (affects all), or an agent id, or a service id; for example: `agents services` or `003 005 007` or `tailscale caddy` (or any combination of those).

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

./cmd make 021-mercury
./cmd 021 bootstrap
...
```

open any agent directory in `$EDITOR`:

```bash
./cmd 001 edit
```

remove any agent directory and its service-manager artifact:

```bash
./cmd remove 011
```

customize host `.env` file in `config/custom/host/` dir, for example: [macOS](config/custom/host/.env.example-macos) | [Linux](config/custom/host/.env.example-linux) | [WSL](config/custom/host/.env.example-wsl)

```bash
CLAWLAB_AGENTS="001 002 003 004 005 006 007"
CLAWLAB_SERVICES="caddy" # caddy internally runs dash-http and dash-tty
CLAWLAB_PROJECTS=".dotfiles=/Users/tadija/.dotfiles clawlab=/Users/Shared/clawlab"
```

then manage host-assigned infra targets (omit targets to use all):

```bash
./cmd infra bootstrap
./cmd infra start
./cmd infra status agents
./cmd infra log services
```

or operate on explicit agents and services directly:

```bash
./cmd infra install caddy 000 004 011
./cmd infra start services 003 005
./cmd infra restart caddy 001 002 006
./cmd infra status 000 004 caddy
./cmd infra doctor services 007
./cmd infra log 003 005 caddy
./cmd infra stop 008 dash-http dash-tty
./cmd infra uninstall 011 caddy
```

manually generate derived files from infra templates:

```bash
./cmd infra render <all|brew|caddy|dash>
```

## notes

- requires `swift` on `$PATH` since [`cmd`](cmd) is a [Swift](https://github.com/swiftlang/swift) script
- agent kinds are defined in [`config/agents/`](config/agents/)
- shared services are defined in [`config/services/`](config/services/)
- repo-wide parsed config is defined in [`config/custom/repo.ini`](config/custom/repo.ini)
- toggle version control manually in [`.gitignore`](.gitignore)

---

`done for fun`

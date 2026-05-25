# aelab

**run many AI agents as one system**

> **works on**: macOS | Linux | WSL  
> **docs**: home | [config](config/README.md) | [infra](infra/README.md)  
>  
> **powered by**: [openclaw](https://github.com/openclaw/openclaw) | [picoclaw](https://github.com/sipeed/picoclaw) | [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) | [nullclaw](https://github.com/nullclaw/nullclaw)  
> [nanobot](https://github.com/HKUDS/nanobot) | [pi](https://github.com/earendil-works/pi) | [hermes](https://github.com/nousresearch/hermes-agent) | [moltis](https://github.com/moltis-org/moltis) | [mercury](https://github.com/cosmicstack-labs/mercury-agent) | [goose](https://github.com/block/goose)  
> [codex](https://github.com/openai/codex) | [claude](https://github.com/anthropics/claude-code) | [gemini](https://github.com/google-gemini/gemini-cli)  

## what this is

`aelab` is a repo-native control plane for operating multiple AI agents across one or more hosts.

AI agent tooling is fragmented: different agents come with different CLIs, auth flows, runtime assumptions, and service models. `aelab` does **not** replace them with yet another framework. It gives them a shared operating model instead:
- each agent lives as a plain directory in one repo
- manifests define reusable runtime conventions
- host config decides what runs where
- one CLI and one infra model operate the whole setup

The result is a mixed fleet that stays legible, inspectable, scriptable, and customizable while preserving each agent's native commands and workflow.

## what you get

- manage multiple agents across multiple hosts as plain directories in one repo
- bootstrap and command unrelated agents from one place
- forward native agent commands directly (`help`, `onboard`, `status`, `--tui`, etc.)
- expose live status of agents and services through the built-in web UI
- access running host shells from desktop or mobile through the built-in tty server
- customize templates and manifests freely; bundled agents and services are examples

## quick mental model

- `agents/` holds one working directory per agent
- `config/` defines agent kinds, services, ports, and host assignment
- `infra/` renders and manages the host-side runtime
- `shared/` is common space across agents
- `ae` is the single CLI entrypoint

## quick start

- run managed agents and shared services under a dedicated `agent` user
- clone this repo into a shared host path and make it writable by `agent` and other groups/users
- without `swift` on `$PATH`, invoke `bash infra/commands/bootstrap.sh` directly
- make a few agents: `./ae make 001-codex && ./ae make 002-claude && ./ae make 003-gemini`
- define your `config/custom/host/.env` file and run `./ae infra bootstrap && ./ae infra start`

## repo layout

- [`agents/`](agents/) — one working directory per agent
- [`config/`](config/) — agent kinds, services, ports, and host assignment
- [`infra/`](infra/) — machine bootstrap and service supervision
- [`shared/`](shared/) — common space across agents
- [`ae`](ae) — unified CLI for agents and infra commands

## command tree

```text
ae
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
│   ├── yolo ...                              # run tui with bypass args when supported
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
    ├── render [<all|brew|caddy|front>]       # render generated infra files
    └── update [<target>...]                  # pull latest and restart targets
```

> **target** can be explicit as `agents` or `services` (affects all), or an agent id, or a service id; for example: `agents services` or `003 005 007` or `core some-service` (or any combination of those).

## common flows

A few representative workflows:

### List local agents

```bash
./ae list
```

### Create and use an agent interactively

Stop a foreground agent run with `Ctrl-C`.

```bash
./ae make 001-openclaw
./ae 001 bootstrap
./ae 001 onboard --skip-daemon
./ae 001 start

./ae make 004-picoclaw
./ae 004 bootstrap
./ae 004 auth login --provider anthropic
./ae 004 start

./ae make 007-zeroclaw
./ae 007 bootstrap
./ae 007 auth paste-redirect --provider openai-codex --profile default
./ae 007 start

./ae make 011-hermes
./ae 011 bootstrap
./ae 011 setup
./ae 011 --tui
./ae 011 start

./ae make 021-mercury
./ae 021 bootstrap
...
```

### Open an agent directory in `$EDITOR`

```bash
./ae 001 edit
```

### Remove an agent and its service-manager artifact

```bash
./ae remove 011
```

### Customize the host `.env`

Examples: [macOS](config/custom/host/.env.example-macos) | [Linux](config/custom/host/.env.example-linux) | [WSL](config/custom/host/.env.example-wsl)

```bash
AELAB_AGENTS="001 002 003 004 005 006 007"
AELAB_SERVICES="core" # core expands to core-http, core-tty, and caddy
AELAB_PROJECTS=".dotfiles=/Users/tadija/.dotfiles aelab=/Users/Shared/aelab"
```

### Manage host-assigned infra targets

Omit explicit targets to affect all.

```bash
./ae infra bootstrap
./ae infra start
./ae infra status
./ae infra log
```

### Operate on explicit agents or services directly

```bash
./ae infra install core agents services
./ae infra start services 003 005
./ae infra restart core 001 002 006
./ae infra status 000 004 007
./ae infra doctor services 007 --repair
./ae infra log 003 005 core
./ae infra stop 008 core-http core-tty
./ae infra uninstall 011 core
```

### Render derived infra files manually

```bash
./ae infra render <all|brew|caddy|front>
```

## screenshots

### desktop

<table>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/53cfa365-38cc-43c2-8ef5-182104f59adc"><img src="https://github.com/user-attachments/assets/53cfa365-38cc-43c2-8ef5-182104f59adc" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/8f4d0859-9403-4267-bd42-793ee1ae7bee"><img src="https://github.com/user-attachments/assets/8f4d0859-9403-4267-bd42-793ee1ae7bee" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/2c681448-75b8-4e11-abed-8aef0c551f0e"><img src="https://github.com/user-attachments/assets/2c681448-75b8-4e11-abed-8aef0c551f0e" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/2d18be6a-9c5b-4c66-a560-448b4d5fda16"><img src="https://github.com/user-attachments/assets/2d18be6a-9c5b-4c66-a560-448b4d5fda16" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/3c799f45-c894-4f37-a4ea-f21157c0f8f3"><img src="https://github.com/user-attachments/assets/3c799f45-c894-4f37-a4ea-f21157c0f8f3" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/1ffc079d-ca17-4a93-b870-19c0121640c4"><img src="https://github.com/user-attachments/assets/1ffc079d-ca17-4a93-b870-19c0121640c4" width="130"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/11ed7ff2-6465-4cc4-9fad-fdf4edbbb768"><img src="https://github.com/user-attachments/assets/11ed7ff2-6465-4cc4-9fad-fdf4edbbb768" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/096e5e47-c398-4ab4-8cae-a2eb2e1143bf"><img src="https://github.com/user-attachments/assets/096e5e47-c398-4ab4-8cae-a2eb2e1143bf" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/772a1e22-5069-467d-9640-6563f68652a8"><img src="https://github.com/user-attachments/assets/772a1e22-5069-467d-9640-6563f68652a8" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/0d98c1ce-128e-423c-b9a6-201d2a4d20d4"><img src="https://github.com/user-attachments/assets/0d98c1ce-128e-423c-b9a6-201d2a4d20d4" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/18644049-43a1-4197-b816-6193959a4208"><img src="https://github.com/user-attachments/assets/18644049-43a1-4197-b816-6193959a4208" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/acfd62dc-7c2f-4a77-991b-23d707c4a29a"><img src="https://github.com/user-attachments/assets/acfd62dc-7c2f-4a77-991b-23d707c4a29a" width="130"></a></td>
  </tr>
</table>

### mobile

<table>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/3523ad2e-e16b-490e-9ccc-bc7d1b09c60b"><img src="https://github.com/user-attachments/assets/3523ad2e-e16b-490e-9ccc-bc7d1b09c60b" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/2f1b9050-4960-4c32-8400-a1b5d67c7d67"><img src="https://github.com/user-attachments/assets/2f1b9050-4960-4c32-8400-a1b5d67c7d67" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/a49bdeb2-0087-4ccf-b6b3-0b58bb6f5ebf"><img src="https://github.com/user-attachments/assets/a49bdeb2-0087-4ccf-b6b3-0b58bb6f5ebf" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/4355af55-16b7-4059-9cb5-456df6dc8bce"><img src="https://github.com/user-attachments/assets/4355af55-16b7-4059-9cb5-456df6dc8bce" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/c91365be-6eef-44e1-8d7b-d1c208808f2b"><img src="https://github.com/user-attachments/assets/c91365be-6eef-44e1-8d7b-d1c208808f2b" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/8c39e01e-36ae-404c-bd7f-a4f71f0ae6bf"><img src="https://github.com/user-attachments/assets/8c39e01e-36ae-404c-bd7f-a4f71f0ae6bf" width="130"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/52370259-156a-4afb-8501-ccf34cd16b51"><img src="https://github.com/user-attachments/assets/52370259-156a-4afb-8501-ccf34cd16b51" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/661ea916-954c-4414-8a5c-dfba7777e473"><img src="https://github.com/user-attachments/assets/661ea916-954c-4414-8a5c-dfba7777e473" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/58e58b58-0a30-4610-b528-ac3d43570d5c"><img src="https://github.com/user-attachments/assets/58e58b58-0a30-4610-b528-ac3d43570d5c" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/4fa9f14d-2403-4948-8375-b2649fb14b27"><img src="https://github.com/user-attachments/assets/4fa9f14d-2403-4948-8375-b2649fb14b27" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/8d42acaf-ccbb-4670-8c75-1219db338c8f"><img src="https://github.com/user-attachments/assets/8d42acaf-ccbb-4670-8c75-1219db338c8f" width="130"></a></td>
    <td><a href="https://github.com/user-attachments/assets/c481abec-32d5-4ca9-a909-484af39bd68b"><img src="https://github.com/user-attachments/assets/c481abec-32d5-4ca9-a909-484af39bd68b" width="130"></a></td>
  </tr>
</table>

## technical notes

- requires `swift` on `$PATH` since [`ae`](ae) is a [Swift](https://github.com/swiftlang/swift) script
- agent kinds are defined in [`config/agents/`](config/agents/)
- shared services are defined in [`config/services/`](config/services/)
- repo-wide parsed config is defined in [`config/custom/repo.ini`](config/custom/repo.ini)
- toggle version control manually in [`.gitignore`](.gitignore)

---

`done for fun`

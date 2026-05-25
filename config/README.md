# aelab-config

**repo-wide manifests for agents, services, ports, and host aliases**

> **works on**: macOS | Linux | WSL  
> **docs**: [home](../README.md) | config | [infra](../infra/README.md)  

## overview

This directory is the repo-wide catalog for what `aelab` knows how to run.

In short, `config/` is where `aelab` turns a pile of separate tools into one operable system.

## what lives here

- `agents/` — reusable runtime conventions for agent kinds
- `services/` — shared dependencies and operator-facing services
- `custom/host/` — per-machine assignment and host-specific settings
- `custom/env/` — shared and per-target runtime environment overrides
- `custom/override/` — manifest and infra command overrides
- `repo.ini` — parsed repo-wide values such as ports and host aliases

## layout

```text
config/
  README.md
  agents/
    claude.env
    codex.env
    gemini.env
    goose.env
    hermes.env
    mercury.env
    moltis.env
    nanobot.env
    nullclaw.env
    openclaw.env
    pi.env
    picoclaw.env
    zeroclaw.env
  services/
    core.env
    core-http.env
    core-tty.env
    mongodb.env
    mysql.env
    nats.env
    postgres.env
    tailscale.env
  custom/
    repo.ini
    host/
      .env
      .env.example-macos
      .env.example-linux
      .env.example-wsl
    env/
      agents/
        .gitkeep
      services/
        .gitkeep
    override/
      agents/
        .gitkeep
      infra/
        .gitkeep
      services/
        .gitkeep
```

## agent manifests

Each file in `config/agents/` defines one agent kind.

Override behavior:
- a same-name file under `config/custom/override/agents/` is sourced after the base file and can override any variable
- a file that exists only under `config/custom/override/agents/` defines a custom agent kind
- the filename and `AELAB_AGENT_KIND` must match

```bash
AELAB_AGENT_KIND="hermes"
AELAB_AGENT_ENV="HOME=__AGENT_DIR__|HERMES_HOME=__AGENT_DIR__/.hermes"
AELAB_AGENT_INSTALL_KIND="script"
AELAB_AGENT_INSTALL_SCRIPT="infra/utils/installers/hermes.sh"
AELAB_AGENT_SETUP_ARGS="hermes|setup"
AELAB_AGENT_TUI_ARGS="hermes|--tui"
AELAB_AGENT_TUI_YOLO_ARGS=""
AELAB_AGENT_START_ARGS="hermes|gateway"
AELAB_AGENT_FORWARD_PREFIX="hermes"
```

### Common agent fields

- `AELAB_AGENT_KIND` is the canonical kind name, matching `config/agents/<kind>.env` or `config/custom/override/agents/<kind>.env`
- `AELAB_AGENT_BREW_TAPS`, `AELAB_AGENT_BREW_PACKAGES`, and `AELAB_AGENT_BREW_CASKS` add Homebrew dependencies to the generated Brewfile
- `AELAB_AGENT_INSTALL_KIND="script"` and `AELAB_AGENT_INSTALL_SCRIPT` opt into a custom installer during bootstrap
- `AELAB_AGENT_HOME_ENV` sets a single home env var to the agent working directory
- `AELAB_AGENT_ENV` sets explicit env vars, separated with `|`
- `AELAB_AGENT_SETUP_ARGS` defines the command run by `./ae <agent-id> setup` and by `./ae make <agent-id-agent-kind>`
- `AELAB_AGENT_TUI_ARGS` defines the command run by `./ae <agent-id> tui`; bare `./ae <agent-id>` uses this when present
- `AELAB_AGENT_TUI_YOLO_ARGS` defines the command run by `./ae <agent-id> yolo`; when omitted, yolo launch actions are hidden
- `AELAB_AGENT_START_ARGS` defines the command run by `./ae <agent-id> start`
- `AELAB_AGENT_START_PORT_FLAG` appends the agent port to the start command with a named flag, such as `--port`
- `AELAB_AGENT_STOP_ARGS` defines the command run by `./ae <agent-id> stop`; when omitted, stop falls back to killing the start command pattern if start is defined
- `AELAB_AGENT_FORWARD_PREFIX` defines how unknown `./ae <agent-id> ...` commands are forwarded to the native agent CLI

Agent command templates use `|` as an argument separator so values can be represented safely in `.env` files.

### Supported placeholders

- `__AGENT_DIR__` expands to the concrete agent working directory, such as `agents/007-hermes`
- `__COMMAND__` expands to the forwarded subcommand for forwarding templates

## custom config

Files under `config/custom/` customize this repo without editing the shared manifests.

At a glance:
- `host/` picks what a machine should run
- `env/` injects shared or per-target runtime environment
- `override/` patches or adds agent kinds, services, and infra commands
- `repo.ini` holds parsed repo-wide values consumed by the CLI and renderers

Override agent and service `.env` files can either override same-name defaults or define new agent kinds and services when no base file exists.

### `host/.env`

`custom/host/.env` is the per-machine assignment file. Copy the matching example from `custom/host/.env.example-*` and edit it for the current host.

```bash
AELAB_HOST="dev-server"
AELAB_ROOT="/opt/aelab"
AELAB_USER="agent"
AELAB_GROUP="agent"
AELAB_AGENTS="021 022 023 024 025"
AELAB_SERVICES="core"
AELAB_PROJECTS="aelab=/opt/aelab app=/srv/app"
AELAB_TAILSCALE_ONLY="false"
```

- `AELAB_HOST` names the current host for generated infra and placeholders
- `AELAB_ROOT` points at the active repo checkout
- `AELAB_USER` and `AELAB_GROUP` set the managed process owner
- `AELAB_AGENTS` lists the agent ids assigned to this host
- `AELAB_SERVICES` lists the shared service ids assigned to this host
- `AELAB_PROJECTS` lists project rows as `title=/absolute/path` pairs; `/tty/<title>/` opens a shell in that path, and the project action menu opens supported interactive agent TUIs in that same path
- `AELAB_TAILSCALE_ONLY=true` restricts generated Caddy routes to Tailscale IPs and localhost

`custom/host/.env` is gitignored for local host selection; `custom/repo.ini`, examples, and custom agent/service manifests are tracked.

### `repo.ini`

`custom/repo.ini` contains parsed repo-level values such as agent ports, service ports, and host aliases.

```ini
[hosts]
dev-server=http://dev-server/
app-server=http://app-server/
data-server=http://data-server/

[agent-ports]
000=42607
001=18789
002=18799
003=18809
004=18819
005=42617
006=42627
007=8642
008=8652

[service-ports]
core-http=2108
core-tty=1984
mysql=3306
postgres=5432
mongodb=27017
nats=4222

[tty-buttons]
ctrl-c=C-c
ctrl-d=C-d
ctrl-z=C-z
ctrl-l=C-l
ctrl-r=C-r
ctrl-u=C-u
ctrl-a=C-a
ctrl-j=C-j
alt=Alt

escape=Esc
tab=Tab
enter=Enter
backspace=Bksp
delete=Del

home=Home
end=End
page-up=PgUp
page-down=PgDn

up=Up
down=Down
left=Left
right=Right

scroll-up=ScUp
scroll-down=ScDn
copy-mode=Copy
```

The `[agent-ports]` section maps plain agent ids to gateway ports. The CLI uses these ports when starting agents, and Caddy rendering uses them to build agent routes.

The `[service-ports]` section maps service ids to their Caddy-facing ports. Values are available as `__SERVICE_PORT__` in service env files and expanded at runtime.

The `[hosts]` section maps host aliases to base URLs for the generated landing page.

The `[tty-buttons]` section controls the floating mobile key dock on `/tty/` pages. Keys are rendered in file order and values are button labels. Blank lines are ignored and can be used to group related keys visually. If the section is absent the dock shows a hint to configure it. Supported keys: `alt`, `backspace`, `copy-mode`, `ctrl-a`–`ctrl-z` variants, `delete`, `down`, `end`, `enter`, `escape`, `home`, `left`, `page-down`, `page-up`, `right`, `scroll-down`, `scroll-up`, `tab`, `up`. Special behaviours: `copy-mode` sends `Ctrl+A [` (tmux copy mode, assumes Ctrl+A prefix); `scroll-up`/`scroll-down` scroll the xterm viewport without sending any key to the shell.

## service manifests

Each file in `config/services/` defines one shared service.

Override behavior:
- a same-name file under `config/custom/override/services/` is sourced after the base file and can override any variable
- a file that exists only under `config/custom/override/services/` defines a custom service
- the filename and `AELAB_SERVICE_ID` must match

```bash
AELAB_SERVICE_ID="caddy"
AELAB_SERVICE_DESCRIPTION="Caddy web server"
AELAB_SERVICE_BIN="caddy"
AELAB_SERVICE_BREW_PACKAGES="caddy"
AELAB_SERVICE_ARGS='run --config "__AELAB_ROOT__/infra/generated/Caddyfile" --adapter caddyfile'
```

### Common service fields

- `AELAB_SERVICE_ID` is the canonical service id, matching `config/services/<service>.env` or `config/custom/override/services/<service>.env`
- `AELAB_SERVICE_DESCRIPTION` is rendered into launchd/systemd metadata
- `AELAB_SERVICE_BIN` is the executable or wrapper script to run
- `AELAB_SERVICE_ARGS` is appended to the service binary when starting the service
- `AELAB_SERVICE_RELOAD_ARGS` defines a reload command when the service supports one
- `AELAB_SERVICE_STOP_COMMAND` defines an explicit stop command when needed
- `AELAB_SERVICE_STDOUT` and `AELAB_SERVICE_STDERR` override the default service log paths
- `AELAB_SERVICE_BREW_TAPS`, `AELAB_SERVICE_BREW_PACKAGES`, and `AELAB_SERVICE_BREW_CASKS` add Homebrew dependencies
- `AELAB_SERVICE_BREW_PACKAGES_MACOS_ARM64` and `AELAB_SERVICE_BREW_CASKS_MACOS_ARM64` override Homebrew dependencies on Apple Silicon macOS
- `AELAB_SERVICE_INSTALL_OPTIONAL="true"` lets bootstrap/install continue if this service's installer fails
- `AELAB_SERVICE_INSTALL_KIND="script"` and `AELAB_SERVICE_INSTALL_SCRIPT` opt into a custom installer during bootstrap
- `AELAB_SERVICE_GROUP_MEMBERS` makes a manifest a service group that expands to multiple service ids
- `AELAB_SERVICE_ENV` sets launchd/systemd environment variables, separated with `|`
- `AELAB_SERVICE_DIR` overrides the runtime directory, defaulting to `__AELAB_ROOT__/state/runtimes/__SERVICE_ID__`
- `AELAB_SERVICE_STATE_DIRS` lists runtime directories that infra should create before install/start
- `AELAB_SERVICE_USER`, `AELAB_SERVICE_GROUP`, and `AELAB_SERVICE_WORKING_DIRECTORY` control process ownership and cwd
- `AELAB_SERVICE_AFTER` and `AELAB_SERVICE_WANTS` render systemd dependency metadata
- `AELAB_SERVICE_RESTART` and `AELAB_SERVICE_RESTART_SEC` tune service-manager restart behavior
- `AELAB_SERVICE_SYSTEMD_NAME` and `AELAB_SERVICE_LAUNCHD_LABEL` override generated service-manager ids
- `AELAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE` adds a systemd-only environment file
- `AELAB_SERVICE_SYSTEMD_*` fields expose systemd-only hardening and capability settings
- `AELAB_SERVICE_CADDY_ROUTE` exposes the service behind Caddy; use `/path`, `:port`, or `host[:port]`
- `AELAB_SERVICE_CADDY_UPSTREAM` sets the backend Caddy forwards to

### Supported placeholders

- `__AELAB_ROOT__` expands to the active repo root from `config/custom/host/.env`
- `__AELAB_USER__` expands to the managed process user from `config/custom/host/.env`
- `__AELAB_GROUP__` expands to the shared group from `config/custom/host/.env`
- `__AELAB_HOST__` expands to the active host name from `config/custom/host/.env`
- `__SERVICE_ID__` expands to the service id
- `__AELAB_SERVICE_DIR__` expands to the resolved service runtime directory

## infra overrides and runtime env

`custom/override/infra/<command>.sh` adds private infra subcommands, or overrides a built-in command when the names match. Custom infra commands are invoked through `./ae infra <command>` and can source `infra/commands/core.sh` to reuse host-env loading, target resolution, manifest loading, and service-manager helpers.

Runtime environment that should apply outside manifests lives under `custom/env/`.

- `custom/env/agents.env` applies to all agents
- `custom/env/agents/<agent-id>.env` adds or overrides values for one agent
- `custom/env/services.env` applies to all services
- `custom/env/services/<service-id>.env` adds or overrides values for one service

Agents load shared values first and per-agent values second before running the native command; managed agents receive the same files through systemd `EnvironmentFile` on Linux or rendered launchd plist values on macOS.

Services load manifest `AELAB_SERVICE_ENV` first, then `custom/env/services.env`, then `custom/env/services/<service-id>.env`. Managed services receive those files through systemd `EnvironmentFile` on Linux or rendered launchd plist values on macOS.

## conventions

- Keep shared manifests declarative; put reusable install/runtime logic under `infra/utils/installers/` or `infra/utils/launchers/`, and host-specific infra commands in `config/custom/override/infra/`
- Prefer repo-local state under `state/runtimes/` and logs under `state/logs/`
- Use custom installers for tools that cannot be represented cleanly as Homebrew packages
- Keep agent ids plain, such as `007`; the CLI resolves the concrete working directory name

# clawlab-config

**repo-wide manifests for agents, services, ports, and host aliases**

> **works on**: macOS | Linux | WSL  
> **docs**: [home](../README.md) | config | [infra](../infra/README.md)  

## overview

This directory is the repo-wide catalog for things clawlab knows how to run. Agent and service manifests describe reusable defaults; files under `custom/` hold host config, parsed repo config, agent/service customizations, and custom infra commands.

```
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
    caddy.env
    dash-http.env
    dash-tty.env
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

Each file in `config/agents/` defines one agent kind. A same-name file under `config/custom/override/agents/` is sourced after the base file and can override any variable. A file that exists only under `config/custom/override/agents/` defines a custom agent kind. The filename and `CLAWLAB_AGENT_KIND` must match.

```bash
CLAWLAB_AGENT_KIND="hermes"
CLAWLAB_AGENT_ENV="HOME=__AGENT_DIR__|HERMES_HOME=__AGENT_DIR__/.hermes"
CLAWLAB_AGENT_INSTALL_KIND="script"
CLAWLAB_AGENT_INSTALL_SCRIPT="infra/installers/hermes.sh"
CLAWLAB_AGENT_SETUP_ARGS="hermes|setup"
CLAWLAB_AGENT_TUI_ARGS="hermes|--tui"
CLAWLAB_AGENT_START_ARGS="hermes|gateway"
CLAWLAB_AGENT_FORWARD_PREFIX="hermes"
```

Common agent fields:

- `CLAWLAB_AGENT_KIND` is the canonical kind name, matching `config/agents/<kind>.env` or `config/custom/override/agents/<kind>.env`
- `CLAWLAB_AGENT_BREW_TAPS`, `CLAWLAB_AGENT_BREW_PACKAGES`, and `CLAWLAB_AGENT_BREW_CASKS` add Homebrew dependencies to the generated Brewfile
- `CLAWLAB_AGENT_INSTALL_KIND="script"` and `CLAWLAB_AGENT_INSTALL_SCRIPT` opt into a custom installer during bootstrap
- `CLAWLAB_AGENT_HOME_ENV` sets a single home env var to the agent working directory
- `CLAWLAB_AGENT_ENV` sets explicit env vars, separated with `|`
- `CLAWLAB_AGENT_SETUP_ARGS` defines the command run by `./cmd <agent-id> setup` and by `./cmd make <agent-id-agent-kind>`
- `CLAWLAB_AGENT_TUI_ARGS` defines the command run by `./cmd <agent-id> tui`; bare `./cmd <agent-id>` uses this when present
- `CLAWLAB_AGENT_START_ARGS` defines the command run by `./cmd <agent-id> start`
- `CLAWLAB_AGENT_START_PORT_FLAG` appends the agent port to the start command with a named flag, such as `--port`
- `CLAWLAB_AGENT_STOP_ARGS` defines the command run by `./cmd <agent-id> stop`; when omitted, stop falls back to killing the start command pattern if start is defined
- `CLAWLAB_AGENT_FORWARD_PREFIX` defines how unknown `./cmd <agent-id> ...` commands are forwarded to the native agent CLI

Agent command templates use `|` as an argument separator so values can be represented safely in `.env` files.

Supported placeholders:

- `__AGENT_DIR__` expands to the concrete agent working directory, such as `agents/007-hermes`
- `__COMMAND__` expands to the forwarded subcommand for forwarding templates

## custom config

Files under `config/custom/` customize this repo without editing the shared manifests. Override agent and service `.env` files can either override same-name defaults or define new agent kinds and services when no base file exists.

### host/.env

`custom/host/.env` is the per-machine assignment file. Copy the matching example from `custom/host/.env.example-*` and edit it for the current host.

```bash
CLAWLAB_HOST="dev-server"
CLAWLAB_ROOT="/opt/clawlab"
CLAWLAB_USER="agent"
CLAWLAB_GROUP="agent"
CLAWLAB_AGENTS="000 004 007"
CLAWLAB_SERVICES="tailscale caddy"
CLAWLAB_PROJECTS="clawlab=/opt/clawlab app=/srv/app"
CLAWLAB_TAILSCALE_ONLY="false"
```

- `CLAWLAB_HOST` names the current host for generated infra and placeholders
- `CLAWLAB_ROOT` points at the active repo checkout
- `CLAWLAB_USER` and `CLAWLAB_GROUP` set the managed process owner
- `CLAWLAB_AGENTS` lists the agent ids assigned to this host
- `CLAWLAB_SERVICES` lists the shared service ids assigned to this host
- `CLAWLAB_PROJECTS` lists dashboard project rows as `title=/absolute/path` pairs; `/tty/<title>/` opens a shell in that path, and the project action menu opens supported interactive agent TUIs in that same path
- `CLAWLAB_TAILSCALE_ONLY=true` restricts generated Caddy routes to Tailscale IPs and localhost

`custom/host/.env` is gitignored for local host selection; `custom/repo.ini`, examples, and custom agent/service manifests are tracked.

### repo.ini

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
dash-http=2108
dash-tty=1984
mysql=3306
postgres=5432
mongodb=27017
nats=4222
```

The `[agent-ports]` section maps plain agent ids to gateway ports. The CLI uses these ports when starting agents, and Caddy rendering uses them to build agent routes.

The `[service-ports]` section maps service ids to their Caddy-facing ports. Values are available as `__SERVICE_PORT__` in service env files and expanded at runtime.

The `[hosts]` section maps host aliases to base URLs for the generated landing page.

## service manifests

Each file in `config/services/` defines one shared service. A same-name file under `config/custom/override/services/` is sourced after the base file and can override any variable. A file that exists only under `config/custom/override/services/` defines a custom service. The filename and `CLAWLAB_SERVICE_ID` must match.

```bash
CLAWLAB_SERVICE_ID="caddy"
CLAWLAB_SERVICE_DESCRIPTION="Caddy web server"
CLAWLAB_SERVICE_BIN="caddy"
CLAWLAB_SERVICE_BREW_PACKAGES="caddy"
CLAWLAB_SERVICE_ARGS='run --config "__CLAWLAB_ROOT__/infra/generated/Caddyfile" --adapter caddyfile'
CLAWLAB_SERVICE_CADDY_ROOT_SERVICE_IDS="dash-http dash-tty"
```

Common service fields:

- `CLAWLAB_SERVICE_ID` is the canonical service id, matching `config/services/<service>.env` or `config/custom/override/services/<service>.env`
- `CLAWLAB_SERVICE_DESCRIPTION` is rendered into launchd/systemd metadata
- `CLAWLAB_SERVICE_BIN` is the executable or wrapper script to run
- `CLAWLAB_SERVICE_ARGS` is appended to the service binary when starting the service
- `CLAWLAB_SERVICE_RELOAD_ARGS` defines a reload command when the service supports one
- `CLAWLAB_SERVICE_STOP_COMMAND` defines an explicit stop command when needed
- `CLAWLAB_SERVICE_STDOUT` and `CLAWLAB_SERVICE_STDERR` override the default service log paths
- `CLAWLAB_SERVICE_BREW_TAPS`, `CLAWLAB_SERVICE_BREW_PACKAGES`, and `CLAWLAB_SERVICE_BREW_CASKS` add Homebrew dependencies
- `CLAWLAB_SERVICE_BREW_PACKAGES_MACOS_ARM64` and `CLAWLAB_SERVICE_BREW_CASKS_MACOS_ARM64` override Homebrew dependencies on Apple Silicon macOS
- `CLAWLAB_SERVICE_INSTALL_OPTIONAL="true"` lets bootstrap/install continue if this service's installer fails
- `CLAWLAB_SERVICE_INSTALL_KIND="script"` and `CLAWLAB_SERVICE_INSTALL_SCRIPT` opt into a custom installer during bootstrap
- `CLAWLAB_SERVICE_ENV` sets launchd/systemd environment variables, separated with `|`
- `CLAWLAB_SERVICE_DIR` overrides the runtime directory, defaulting to `__CLAWLAB_ROOT__/state/runtimes/__SERVICE_ID__`
- `CLAWLAB_SERVICE_STATE_DIRS` lists runtime directories that infra should create before install/start
- `CLAWLAB_SERVICE_USER`, `CLAWLAB_SERVICE_GROUP`, and `CLAWLAB_SERVICE_WORKING_DIRECTORY` control process ownership and cwd
- `CLAWLAB_SERVICE_AFTER` and `CLAWLAB_SERVICE_WANTS` render systemd dependency metadata
- `CLAWLAB_SERVICE_RESTART` and `CLAWLAB_SERVICE_RESTART_SEC` tune service-manager restart behavior
- `CLAWLAB_SERVICE_SYSTEMD_NAME` and `CLAWLAB_SERVICE_LAUNCHD_LABEL` override generated service-manager ids
- `CLAWLAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE` adds a systemd-only environment file
- `CLAWLAB_SERVICE_SYSTEMD_*` fields expose systemd-only hardening and capability settings
- `CLAWLAB_SERVICE_CADDY_ROUTE` exposes the service behind Caddy; use `/path`, `:port`, or `host[:port]`
- `CLAWLAB_SERVICE_CADDY_UPSTREAM` sets the backend Caddy forwards to
- `CLAWLAB_SERVICE_CADDY_ROOT_UPSTREAM` marks a service as the generated Caddy root upstream
- `CLAWLAB_SERVICE_CADDY_ROOT_SERVICE_IDS` on `caddy` chooses the preferred root helper services; the first entry is used for the root upstream and the full list is treated as managed by caddy

Supported placeholders:

- `__CLAWLAB_ROOT__` expands to the active repo root from `config/custom/host/.env`
- `__CLAWLAB_USER__` expands to the managed process user from `config/custom/host/.env`
- `__CLAWLAB_GROUP__` expands to the shared group from `config/custom/host/.env`
- `__CLAWLAB_HOST__` expands to the active host name from `config/custom/host/.env`
- `__SERVICE_ID__` expands to the service id
- `__CLAWLAB_SERVICE_DIR__` expands to the resolved service runtime directory

## infra

`custom/override/infra/<command>.sh` adds private infra subcommands, or overrides a built-in command when the names match. Custom infra commands are invoked through `./cmd infra <command>` and can source `infra/commands/core.sh` to reuse host-env loading, target resolution, manifest loading, and service-manager helpers.

Runtime environment that should apply outside manifests lives under `custom/env/`.

- `custom/env/agents.env` applies to all agents
- `custom/env/agents/<agent-id>.env` adds or overrides values for one agent
- `custom/env/services.env` applies to all services
- `custom/env/services/<service-id>.env` adds or overrides values for one service

Agents load shared values first and per-agent values second before running the native command; managed agents receive the same files through systemd `EnvironmentFile` on Linux or rendered launchd plist values on macOS.

Services load manifest `CLAWLAB_SERVICE_ENV` first, then `custom/env/services.env`, then `custom/env/services/<service-id>.env`. Managed services receive those files through systemd `EnvironmentFile` on Linux or rendered launchd plist values on macOS.

## conventions

- Keep shared manifests declarative; put reusable install/runtime logic in `infra/installers/` or `infra/utils/`, and host-specific infra commands in `config/custom/override/infra/`
- Prefer repo-local state under `state/runtimes/` and logs under `state/logs/`
- Use custom installers for tools that cannot be represented cleanly as Homebrew packages
- Keep agent ids plain, such as `007`; the CLI resolves the concrete working directory name

# config

**repo-wide manifests for agents, services, ports, and host aliases**

> **docs**: [home](../README.md) | config | [infra](../infra/README.md)
>  
> **play with**: [openclaw](https://github.com/openclaw/openclaw) | [picoclaw](https://github.com/sipeed/picoclaw) | [zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) | [nullclaw](https://github.com/nullclaw/nullclaw) | [nanobot](https://github.com/HKUDS/nanobot) | [pi](https://github.com/earendil-works/pi) | [hermes](https://github.com/nousresearch/hermes-agent) | [moltis](https://github.com/moltis-org/moltis) | [mercury](https://github.com/cosmicstack-labs/mercury-agent) | [goose](https://github.com/block/goose) | [codex](https://github.com/openai/codex) | [claude](https://github.com/anthropics/claude-code) | [gemini](https://github.com/google-gemini/gemini-cli)  
>
> **works on**: macOS | Linux | WSL

## overview

`config/` is the repo-wide catalog for what `aelab` knows how to run.

## layout

```text
config/
  agents.toml            # agent kind manifests
  services.toml          # shared service manifests
  repo.toml              # repo-wide host aliases, ports, and deploy hosts
  host.toml              # per-host runtime config, copied from host.example.toml
  host.example.toml      # commented host template
  env/                   # shared and per-target runtime env files
  infra/                 # optional custom infra commands and hooks
```

## agent manifests

`agents.toml` defines reusable agent kinds as top-level TOML tables:

```toml
[codex]
AELAB_AGENT_KIND = "codex"
AELAB_AGENT_BREW_CASKS = "codex"
AELAB_AGENT_TUI_ARGS = "codex"
AELAB_AGENT_TUI_YOLO_ARGS = "codex|--dangerously-bypass-approvals-and-sandbox"
AELAB_AGENT_SETUP_ARGS = "codex"
AELAB_AGENT_FORWARD_PREFIX = "codex"
```

Common fields:

- `AELAB_AGENT_KIND` is the canonical kind name and should match the table name
- `AELAB_AGENT_BREW_TAPS`, `AELAB_AGENT_BREW_PACKAGES`, and `AELAB_AGENT_BREW_CASKS` add Homebrew dependencies
- `AELAB_AGENT_INSTALL_KIND="script"` and `AELAB_AGENT_INSTALL_SCRIPT` opt into an installer during bootstrap
- `AELAB_AGENT_HOME_ENV` sets a single home env var to the agent working directory
- `AELAB_AGENT_ENV` sets explicit env vars, separated with `|`
- `AELAB_AGENT_SETUP_ARGS`, `AELAB_AGENT_TUI_ARGS`, `AELAB_AGENT_TUI_YOLO_ARGS`, `AELAB_AGENT_START_ARGS`, and `AELAB_AGENT_STOP_ARGS` define command templates
- `AELAB_AGENT_START_PORT_FLAG` appends the assigned port to the start command
- `AELAB_AGENT_FORWARD_PREFIX` defines how unknown `./ae <agent-id> ...` commands forward to the native CLI

Command templates use `|` as an argument separator. `__AGENT_DIR__` expands to the concrete agent working directory, and `__COMMAND__` expands to the forwarded subcommand.

## service manifests

`services.toml` defines shared services as top-level TOML tables:

```toml
[caddy]
AELAB_SERVICE_ID = "caddy"
AELAB_SERVICE_DESCRIPTION = "Caddy web server"
AELAB_SERVICE_BIN = "caddy"
AELAB_SERVICE_BREW_PACKAGES = "caddy"
AELAB_SERVICE_ARGS = "run --config \"__AELAB_ROOT__/infra/generated/Caddyfile\" --adapter caddyfile"
```

Common fields:

- `AELAB_SERVICE_ID` is the canonical service id and should match the table name
- `AELAB_SERVICE_DESCRIPTION`, `AELAB_SERVICE_BIN`, `AELAB_SERVICE_ARGS`, `AELAB_SERVICE_RELOAD_ARGS`, and `AELAB_SERVICE_STOP_COMMAND` define the service command surface
- `AELAB_SERVICE_BREW_TAPS`, `AELAB_SERVICE_BREW_PACKAGES`, and `AELAB_SERVICE_BREW_CASKS` add Homebrew dependencies
- `AELAB_SERVICE_INSTALL_OPTIONAL`, `AELAB_SERVICE_INSTALL_KIND`, and `AELAB_SERVICE_INSTALL_SCRIPT` tune bootstrap/install hooks
- `AELAB_SERVICE_GROUP_MEMBERS` makes a table a service group that expands to multiple service ids
- `AELAB_SERVICE_ENV` sets launchd/systemd environment variables, separated with `|`
- `AELAB_SERVICE_DIR`, `AELAB_SERVICE_STATE_DIRS`, `AELAB_SERVICE_USER`, `AELAB_SERVICE_GROUP`, and `AELAB_SERVICE_WORKING_DIRECTORY` control runtime layout and ownership
- `AELAB_SERVICE_AFTER`, `AELAB_SERVICE_WANTS`, `AELAB_SERVICE_RESTART`, and `AELAB_SERVICE_RESTART_SEC` tune service-manager behavior
- `AELAB_SERVICE_CADDY_ROUTE` and `AELAB_SERVICE_CADDY_UPSTREAM` expose the service behind Caddy

Supported placeholders include `__AELAB_ROOT__`, `__AELAB_USER__`, `__AELAB_GROUP__`, `__SERVICE_ID__`, `__SERVICE_PORT__`, and `__AELAB_SERVICE_DIR__`.

## repo config

`repo.toml` contains repo-wide values:

```toml
[hosts]
dev-server = "https://dev-server/"

[deploy-hosts]
dev-server = "agent@dev-server:/Users/Shared/.aelab"

[agent-ports]
001 = "18789"

[service-ports]
core-http = "2108"
core-tty = "1984"
```

- `[hosts]` maps host aliases to base URLs for the generated landing page and `./ae infra web`
- `[deploy-hosts]` maps host aliases to `ssh-target:/absolute/aelab/root` entries used by `./ae infra deploy`
- `[agent-ports]` maps agent ids to gateway ports
- `[service-ports]` maps service ids to Caddy-facing ports
- `[tty-buttons]` controls the floating mobile key dock on `/tty/` pages
Manifest overrides live in `host.toml`, not `repo.toml`.

`host.toml` is gitignored and can override agent kind sections from `agents.toml` and service sections from `services.toml`:

```toml
[services.core-tty]
AELAB_SERVICE_USER = "tadija"
```

Only `[agents.<kind>]` and `[services.<service>]` sections are read as manifest overrides from `host.toml`.

## host config

`host.toml` remains per-machine for now. Copy `host.example.toml`, uncomment the matching platform block, and edit it for the current host.

```toml
AELAB_HOST = "dev-server"
AELAB_ROOT = "/opt/aelab"
AELAB_USER = "agent"
AELAB_GROUP = "agent"
AELAB_AGENTS = "021 022 023 024"
AELAB_SERVICES = "core"
AELAB_PROJECTS = "aelab=/opt/aelab"
AELAB_TAILSCALE_ONLY = "false"
AELAB_CADDY_TLS = "off"
```

## HTTPS on Tailscale hostnames

Set `AELAB_CADDY_TLS=internal` and change the active `[hosts]` URL to HTTPS:

```toml
[hosts]
dev-server = "https://dev-server/"
```

Generated Caddy config serves the root aelab site at `https://dev-server/`, redirects `http://dev-server/` to HTTPS, and uses Caddy's internal CA with `tls internal`.

Client devices must trust Caddy's internal root CA before browsers accept short Tailscale hostnames such as `https://dev-server/`. If you prefer publicly trusted certificates without installing a local CA, use a full Tailscale `*.ts.net` name with Tailscale certificates or a real domain with DNS and public ACME.


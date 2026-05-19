# clawlab-infra

**host bootstrap and service supervision for clawlab**

> **works on**: macOS | Linux | WSL  
> **docs**: [home](../README.md) | [config](../config/README.md) | infra  

## overview

- `config/custom/host/.env` declares what one machine should run, copied from [`.env.example-macos`](../config/custom/host/.env.example-macos), [`.env.example-linux`](../config/custom/host/.env.example-linux), or [`.env.example-wsl`](../config/custom/host/.env.example-wsl)
- [`config/agents/`](../config/agents/) defines agent kind defaults, with overrides in [`config/custom/override/agents/`](../config/custom/override/agents/)
- [`config/custom/repo.ini`](../config/custom/repo.ini) defines parsed repo-wide config such as host aliases and gateway ports
- [`config/services/`](../config/services/) defines shared service defaults, with overrides in [`config/custom/override/services/`](../config/custom/override/services/)
- [`infra/templates/`](templates/) holds launchd/systemd templates
- `./cmd infra ...` is the public entrypoint
- `infra/commands/*.sh` are implementation scripts for rendering, installing, lifecycle, status, and logs
- `config/custom/override/infra/*.sh` adds private infra subcommands, or overrides same-name built-in commands
- infra is intentionally template-driven so custom agent/service kinds can be added without changing the core layout

## commands

```bash
./cmd infra bootstrap [agents|services|agent-id|service-id...]  # install packages/runtimes and service-manager artifacts
./cmd infra install [agents|services|agent-id|service-id...]    # install launchd plists or systemd units
./cmd infra uninstall [agents|services|agent-id|service-id...]  # stop/disable and remove launchd plists or systemd units
./cmd infra start [agents|services|agent-id|service-id...]      # start managed services and agents
./cmd infra stop [agents|services|agent-id|service-id...]       # stop managed services and agents
./cmd infra restart [agents|services|agent-id|service-id...]    # stop then start managed services and agents
./cmd infra doctor [agents|services|agent-id|service-id...]     # print host diagnostics and flag unhealthy requested items
./cmd infra log [agents|services|agent-id|service-id...]        # show stdout/stderr logs
./cmd infra status [agents|services|agent-id|service-id...]     # show service-manager status
./cmd infra render <all|brew|caddy|dash>                        # render generated infra files
./cmd infra update [agents|services|agent-id|service-id...] [--no-pull] [--no-restart] [--dry-run]  # pull latest and restart targets
```

Common host-default flow:

```bash
./cmd infra install
./cmd infra start
./cmd infra status
./cmd infra doctor
./cmd infra log
./cmd infra restart
./cmd infra stop
```

Explicit target examples:

```bash
./cmd infra install 000 004 007 tailscale caddy
./cmd infra install agents
./cmd infra install services
./cmd infra start agents
./cmd infra start services
./cmd infra start 000 004 007 tailscale caddy
./cmd infra status 000 caddy
./cmd infra doctor services
./cmd infra log --short 007
./cmd infra stop 007 tailscale
./cmd infra uninstall caddy
```

## privileges

Some infra commands invoke `sudo` because clawlab installs and controls system-level service-manager artifacts.

- `install` writes systemd units under `/etc/systemd/system` or launchd plists under `/Library/LaunchDaemons`, and may adjust ownership of `state/`
- `uninstall` removes those units/plists and stops/disables matching services
- `start`, `stop`, and `restart` call `systemctl` or system `launchctl`
- `bootstrap` may remove leftover units/plists that no longer match `config/custom/host/.env`
- `infra/utils/relocate-root.sh` is a one-time helper that should be run with `sudo`

Commands that only inspect or render local files, such as `status`, `doctor`, `log`, and `render`, should not require sudo.

## host root

The recommended checkout path is shared and stable across users: `/Users/Shared/clawlab` on macOS, `/srv/clawlab` on Linux, or a Windows-side path such as `C:\Users\Public\clawlab` for WSL.

Create the parent directory with `sudo`, hand ownership to your login user, then clone as that user. This avoids a root-owned checkout that later blocks normal `git`, `./cmd`, and editor workflows.

macOS:

```bash
sudo mkdir -p /Users/Shared/clawlab
sudo chown "$USER":staff /Users/Shared/clawlab
git clone git@github.com:tadija/clawlab.git /Users/Shared/clawlab
```

Linux:

```bash
sudo mkdir -p /srv/clawlab
sudo chown "$USER":"$USER" /srv/clawlab
git clone git@github.com:tadija/clawlab.git /srv/clawlab
```

WSL:

For WSL, prefer cloning on the Windows side so the checkout is easy to open from both Windows tools and Linux shells. From Windows PowerShell:

```powershell
git clone git@github.com:tadija/clawlab.git C:\Users\Public\clawlab
```

Then use it from WSL through the mounted Windows path:

```bash
cd /mnt/c/Users/Public/clawlab
```

If you already cloned with `sudo`, fix ownership before continuing:

```bash
sudo chown -R "$USER":"$(id -gn)" /srv/clawlab
sudo chown -R "$USER":staff /Users/Shared/clawlab
```

For a one-time relocation into that path:

```bash
sudo bash infra/utils/relocate-root.sh
```

## host config

`config/custom/host/.env` is the per-machine assignment file. Copy the matching platform example and edit it for the current host:

```bash
cp config/custom/host/.env.example-macos config/custom/host/.env
# or
cp config/custom/host/.env.example-linux config/custom/host/.env
# or
cp config/custom/host/.env.example-wsl config/custom/host/.env
```

```bash
CLAWLAB_AGENTS="000 004 007"
CLAWLAB_SERVICES="tailscale caddy"
CLAWLAB_HOST=app-server
CLAWLAB_USER=agent
CLAWLAB_GROUP=staff
CLAWLAB_ROOT=/Users/Shared/clawlab
CLAWLAB_PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
CLAWLAB_PROJECTS="clawlab=/Users/Shared/clawlab app=/Users/Shared/clawlab/shared/projects/app"
```

Host fields:

- `CLAWLAB_AGENTS` lists the agent ids assigned to this host
- `CLAWLAB_SERVICES` lists the shared services assigned to this host
- `CLAWLAB_PROJECTS` lists dashboard project rows as `title=/absolute/path` pairs; `/tty/<title>/` opens a shell in that path, and the project action menu opens supported interactive agent TUIs in that same path
- `CLAWLAB_HOST` selects the active segmented-nav host for the generated Caddy landing page
- `CLAWLAB_USER` is the account that should own and run the managed processes
- `CLAWLAB_GROUP` is the shared group used for the repo, such as `staff` on macOS or the service user's primary group on Linux
- `CLAWLAB_ROOT` is the git checkout root directory path
- `CLAWLAB_PATH` is injected into managed service and agent processes

Special targets expand from this file:

- `agents` expands to `CLAWLAB_AGENTS`
- `services` expands to `CLAWLAB_SERVICES`

Examples:

```bash
./cmd infra start agents
./cmd infra start services
```

With no explicit args, infra lifecycle commands use both host-assigned services and agents. Services are resolved first so shared dependencies can come up before agents.

## bootstrap, install, and uninstall

These commands prepare the host and manage service-manager artifacts. With no explicit args, they use both host-assigned services and agents from `config/custom/host/.env`.

```bash
./cmd infra bootstrap
./cmd infra install
./cmd infra uninstall
./cmd infra install agents
./cmd infra install services
./cmd infra uninstall caddy
```

`bootstrap` installs packages and runtime prerequisites, runs installer hooks, prepares the base local state layout, removes service-manager leftover artifacts that are no longer part of the current host assignment, and installs service-manager artifacts for the requested host items.

`install` writes launchd plists or systemd units for the requested host items.

`uninstall` stops, disables, and removes installed launchd plists or systemd units for the requested host items.

`bootstrap.sh` does the following:

- renders `infra/generated/Brewfile`
- runs `brew bundle`
- runs any enabled agent-kind installer hooks declared in `config/agents/*.env` or `config/custom/override/agents/*.env`
- runs any enabled service installer hooks declared in `config/services/*.env` or `config/custom/override/services/*.env`
- creates the base `state/` layout
- removes leftover service-manager artifacts no longer assigned in `config/custom/host/.env`
- runs `install.sh` for the requested host items

Services with `CLAWLAB_SERVICE_INSTALL_OPTIONAL="true"` are best-effort during bootstrap/install: installer failures are reported as warnings and their Homebrew dependencies are left out of the generated Brewfile.

`install.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- installs launchd plists or systemd units for those items
- ensures service runtime/log directories exist
- renders the Caddy config when `caddy` is being installed

`uninstall.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- stops and disables matching launchd plists or systemd units
- removes installed plist/unit files for requested agents and services
- removes Caddy-managed helper service artifacts when `caddy` is being uninstalled
- reloads systemd when unit files were removed on Linux
- reports when no installed unit files or plists were found

## start, stop, and restart

These commands control installed launchd/systemd items. Services are resolved before agents when no explicit args are provided, so shared dependencies can come up before assigned agents.

```bash
./cmd infra start
./cmd infra stop
./cmd infra restart
./cmd infra start agents
./cmd infra start services
./cmd infra start 000 004 007 tailscale caddy
./cmd infra stop 007 tailscale
```

`start.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- repairs group ownership and group-writable modes under requested agent directories and service state paths
- refreshes agent service-manager artifacts before starting agents
- starts agents through `agent@<id>` systemd units on Linux or rendered launchd plists on macOS
- starts managed agents with a group-writable umask so regenerated files remain readable by repo users in `CLAWLAB_GROUP`
- starts services through their rendered service-manager artifacts
- refreshes generated dash/Caddy outputs when starting `dash-http` or `caddy`
- starts Caddy-managed helper services before `caddy`
- does not run installer hooks; use `bootstrap` or `install` for installer/setup work

Set `CLAWLAB_LOG_VERBOSE=1` to print extra diagnostics from repair steps during commands such as `./cmd infra start`.

`stop.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- stops and disables matching launchd plists or systemd units
- stops Caddy-managed helper services when `caddy` is being stopped

`restart.sh` does the following:

- runs `stop.sh` with the same args
- runs `start.sh` with the same args

## doctor, log, and status

These commands inspect host items and their logs. They do not install, remove, start, or stop service-manager artifacts.

```bash
./cmd infra status
./cmd infra doctor
./cmd infra log
./cmd infra status 000 caddy
./cmd infra doctor services
./cmd infra log --short 007
./cmd infra log --lines 100 caddy
```

`status.sh` prints each requested item with service-manager state, backend name, and pid.

`doctor.sh` repairs group ownership and group-writable modes under requested agent directories and service state paths, then prints host basics, discovered binaries, enabled agent install methods, requested item states, and recent logs for unhealthy items. It exits non-zero when requested items are not active/running/waiting.

`log.sh` prints stdout/stderr logs from `state/logs/`, with `--short` for 4 lines or `--lines N` for a custom tail size.

## render

`render.sh` writes host-local derived files without installing service-manager artifacts.

```bash
./cmd infra render <all|brew|caddy|dash>
```

- `infra/generated/Brewfile` is generated from `config/custom/host/.env`, `config/agents/*.env`, `config/custom/override/agents/*.env`, `config/services/*.env`, and `config/custom/override/services/*.env`
- `infra/generated/Caddyfile` is generated from `config/custom/repo.ini[agent-ports]`, `CLAWLAB_AGENTS`, and Caddy-enabled services
- `infra/generated/caddy/index.html` is generated from `infra/templates/dash-page.html`, `CLAWLAB_AGENTS`, `CLAWLAB_SERVICES`, and optional `CLAWLAB_PROJECTS`
- `infra/commands/render.sh brew` runs automatically during `bootstrap.sh` before `brew bundle`
- `infra/commands/render.sh caddy` also refreshes the generated dash page from `infra/templates/dash-page.html`
- `caddy` can manage root helper services declared in [`config/services/caddy.env`](../config/services/caddy.env) via `CLAWLAB_SERVICE_CADDY_ROOT_SERVICE_IDS`; the first entry is used for the root upstream, and the full list is treated as managed by caddy

`infra/generated/` is host-local and gitignored, so generated artifacts like the Brewfile, Caddyfile, dash binary, and generated landing page are not tracked.

## config model

- [`config/services/*.env`](../config/services/) define shared-service runtime defaults, with same-name overrides in [`config/custom/override/services/`](../config/custom/override/services/)
- [`config/agents/*.env`](../config/agents/) define agent-kind metadata and command templates, with same-name overrides in [`config/custom/override/agents/`](../config/custom/override/agents/)
- [`config/custom/repo.ini`](../config/custom/repo.ini) defines parsed repo-wide sections such as host alias URLs and gateway ports
- [`config/custom/override/infra/*.sh`](../config/custom/override/infra/) adds host-specific infra subcommands, or overrides same-name built-in commands
- service manifests can use `__CLAWLAB_SERVICE_DIR__` as the per-service runtime base directory, which defaults to `__CLAWLAB_ROOT__/state/runtimes/__SERVICE_ID__`
- service manifests can use `CLAWLAB_SERVICE_ENV` for launchd/systemd environment variables, using `|` between assignments
- agent manifests can also set dedicated home or extra env vars when a tool supports them
- agents can use optional env files under `config/custom/env/`; `config/custom/env/agents.env` is shared by all agents, and `config/custom/env/agents/<agent-id>.env` such as `config/custom/env/agents/007.env` can override or extend it. `cmd <agent-id> ...` loads shared values first and per-agent values second before running the native command. Linux also reads both files through systemd `EnvironmentFile`, and macOS renders the effective values into the launchd plist during `install`/`start`
- services can use optional env files under `config/custom/env/`; `config/custom/env/services.env` is shared by all services, and `config/custom/env/services/<service-id>.env` such as `config/custom/env/services/postgres.env` can override or extend it. Managed services load manifest `CLAWLAB_SERVICE_ENV` first, then shared values, then per-service values
- [`infra/templates/`](templates/) define the rendered launchd/systemd unit shapes

## state

- `state/logs/agent/` stores agent stdout/stderr logs as `<id>.log` and `<id>.err`
- `state/logs/` stores shared-service stdout/stderr logs as `<service>.log` and `<service>.err`
- `state/runtimes/<service>/` is the default home for shared-service runtime state
- agent-kind installers may also use `state/runtimes/<kind>` for shared runtimes such as Hermes or Mercury
- services can override runtime locations when needed, but defaults keep state inside `CLAWLAB_ROOT`

## layout

```
infra/
  generated/
    Brewfile
    Caddyfile
    caddy/
  commands/
    bootstrap.sh
    core.sh
    doctor.sh
    install.sh
    log.sh
    render.sh
    restart.sh
    start.sh
    status.sh
    stop.sh
    uninstall.sh
  installers/
    dash-tty.sh
    hermes.sh
    mercury.sh
    nanobot.sh
  templates/
    agent.launchd.plist
    agent.systemd
    dash-page.html
    service.launchd.plist
    service.systemd
  utils/
    dash-http-server.swift
    dash-tty-server.swift
    mongodb-server.sh
    mysql-server.sh
    postgres-server.sh
    relocate-root.sh
config/
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
    override/
      agents/
        .gitkeep
      infra/
      services/
state/
  logs/
    agent/
      <id>.log
      <id>.err
    <service>.log
    <service>.err
  runtimes/
    <agent-kind>/
    <service>/
```

## platform behavior

- on Linux, configured shared services are installed as rendered systemd units
- on macOS, configured shared services are installed as rendered launchd plists
- enabled agents are installed one per id, while the CLI still uses plain `NNN` ids and resolves them internally
- `cmd <agent-id> start` remains the single source of truth for how an agent is launched; infra just delegates into the main CLI

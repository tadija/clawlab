# aelab-infra

**host bootstrap and service supervision for aelab**

> **works on**: macOS | Linux | WSL  
> **docs**: [home](../README.md) | [config](../config/README.md) | infra  

## overview

`infra/` is the operating layer that turns `aelab` config into a running system on a real machine.

This is what makes a multi-agent setup not just configurable, but operable: bootstrapped consistently, supervised by the host, and managed through one lifecycle model.

## how it works

- `config/custom/host/.env` says which agents and services belong on a host
- manifests in [`config/agents/`](../config/agents/) and [`config/services/`](../config/services/) describe how they run
- [`config/custom/repo.ini`](../config/custom/repo.ini) supplies ports, host aliases, and shared derived values
- templates in [`infra/templates/`](templates/) render launchd/systemd artifacts and generated web-facing files
- `./ae infra ...` installs, starts, stops, inspects, and repairs the result

## implementation map

- `config/custom/host/.env` declares what one machine should run, copied from [`.env.example-macos`](../config/custom/host/.env.example-macos), [`.env.example-linux`](../config/custom/host/.env.example-linux), or [`.env.example-wsl`](../config/custom/host/.env.example-wsl)
- [`config/agents/`](../config/agents/) defines agent kind defaults, with overrides in [`config/custom/override/agents/`](../config/custom/override/agents/)
- [`config/custom/repo.ini`](../config/custom/repo.ini) defines parsed repo-wide config such as host aliases and gateway ports
- [`config/services/`](../config/services/) defines shared service defaults, with overrides in [`config/custom/override/services/`](../config/custom/override/services/)
- [`infra/templates/`](templates/) holds launchd/systemd templates
- [`infra/core/`](core/) holds the built-in HTTP and tty server sources/templates
- `./ae infra ...` is the public entrypoint
- `infra/commands/*.sh` are implementation scripts for rendering, installing, lifecycle, status, and logs
- `config/custom/override/infra/*.sh` adds private infra subcommands, or overrides same-name built-in commands
- infra is intentionally template-driven so custom agent/service kinds can be added without changing the core layout

## command groups

### Lifecycle and setup

```bash
./ae infra bootstrap [agents|services|agent-id|service-id...]  # install packages/runtimes and service-manager artifacts
./ae infra install [agents|services|agent-id|service-id...]    # install launchd plists or systemd units
./ae infra uninstall [agents|services|agent-id|service-id...]  # stop/disable and remove launchd plists or systemd units
./ae infra start [agents|services|agent-id|service-id...]      # start managed services and agents
./ae infra stop [agents|services|agent-id|service-id...]       # stop managed services and agents
./ae infra restart [agents|services|agent-id|service-id...]    # stop then start managed services and agents
./ae infra update [agents|services|agent-id|service-id...] [--no-pull] [--no-restart] [--dry-run]  # pull latest and restart targets; defaults to core
```

### Inspection and rendering

```bash
./ae infra doctor [agents|services|agent-id|service-id...]     # print host diagnostics and flag unhealthy requested items
./ae infra log [agents|services|agent-id|service-id...]        # show stdout/stderr logs
./ae infra status [agents|services|agent-id|service-id...]     # show service-manager status
./ae infra render <all|brew|caddy|front>                       # render generated infra files
```

## common flows

### Default host flow

```bash
./ae infra install
./ae infra start
./ae infra status
./ae infra doctor
./ae infra log
./ae infra restart
./ae infra stop
```

### Explicit target examples

```bash
./ae infra install 000 004 007 core
./ae infra install agents
./ae infra install services
./ae infra start agents
./ae infra start services
./ae infra start 000 004 007 core
./ae infra status 000 core
./ae infra doctor services
./ae infra log --short 007
./ae infra stop 007 some-service
./ae infra uninstall core
```

## privileges

Some infra commands invoke `sudo` because `aelab` installs and controls system-level service-manager artifacts.

- `install` writes systemd units under `/etc/systemd/system` or launchd plists under `/Library/LaunchDaemons`, and may adjust ownership of `state/`
- `uninstall` removes those units/plists and stops/disables matching services
- `start`, `stop`, and `restart` call `systemctl` or system `launchctl`
- `bootstrap` may remove leftover units/plists that no longer match `config/custom/host/.env`

Commands that only inspect or render local files, such as `status`, `doctor`, `log`, and `render`, should not require sudo.

### sudoers allowlist

`install` drops a tight allowlist at `/etc/sudoers.d/aelab` on its first run (one sudo prompt). It restricts `NOPASSWD` to the exact `launchctl` / `systemctl` / `install` / `chmod` / `chown` invocations the lifecycle commands need against the aelab root and `/Library/LaunchDaemons` (or `/etc/systemd/system`). After that, subsequent `start`, `stop`, `restart`, `install`, and `uninstall` runs proceed without password prompts. The rule grants the host's admin group (`%admin` on macOS, `%wheel` or `%sudo` on Linux), not a specific user, so renaming the account is fine.

Manage it explicitly:

```bash
./ae infra install sudoers     # render + drop the file (no other side effects)
./ae infra uninstall sudoers   # remove just the file
```

A bare `./ae infra uninstall` (no args) removes the sudoers file at the end, in addition to the host-assigned services and agents. Targeted uninstalls (e.g. `./ae infra uninstall core`) leave it alone.

## checkout location

The recommended checkout path is shared and stable across users: `/Users/Shared/aelab` on macOS, `/srv/aelab` on Linux, or a Windows-side path such as `C:\Users\Public\aelab` for WSL.

Create the parent directory with `sudo`, hand ownership to your login user, then clone as that user. This avoids a root-owned checkout that later blocks normal `git`, `./ae`, and editor workflows.

macOS:

```bash
sudo mkdir -p /Users/Shared/aelab
sudo chown "$USER":staff /Users/Shared/aelab
git clone git@github.com:tadija/aelab.git /Users/Shared/aelab
```

Linux:

```bash
sudo mkdir -p /srv/aelab
sudo chown "$USER":"$USER" /srv/aelab
git clone git@github.com:tadija/aelab.git /srv/aelab
```

WSL:

For WSL, prefer cloning on the Windows side so the checkout is easy to open from both Windows tools and Linux shells. From Windows PowerShell:

```powershell
git clone git@github.com:tadija/aelab.git C:\Users\Public\aelab
```

Then use it from WSL through the mounted Windows path:

```bash
cd /mnt/c/Users/Public/aelab
```

If you already cloned with `sudo`, fix ownership before continuing:

```bash
sudo chown -R "$USER":"$(id -gn)" /srv/aelab
sudo chown -R "$USER":staff /Users/Shared/aelab
```

## host config

`config/custom/host/.env` is the per-machine assignment file.

### Copy the matching platform example

```bash
cp config/custom/host/.env.example-macos config/custom/host/.env
# or
cp config/custom/host/.env.example-linux config/custom/host/.env
# or
cp config/custom/host/.env.example-wsl config/custom/host/.env
```

```bash
AELAB_AGENTS="021 022 023 024 025"
AELAB_SERVICES="core"
AELAB_HOST=app-server
AELAB_USER=agent
AELAB_GROUP=staff
AELAB_ROOT=/Users/Shared/aelab
AELAB_PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
AELAB_PROJECTS="aelab=/Users/Shared/aelab app=/Users/Shared/aelab/shared/projects/app"
```

### Host fields

- `AELAB_AGENTS` lists the agent ids assigned to this host
- `AELAB_SERVICES` lists the shared services assigned to this host
- `AELAB_PROJECTS` lists project rows as `title=/absolute/path` pairs; `/tty/<title>/` opens a shell in that path, and the project action menu opens supported interactive agent TUIs in that same path
- `AELAB_HOST` selects the active segmented-nav host for the generated Caddy landing page
- `AELAB_USER` is the account that should own and run the managed processes
- `AELAB_GROUP` is the shared group used for the repo, such as `staff` on macOS or the service user's primary group on Linux
- `AELAB_ROOT` is the git checkout root directory path
- `AELAB_PATH` is injected into managed service and agent processes

### Special targets

- `agents` expands to `AELAB_AGENTS`
- `services` expands to `AELAB_SERVICES`

### Examples

```bash
./ae infra start agents
./ae infra start services
```

With no explicit args, infra lifecycle commands use both host-assigned services and agents. Services are resolved first so shared dependencies can come up before agents.

## bootstrap, install, and uninstall

These commands prepare the host and manage service-manager artifacts. With no explicit args, they use both host-assigned services and agents from `config/custom/host/.env`.

### Common commands

```bash
./ae infra bootstrap
./ae infra install
./ae infra uninstall
./ae infra install agents
./ae infra install services
./ae infra uninstall core
```

`bootstrap` installs packages and runtime prerequisites, runs installer hooks, prepares the base local state layout, removes service-manager leftover artifacts that are no longer part of the current host assignment, and installs service-manager artifacts for the requested host items.

`install` writes launchd plists or systemd units for the requested host items and, on its first run, drops `/etc/sudoers.d/aelab` so subsequent lifecycle commands don't prompt for a password (see "sudoers allowlist" above).

`uninstall` stops, disables, and removes installed launchd plists or systemd units for the requested host items. With no args it also removes `/etc/sudoers.d/aelab`.

### What `bootstrap.sh` does

- renders `infra/generated/Brewfile`
- runs `brew bundle`
- runs any enabled agent-kind installer hooks declared in `config/agents/*.env` or `config/custom/override/agents/*.env`
- runs any enabled service installer hooks declared in `config/services/*.env` or `config/custom/override/services/*.env`
- creates the base `state/` layout
- removes leftover service-manager artifacts no longer assigned in `config/custom/host/.env`
- runs `install.sh` for the requested host items

Services with `AELAB_SERVICE_INSTALL_OPTIONAL="true"` are best-effort during bootstrap/install: installer failures are reported as warnings and their Homebrew dependencies are left out of the generated Brewfile.

### What `install.sh` does

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- installs launchd plists or systemd units for those items
- ensures service runtime/log directories exist
- renders the Caddy config when `caddy` is being installed

### What `uninstall.sh` does

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- stops and disables matching launchd plists or systemd units
- removes installed plist/unit files for requested agents and services
- reloads systemd when unit files were removed on Linux
- reports when no installed unit files or plists were found

## start, stop, and restart

These commands control installed launchd/systemd items. Services are resolved before agents when no explicit args are provided, so shared dependencies can come up before assigned agents.

### Common commands

```bash
./ae infra start
./ae infra stop
./ae infra restart
./ae infra start agents
./ae infra start services
./ae infra start 000 004 007 core
./ae infra stop 007 some-service
```

`start.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- repairs group ownership and group-writable modes under requested agent directories and service state paths
- refreshes agent service-manager artifacts before starting agents
- starts agents through `agent@<id>` systemd units on Linux or rendered launchd plists on macOS
- starts managed agents with a group-writable umask so regenerated files remain readable by repo users in `AELAB_GROUP`
- starts services through their rendered service-manager artifacts
- refreshes generated index/Caddy outputs when starting `core-http` or `caddy`
- does not run installer hooks; use `bootstrap` or `install` for installer/setup work

Set `AELAB_LOG_VERBOSE=1` to print extra diagnostics from repair steps during commands such as `./ae infra start`.

`stop.sh` does the following:

- resolves requested agent ids and services from explicit args or `config/custom/host/.env`
- stops and disables matching launchd plists or systemd units

`restart.sh` does the following:

- runs `stop.sh` with the same args
- runs `start.sh` with the same args

## doctor, log, and status

These commands inspect host items and their logs. They do not install, remove, start, or stop service-manager artifacts.

```bash
./ae infra status
./ae infra doctor
./ae infra log
./ae infra status 000 core
./ae infra doctor services
./ae infra doctor 001 002 --repair
./ae infra doctor agents --repair-full
./ae infra doctor repo --repair-full
./ae infra doctor --no-repair services
./ae infra log --short 007
./ae infra log --lines 100 core
```

`status.sh` prints each requested item with service-manager state, backend name, and pid.

`doctor.sh` prints host basics, discovered binaries, enabled agent install methods, requested item states, and recent logs for unhealthy items. By default it only inspects. Add `--repair` for shallow repair of known generated agent paths that can become unreadable to repo users, or `--repair-full` for recursive agent/service state repair. Use `repo --repair-full` to normalize collaborative aelab source/config/doc paths while skipping `.git`, `shared/`, and agent runtime state. It exits non-zero when requested items are not active/running/waiting.

`log.sh` prints stdout/stderr logs from `state/logs/`, with `--short` for 4 lines or `--lines N` for a custom tail size.

## render

`render.sh` writes host-local derived files without installing service-manager artifacts.

```bash
./ae infra render <all|brew|caddy|front>
```

- `infra/generated/Brewfile` is generated from `config/custom/host/.env`, `config/agents/*.env`, `config/custom/override/agents/*.env`, `config/services/*.env`, and `config/custom/override/services/*.env`
- `infra/generated/Caddyfile` is generated from `config/custom/repo.ini[agent-ports]`, `AELAB_AGENTS`, and Caddy-enabled services
- `infra/generated/index.html` is generated from `infra/core/index.html`, `AELAB_AGENTS`, `AELAB_SERVICES`, and optional `AELAB_PROJECTS`
- `infra/commands/render.sh brew` runs automatically during `bootstrap.sh` before `brew bundle`
- `infra/commands/render.sh front` also refreshes the generated index page from `infra/core/index.html`
- [`config/services/core.env`](../config/services/core.env) expands to the core service tree (`core-http`, `core-tty`, and `caddy`)

`infra/generated/` is host-local and gitignored, so generated artifacts like the Brewfile, Caddyfile, core binaries, and generated landing page are not tracked.

## config model

- [`config/services/*.env`](../config/services/) define shared-service runtime defaults, with same-name overrides in [`config/custom/override/services/`](../config/custom/override/services/)
- [`config/agents/*.env`](../config/agents/) define agent-kind metadata and command templates, with same-name overrides in [`config/custom/override/agents/`](../config/custom/override/agents/)
- [`config/custom/repo.ini`](../config/custom/repo.ini) defines parsed repo-wide sections such as host alias URLs and gateway ports
- [`config/custom/override/infra/*.sh`](../config/custom/override/infra/) adds host-specific infra subcommands, or overrides same-name built-in commands
- service manifests can use `__AELAB_SERVICE_DIR__` as the per-service runtime base directory, which defaults to `__AELAB_ROOT__/state/runtimes/__SERVICE_ID__`
- service manifests can use `AELAB_SERVICE_ENV` for launchd/systemd environment variables, using `|` between assignments
- agent manifests can also set dedicated home or extra env vars when a tool supports them
- agents can use optional env files under `config/custom/env/`; `config/custom/env/agents.env` is shared by all agents, and `config/custom/env/agents/<agent-id>.env` such as `config/custom/env/agents/007.env` can override or extend it. `ae <agent-id> ...` loads shared values first and per-agent values second before running the native command. Linux also reads both files through systemd `EnvironmentFile`, and macOS renders the effective values into the launchd plist during `install`/`start`
- services can use optional env files under `config/custom/env/`; `config/custom/env/services.env` is shared by all services, and `config/custom/env/services/<service-id>.env` such as `config/custom/env/services/postgres.env` can override or extend it. Managed services load manifest `AELAB_SERVICE_ENV` first, then shared values, then per-service values
- [`infra/templates/`](templates/) define the rendered launchd/systemd unit shapes

## state

- `state/logs/agent/` stores agent stdout/stderr logs as `<id>.log` and `<id>.err`
- `state/logs/` stores shared-service stdout/stderr logs as `<service>.log` and `<service>.err`
- `state/runtimes/<service>/` is the default home for shared-service runtime state
- agent-kind installers may also use `state/runtimes/<kind>` for shared runtimes such as Hermes or Mercury
- services can override runtime locations when needed, but defaults keep state inside `AELAB_ROOT`

## layout

```
infra/
  generated/
    Brewfile
    Caddyfile
    index.html
    bin/
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
  core/
    http-server.swift
    index.html
    tty-server.swift
    tty.html
  templates/
    agent.launchd.plist
    agent.systemd
    service.launchd.plist
    service.systemd
  utils/
    installers/
      core-http.sh
      core-tty.sh
      hermes.sh
      mercury.sh
      nanobot.sh
    launchers/
      mongodb-server.sh
      mysql-server.sh
      postgres-server.sh
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
- `ae <agent-id> start` remains the single source of truth for how an agent is launched; infra just delegates into the main CLI

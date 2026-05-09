#!/usr/bin/env swift

import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

func usage() {
    print("""
Usage:
  cmd list
  cmd make <agent-id-agent-kind|existing-agent-id> [args...]
  cmd remove <agent-id> [agent-id...] [-y|--yes]
  cmd <agent-id> <command...>
  cmd infra <bootstrap|install|uninstall|start|stop|restart|status|doctor|log|render> [args...]

Global commands:
  list    -> list existing agents
  make    -> create agent working dir if needed and run native setup once
  remove  -> remove agent working dir(s) (-y to confirm)
  infra   -> run clawlab infra scripts

Agent commands:
  bootstrap -> install runtime/dependencies for this agent kind
  edit    -> open agent working dir in $EDITOR
  start   -> start gateway / daemon (depending on agent)
  stop    -> stop gateway / daemon (depending on agent)

Examples:
  ./cmd list

  ./cmd make 001-openclaw && ./cmd 001 bootstrap && ./cmd 001 onboard --skip-daemon && ./cmd 001 start

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
  ./cmd 011 start

  ./cmd infra render <brew|caddy>
  ./cmd infra bootstrap <agents|services>
  ./cmd infra install <agents|services>
  ./cmd infra start <agents|services>
  ./cmd infra start 003 005 007
  ./cmd infra status 000 && ./cmd infra log 000
""")
}


enum GlobalCommand: String {
    case make
    case remove
    case list
    case infra
}

enum AgentCommand: String {
    case bootstrap
    case edit
    case start
    case stop
}

struct AgentKindSpec {
    let kind: String
    let homeEnvName: String?
    let envAssignments: [(String, String)]
    let brewTaps: [String]
    let brewPackages: [String]
    let brewCasks: [String]
    let installKind: String?
    let installScript: String?
    let initArgs: [String]
    let hasInitCommand: Bool
    let startArgs: [String]
    let startPortFlag: String?
    let stopArgs: [String]
    let forwardPrefix: [String]
}

let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let agentsURL = rootURL.appendingPathComponent("agents", isDirectory: true)
let configRootURL = rootURL.appendingPathComponent("config", isDirectory: true)
let customConfigURL = configRootURL.appendingPathComponent("custom", isDirectory: true)
let repoConfigURL = customConfigURL.appendingPathComponent("repo.ini")
let agentKindsURL = configRootURL.appendingPathComponent("agents", isDirectory: true)
let customAgentKindsURL = customConfigURL.appendingPathComponent("override", isDirectory: true).appendingPathComponent("agents", isDirectory: true)
let customEnvURL = customConfigURL.appendingPathComponent("env", isDirectory: true)

var agentEntries: [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: agentsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
}

func stripQuotes(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2 {
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
    }
    return trimmed
}

func parseEnvFile(at url: URL) -> [String: String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let equalsIndex = line.firstIndex(of: "=") else { continue }

        let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: equalsIndex)...])
        values[key] = stripQuotes(value)
    }

    return values
}

func parseSectionedConfigFile(at url: URL) -> [String: [String: String]] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var sections: [String: [String: String]] = [:]
    var currentSection: String?

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }

        if line.hasPrefix("[") && line.hasSuffix("]") && line.count >= 3 {
            let sectionName = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            currentSection = sectionName.isEmpty ? nil : sectionName
            if let currentSection {
                sections[currentSection, default: [:]] = sections[currentSection, default: [:]]
            }
            continue
        }

        guard let currentSection, let equalsIndex = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { continue }
        sections[currentSection, default: [:]][key] = value
    }

    return sections
}

func splitTemplateArgs(_ value: String?) -> [String] {
    guard let value, !value.isEmpty else { return [] }
    return value
        .split(separator: "|", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.isEmpty }
}

func parseListValue(_ value: String?) -> [String] {
    guard let value, !value.isEmpty else { return [] }
    return value
        .replacingOccurrences(of: ",", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        .map(String.init)
        .filter { !$0.isEmpty }
}

func parseEnvAssignments(_ value: String?) -> [(String, String)] {
    splitTemplateArgs(value).compactMap { item in
        guard let equalsIndex = item.firstIndex(of: "=") else {
            fatalConfig("invalid env assignment: \(item)")
        }
        let key = String(item[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let val = String(item[item.index(after: equalsIndex)...])
        guard !key.isEmpty else {
            fatalConfig("invalid env assignment: \(item)")
        }
        return (key, val)
    }
}

func fatalConfig(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

func loadAgentKindSpecs() -> [AgentKindSpec] {
    func envFileURLs(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.filter { $0.pathExtension == "env" }
    }

    let fileNames = Set(envFileURLs(in: agentKindsURL).map(\.lastPathComponent))
        .union(Set(envFileURLs(in: customAgentKindsURL).map(\.lastPathComponent)))
        .sorted()

    if fileNames.isEmpty {
        return []
    }

    return fileNames.map { fileName in
        let baseURL = agentKindsURL.appendingPathComponent(fileName)
        let customURL = customAgentKindsURL.appendingPathComponent(fileName)
        let values = parseEnvFile(at: baseURL).merging(parseEnvFile(at: customURL)) { _, custom in custom }

        func require(_ key: String) -> String {
            guard let value = values[key], !value.isEmpty else {
                fatalConfig("agent kind config \(fileName) is missing \(key)")
            }
            return value
        }

        return AgentKindSpec(
            kind: require("CLAWLAB_AGENT_KIND"),
            homeEnvName: values["CLAWLAB_AGENT_HOME_ENV"].flatMap { $0.isEmpty ? nil : $0 },
            envAssignments: parseEnvAssignments(values["CLAWLAB_AGENT_ENV"]),
            brewTaps: parseListValue(values["CLAWLAB_AGENT_BREW_TAPS"]),
            brewPackages: parseListValue(values["CLAWLAB_AGENT_BREW_PACKAGES"]),
            brewCasks: parseListValue(values["CLAWLAB_AGENT_BREW_CASKS"]),
            installKind: values["CLAWLAB_AGENT_INSTALL_KIND"].flatMap { $0.isEmpty ? nil : $0 },
            installScript: values["CLAWLAB_AGENT_INSTALL_SCRIPT"].flatMap { $0.isEmpty ? nil : $0 },
            initArgs: splitTemplateArgs(values["CLAWLAB_AGENT_SETUP_ARGS"]),
            hasInitCommand: values["CLAWLAB_AGENT_SETUP_ARGS"] != nil,
            startArgs: splitTemplateArgs(require("CLAWLAB_AGENT_START_ARGS")),
            startPortFlag: values["CLAWLAB_AGENT_START_PORT_FLAG"].flatMap { $0.isEmpty ? nil : $0 },
            stopArgs: splitTemplateArgs(values["CLAWLAB_AGENT_STOP_ARGS"]),
            forwardPrefix: splitTemplateArgs(require("CLAWLAB_AGENT_FORWARD_PREFIX"))
        )
    }
}

let agentKindSpecs = loadAgentKindSpecs()
let agentKindsByName = Dictionary(uniqueKeysWithValues: agentKindSpecs.map { ($0.kind, $0) })

func listAgents() -> Never {
    let agents = existingAgentNames().sorted()
    if agents.isEmpty {
        print("no agents found")
    } else {
        for name in agents {
            print(name)
        }
    }
    exit(0)
}

enum ParsedCommand {
    case globalMake(agentArg: String, extra: [String])
    case globalRemove(args: [String])
    case globalList
    case globalInfra(subcommand: String, extra: [String])
    case agent(agentArg: String, command: String, extra: [String])
}

func parseArgs(_ args: [String]) -> ParsedCommand {
    guard args.count >= 2 else {
        usage()
        exit(1)
    }

    switch args[1] {
    case GlobalCommand.list.rawValue:
        if args.count != 2 {
            fputs("usage: cmd list\n", stderr)
            exit(1)
        }
        return .globalList
    case GlobalCommand.make.rawValue:
        if args.count < 3 {
            fputs("usage: cmd make <agent-id-agent-kind|existing-agent-id> [args...]\n", stderr)
            exit(1)
        }
        return .globalMake(agentArg: args[2], extra: Array(args.dropFirst(3)))
    case GlobalCommand.remove.rawValue:
        if args.count < 3 {
            fputs("usage: cmd remove <agent-id> [agent-id...] [-y|--yes]\n", stderr)
            exit(1)
        }
        return .globalRemove(args: Array(args.dropFirst(2)))
    case "init", "setup", "render":
        fputs("unknown global command: \(args[1])\n", stderr)
        exit(1)
    case GlobalCommand.infra.rawValue:
        if args.count < 3 {
            fputs("usage: cmd infra <bootstrap|install|uninstall|start|stop|restart|status|doctor|log|render> [args...]\n", stderr)
            exit(1)
        }
        return .globalInfra(subcommand: args[2], extra: Array(args.dropFirst(3)))
    default:
        if args.count < 3 {
            usage()
            exit(1)
        }
        if args[2] == GlobalCommand.make.rawValue || args[2] == GlobalCommand.remove.rawValue || args[2] == GlobalCommand.list.rawValue {
            fputs("usage: cmd <agent-id> <command...>\n", stderr)
            exit(1)
        }
        return .agent(agentArg: args[1], command: args[2], extra: Array(args.dropFirst(3)))
    }
}

let parsed = parseArgs(CommandLine.arguments)

func candidateBinaryDirectories() -> [String] {
    var dirs: [String] = []
    var seen = Set<String>()

    func add(_ dir: String) {
        guard !dir.isEmpty, !seen.contains(dir) else { return }
        seen.insert(dir)
        dirs.append(dir)
    }

    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for dir in path.split(separator: ":").map(String.init) {
            add(dir)
        }
    }

    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        add(URL(fileURLWithPath: home).appendingPathComponent(".local/bin").path)
        add(URL(fileURLWithPath: home).appendingPathComponent(".cargo/bin").path)
    }

    for dir in [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        add(dir)
    }

    return dirs
}

func executablePath(_ command: String) -> String? {
    if command.contains("/") {
        if FileManager.default.isExecutableFile(atPath: command) {
            return command
        }
        return nil
    }

    for dir in candidateBinaryDirectories() {
        let candidate = URL(fileURLWithPath: dir).appendingPathComponent(command).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

func resolveExecutable(_ command: String) -> String {
    if let path = executablePath(command) {
        return path
    }

    if command.contains("/") {
        fputs("executable not found: \(command)\n", stderr)
        exit(1)
    }

    fputs("executable not found in PATH: \(command)\n", stderr)
    fputs("run ./cmd <agent-id> bootstrap to install manually\n", stderr)
    fputs("or set up config/custom/host/.env file and run ./cmd infra bootstrap\n", stderr)
    exit(1)
}

func agentNameParts(_ agentName: String) -> [String] {
    agentName.split(separator: "-").map(String.init)
}

func agentId(from agentName: String) -> String {
    agentNameParts(agentName).first ?? agentName
}

func agentKindName(from agentName: String) -> String? {
    let parts = agentNameParts(agentName)
    guard parts.count >= 2 else { return nil }
    return parts[1]
}

func agentKindSpec(for agentName: String) -> AgentKindSpec? {
    guard let kindName = agentKindName(from: agentName) else { return nil }
    return agentKindsByName[kindName]
}

func existingAgentNames() -> [String] {
    agentEntries.compactMap { url -> String? in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }
        return url.lastPathComponent
    }
}

func resolveAgentName(_ agentArg: String) -> String {
    let agentNames = existingAgentNames()
    if agentNames.contains(agentArg) {
        return agentArg
    }

    let matches = agentNames.filter { name in
        name.contains(agentArg) && agentKindSpec(for: name) != nil
    }
    if matches.count == 1 {
        return matches[0]
    }
    if matches.isEmpty {
        fputs("unknown agent id: \(agentArg)\n", stderr)
    } else {
        let list = matches.sorted().joined(separator: ", ")
        fputs("ambiguous agent id: \(agentArg) (matches: \(list))\n", stderr)
    }
    exit(1)
}

func validateNewAgentName(_ agentName: String) -> String {
    if let kindName = agentKindName(from: agentName), agentKindsByName[kindName] != nil {
        return agentName
    }
    let kinds = agentKindSpecs.map(\.kind).sorted().joined(separator: ", ")
    fputs("agent name must include a known kind, e.g. 007-openclaw (known kinds: \(kinds))\n", stderr)
    exit(1)
}

func resolveInitAgentName(_ agentArg: String) -> String {
    let agentNames = existingAgentNames()
    if agentNames.contains(agentArg) {
        return agentArg
    }

    let matches = agentNames.filter { name in
        name.contains(agentArg) && agentKindSpec(for: name) != nil
    }
    if matches.count == 1 {
        return matches[0]
    }
    if matches.count > 1 {
        let list = matches.sorted().joined(separator: ", ")
        fputs("ambiguous agent id: \(agentArg) (matches: \(list))\n", stderr)
        exit(1)
    }

    return validateNewAgentName(agentArg)
}

func portFor(agent: String) -> String? {
    let repoConfig = parseSectionedConfigFile(at: repoConfigURL)
    return repoConfig["agent-ports"]?[agentId(from: agent)]
}

func execInteractive(_ argv: [String]) -> Never {
    guard let first = argv.first else {
        fputs("no command provided\n", stderr)
        exit(1)
    }

    var resolved = argv
    resolved[0] = resolveExecutable(first)

    var cArgs = resolved.map { strdup($0) }
    cArgs.append(nil)
    guard let command = cArgs[0] else {
        fputs("no command provided\n", stderr)
        exit(1)
    }
    cArgs.withUnsafeMutableBufferPointer { argsBuffer in
        guard let argv = argsBuffer.baseAddress else {
            fputs("no argv provided\n", stderr)
            exit(1)
        }
        execv(command, argv)
    }
    perror("execv")
    exit(1)
}

func runCommandAndWait(_ argv: [String]) {
    guard let first = argv.first else {
        fputs("no command provided\n", stderr)
        exit(1)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: resolveExecutable(first))
    process.arguments = Array(argv.dropFirst())
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("failed to run \(argv.joined(separator: " ")): \(error)\n", stderr)
        exit(1)
    }

    if process.terminationStatus != 0 {
        exit(process.terminationStatus)
    }
}

func infraScriptPath(_ subcommand: String) -> String {
    let infraRoot = rootURL.appendingPathComponent("infra")
    let builtInSubcommands: Set<String> = ["bootstrap", "install", "uninstall", "start", "stop", "restart", "status", "doctor", "log", "render"]
    let customScriptsURL = customConfigURL.appendingPathComponent("override", isDirectory: true).appendingPathComponent("infra", isDirectory: true)
    let customScriptURL = customScriptsURL.appendingPathComponent("\(subcommand).sh")

    if FileManager.default.isExecutableFile(atPath: customScriptURL.path) {
        return customScriptURL.path
    }

    guard builtInSubcommands.contains(subcommand) else {
        fputs("unknown infra subcommand: \(subcommand)\n", stderr)
        let customSubcommands = ((try? FileManager.default.contentsOfDirectory(
            at: customScriptsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == "sh" && FileManager.default.isExecutableFile(atPath: $0.path) }
            .map { $0.deletingPathExtension().lastPathComponent }
        let supported = (Array(builtInSubcommands) + customSubcommands).sorted().joined(separator: ", ")
        fputs("supported: \(supported)\n", stderr)
        exit(1)
    }

    return infraRoot
        .appendingPathComponent("commands", isDirectory: true)
        .appendingPathComponent("\(subcommand).sh").path
}

func handleInfra(subcommand: String, extra: [String]) -> Never {
    execInteractive(["/bin/bash", infraScriptPath(subcommand)] + extra)
}

func handleEdit(agentURL: URL) -> Never {
    let env = ProcessInfo.processInfo.environment
    if let editor = env["EDITOR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !editor.isEmpty {
        let editorArgs = editor.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        execInteractive(editorArgs + [agentURL.path])
    }
    fputs("$EDITOR is not set\n", stderr)
    exit(1)
}

func runBootstrapSteps(kind: AgentKindSpec) {
    if !kind.brewTaps.isEmpty || !kind.brewPackages.isEmpty || !kind.brewCasks.isEmpty {
        _ = resolveExecutable("brew")

        for tap in kind.brewTaps {
            runCommandAndWait(["brew", "tap", tap])
        }
        if !kind.brewPackages.isEmpty {
            runCommandAndWait(["brew", "install"] + kind.brewPackages)
        }
        if !kind.brewCasks.isEmpty {
            runCommandAndWait(["brew", "install", "--cask"] + kind.brewCasks)
        }
    }

    switch kind.installKind ?? "" {
    case "":
        if kind.brewTaps.isEmpty && kind.brewPackages.isEmpty && kind.brewCasks.isEmpty {
            print("no bootstrap step defined for agent kind: \(kind.kind)")
        }
    case "script":
        guard let installScript = kind.installScript, !installScript.isEmpty else {
            fputs("agent kind \(kind.kind) is missing CLAWLAB_AGENT_INSTALL_SCRIPT\n", stderr)
            exit(1)
        }
        let scriptPath = rootURL.appendingPathComponent(installScript).path
        runCommandAndWait(["/bin/bash", scriptPath])
    default:
        fputs("unsupported CLAWLAB_AGENT_INSTALL_KIND for \(kind.kind): \(kind.installKind ?? "")\n", stderr)
        exit(1)
    }
}

func handleBootstrap(kind: AgentKindSpec, agentURL: URL) -> Never {
    applyPerAgentEnvironment(agent: agentURL.lastPathComponent)
    applyAgentEnvironment(kind, agentURL: agentURL)
    switchToAgentDirectory(agentURL)
    runBootstrapSteps(kind: kind)

    exit(0)
}

func ensureGitkeep(in agentURL: URL) throws {
    let gitkeepURL = agentURL.appendingPathComponent(".gitkeep")
    if !FileManager.default.fileExists(atPath: gitkeepURL.path) {
        _ = FileManager.default.createFile(atPath: gitkeepURL.path, contents: nil)
    }
}

func agentDirectoryContents(at agentURL: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: agentURL.path)) ?? []).sorted()
}

func handleInit(agent: String, agentURL: URL, kind: AgentKindSpec, extra: [String]) -> Never {
    var created = false
    do {
        if !FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.createDirectory(at: agentURL, withIntermediateDirectories: true)
            created = true
        }
        try ensureGitkeep(in: agentURL)
        if created {
            print("created working dir: \(agent)")
        }

        let contents = agentDirectoryContents(at: agentURL)
        if contents != [".gitkeep"] {
            print("skipping make for non-empty agent dir: \(agent)")
            exit(0)
        }

        runInitCommand(agent: agent, kind: kind, agentURL: agentURL, extra: extra)
    } catch {
        fputs("failed to create working dir: \(error)\n", stderr)
        exit(1)
    }
}

func applyAgentEnvironment(_ kind: AgentKindSpec, agentURL: URL) {
    if let homeEnvName = kind.homeEnvName {
        setenv(homeEnvName, agentURL.path, 1)
    }
    for (key, rawValue) in kind.envAssignments {
        let value = rawValue.replacingOccurrences(of: "__AGENT_DIR__", with: agentURL.path)
        setenv(key, value, 1)
    }
}

func applyPerAgentEnvironment(agent: String) {
    let agentURL = agentsURL.appendingPathComponent(agent, isDirectory: true)
    let sharedEnvURL = customEnvURL.appendingPathComponent("agents.env")
    applyEnvFile(at: sharedEnvURL, agentURL: agentURL)

    let envURL = customEnvURL
        .appendingPathComponent("agents", isDirectory: true)
        .appendingPathComponent("\(agentId(from: agent)).env")
    applyEnvFile(at: envURL, agentURL: agentURL)
}

func applyEnvFile(at envURL: URL, agentURL: URL) {
    for (key, rawValue) in parseEnvFile(at: envURL) {
        let value = rawValue
            .replacingOccurrences(of: "__CLAWLAB_ROOT__", with: rootURL.path)
            .replacingOccurrences(of: "__AGENT_DIR__", with: agentURL.path)
        setenv(key, value, 1)
    }
}

func switchToAgentDirectory(_ agentURL: URL) {
    guard FileManager.default.changeCurrentDirectoryPath(agentURL.path) else {
        fputs("failed to switch to agent dir: \(agentURL.path)\n", stderr)
        exit(1)
    }
}

func expandTemplateArgs(_ args: [String], agentURL: URL, port: String? = nil, command: String? = nil) -> [String] {
    var expanded: [String] = []

    for arg in args {
        var value = arg.replacingOccurrences(of: "__AGENT_DIR__", with: agentURL.path)
        if let port {
            value = value.replacingOccurrences(of: "__PORT__", with: port)
        }
        if let command {
            value = value.replacingOccurrences(of: "__COMMAND__", with: command)
        }

        if value == "__PORT__" && port == nil {
            continue
        }
        if value == "__COMMAND__" && command == nil {
            continue
        }
        expanded.append(value)
    }

    return expanded
}

func buildForwardArgs(kind: AgentKindSpec, agentURL: URL, command: String) -> [String] {
    let prefix = expandTemplateArgs(kind.forwardPrefix, agentURL: agentURL, command: command)
    if prefix.contains(command) {
        return prefix
    }
    return prefix + [command]
}

func promptYesNo(_ question: String) -> Bool {
    fputs("\(question) [y/N]: ", stderr)
    let reply = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return reply == "y" || reply == "yes"
}

func confirmBootstrap(agent: String, command: String) -> Bool {
    fputs("executable not found in PATH: \(command)\n", stderr)
    guard isatty(fileno(stdin)) != 0 else {
        fputs("run ./cmd \(agentId(from: agent)) bootstrap to install it\n", stderr)
        exit(1)
    }
    return promptYesNo("Run ./cmd \(agentId(from: agent)) bootstrap now?")
}

func ensureInitExecutable(agent: String, kind: AgentKindSpec, args: [String]) {
    guard let command = args.first else { return }
    guard executablePath(command) == nil else { return }

    if !confirmBootstrap(agent: agent, command: command) {
        fputs("aborted\n", stderr)
        exit(1)
    }

    runBootstrapSteps(kind: kind)

    if executablePath(command) == nil {
        fputs("executable still not found in PATH after bootstrap: \(command)\n", stderr)
        exit(1)
    }
}

func hasBootstrapSteps(kind: AgentKindSpec) -> Bool {
    if !kind.brewTaps.isEmpty || !kind.brewPackages.isEmpty || !kind.brewCasks.isEmpty {
        return true
    }
    return !(kind.installKind ?? "").isEmpty
}

func confirmBootstrapWithoutMake(agent: String, kind: AgentKindSpec) -> Bool {
    let agentID = agentId(from: agent)
    fputs("no make command for agent kind: \(kind.kind)\n", stderr)
    guard isatty(fileno(stdin)) != 0 else {
        fputs("run ./cmd \(agentID) bootstrap to install manually\n", stderr)
        exit(0)
    }
    return promptYesNo("Run ./cmd \(agentID) bootstrap now?")
}

func runInitCommand(agent: String, kind: AgentKindSpec, agentURL: URL, extra: [String]) -> Never {
    applyPerAgentEnvironment(agent: agent)
    applyAgentEnvironment(kind, agentURL: agentURL)
    switchToAgentDirectory(agentURL)
    if !kind.hasInitCommand {
        if !extra.isEmpty {
            fputs("make is not defined for agent kind: \(kind.kind)\n", stderr)
            exit(1)
        }
        if hasBootstrapSteps(kind: kind) {
            if confirmBootstrapWithoutMake(agent: agent, kind: kind) {
                runBootstrapSteps(kind: kind)
            }
            exit(0)
        }
        print("no make command for agent kind: \(kind.kind)")
        print("run ./cmd \(agentId(from: agent)) bootstrap to install manually")
        exit(0)
    }
    let args = expandTemplateArgs(kind.initArgs, agentURL: agentURL) + extra
    ensureInitExecutable(agent: agent, kind: kind, args: args)
    execInteractive(args)
}

func handleStart(kind: AgentKindSpec, agentURL: URL, port: String?, extra: [String]) -> Never {
    applyPerAgentEnvironment(agent: agentURL.lastPathComponent)
    applyAgentEnvironment(kind, agentURL: agentURL)
    switchToAgentDirectory(agentURL)
    var args = expandTemplateArgs(kind.startArgs, agentURL: agentURL)
    if let portFlag = kind.startPortFlag, let port, !portFlag.isEmpty {
        args += [portFlag, port]
    }
    args += extra
    execInteractive(args)
}

func handleStop(kind: AgentKindSpec, agentURL: URL, extra: [String]) -> Never {
    if !kind.stopArgs.isEmpty {
        applyPerAgentEnvironment(agent: agentURL.lastPathComponent)
        applyAgentEnvironment(kind, agentURL: agentURL)
        switchToAgentDirectory(agentURL)
        let args = expandTemplateArgs(kind.stopArgs, agentURL: agentURL) + extra
        execInteractive(args)
    }

    let pattern = expandTemplateArgs(kind.startArgs, agentURL: agentURL).joined(separator: " ")

    let pgrepProcess = Process()
    pgrepProcess.executableURL = URL(fileURLWithPath: resolveExecutable("pgrep"))
    pgrepProcess.arguments = ["-f", pattern]
    let pipe = Pipe()
    pgrepProcess.standardOutput = pipe
    pgrepProcess.standardError = FileHandle.standardError

    do {
        try pgrepProcess.run()
        pgrepProcess.waitUntilExit()
    } catch {
        fputs("failed to run pgrep: \(error)\n", stderr)
        exit(1)
    }

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

    if pids.isEmpty {
        fputs("no running \(kind.kind) process found\n", stderr)
        exit(1)
    }

    for pid in pids {
        kill(pid, SIGTERM)
    }
    print("sent SIGTERM to \(kind.kind) (pid: \(pids.map(String.init).joined(separator: ", ")))")
    exit(0)
}

func existingCleanupTargets(for agents: [String], removesLastAgent: Bool) -> [String] {
#if os(Linux)
    if removesLastAgent && FileManager.default.fileExists(atPath: "/etc/systemd/system/agent@.service") {
        return agents.map(agentId)
    }
    return []
#else
    return agents.compactMap { agent -> String? in
        let id = agentId(from: agent)
        let plistPath = "/Library/LaunchDaemons/net.tadija.clawlab.\(id).plist"
        return FileManager.default.fileExists(atPath: plistPath) ? id : nil
    }
#endif
}

func offerServiceManagerCleanup(targets: [String]) -> Never {
    guard !targets.isEmpty else {
        exit(0)
    }

    let command = "./cmd infra uninstall \(targets.joined(separator: " "))"
    guard isatty(fileno(stdin)) != 0 else {
        print("service-manager artifacts may still exist; run: \(command)")
        exit(0)
    }

    if promptYesNo("Service-manager artifacts may still exist. Run \(command) now?") {
        execInteractive(["/bin/bash", infraScriptPath("uninstall")] + targets)
    }

    exit(0)
}

func handleRemove(agentArgs: [String]) -> Never {
    let confirmArgs: Set<String> = ["-y", "--yes"]
    let unknownOptions = agentArgs.filter { $0.hasPrefix("-") && !confirmArgs.contains($0) }
    if !unknownOptions.isEmpty {
        fputs("usage: cmd remove <agent-id> [agent-id...] [-y|--yes]\n", stderr)
        exit(1)
    }

    let autoConfirm = agentArgs.contains(where: { confirmArgs.contains($0) })
    let requestedAgents = agentArgs.filter { !confirmArgs.contains($0) }
    if requestedAgents.isEmpty {
        fputs("usage: cmd remove <agent-id> [agent-id...] [-y|--yes]\n", stderr)
        exit(1)
    }

    let agents = requestedAgents.map(resolveAgentName)
    let duplicates = Dictionary(grouping: agents, by: { $0 }).filter { $0.value.count > 1 }.keys
    if !duplicates.isEmpty {
        let list = duplicates.sorted().joined(separator: ", ")
        fputs("duplicate agent id: \(list)\n", stderr)
        exit(1)
    }

    for agent in agents {
        let agentURL = agentsURL.appendingPathComponent(agent, isDirectory: true)
        requireAgentDir(agent: agent, agentURL: agentURL)
    }

    let removesLastAgent = Set(existingAgentNames()).subtracting(agents).isEmpty

    let isInteractive = isatty(fileno(stdin)) != 0
    if !autoConfirm {
        if !isInteractive {
            fputs("non-interactive: pass -y or --yes to confirm removal\n", stderr)
            exit(1)
        }
        if agents.count == 1 {
            let agentURL = agentsURL.appendingPathComponent(agents[0], isDirectory: true)
            fputs("Remove agent '\(agents[0])' at \(agentURL.path)? [y/N]: ", stderr)
        } else {
            fputs("Remove agents \(agents.joined(separator: ", "))? [y/N]: ", stderr)
        }
        let reply = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if reply != "y" && reply != "yes" {
            fputs("aborted\n", stderr)
            exit(1)
        }
    }

    for agent in agents {
        let agentURL = agentsURL.appendingPathComponent(agent, isDirectory: true)

        do {
            try FileManager.default.removeItem(at: agentURL)
        } catch {
            fputs("failed to remove working dir \(agentURL.path): \(error)\n", stderr)
            exit(1)
        }
        print("removed working dir: \(agent)")
    }

    offerServiceManagerCleanup(targets: existingCleanupTargets(for: agents, removesLastAgent: removesLastAgent))
}

func forwardCommand(kind: AgentKindSpec, agentURL: URL, command: String, extra: [String]) -> Never {
    applyPerAgentEnvironment(agent: agentURL.lastPathComponent)
    applyAgentEnvironment(kind, agentURL: agentURL)
    switchToAgentDirectory(agentURL)
    let args = buildForwardArgs(kind: kind, agentURL: agentURL, command: command) + extra
    execInteractive(args)
}

func requireAgentDir(agent: String, agentURL: URL) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: agentURL.path, isDirectory: &isDir), isDir.boolValue else {
        fputs("unknown agent: \(agent)\n", stderr)
        fputs("create it with: cmd make \(agent)\n", stderr)
        exit(1)
    }
}

switch parsed {
case .globalList:
    listAgents()
case .globalMake(let agentArg, let extra):
    let resolvedName = resolveInitAgentName(agentArg)
    let agentURL = agentsURL.appendingPathComponent(resolvedName, isDirectory: true)
    guard let kind = agentKindSpec(for: resolvedName) else {
        fputs("unrecognized agent kind: \(resolvedName)\n", stderr)
        exit(1)
    }
    handleInit(agent: resolvedName, agentURL: agentURL, kind: kind, extra: extra)
case .globalRemove(let args):
    handleRemove(agentArgs: args)
case .globalInfra(let subcommand, let extra):
    handleInfra(subcommand: subcommand, extra: extra)
case .agent(let agentArg, let command, let extra):
    let agentName = resolveAgentName(agentArg)
    let agentURL = agentsURL.appendingPathComponent(agentName, isDirectory: true)
    let port = portFor(agent: agentName)

    guard let kind = agentKindSpec(for: agentName) else {
        fputs("unrecognized agent kind: \(agentName)\n", stderr)
        exit(1)
    }

    requireAgentDir(agent: agentName, agentURL: agentURL)

    if let agentCommand = AgentCommand(rawValue: command) {
        switch agentCommand {
        case .bootstrap:
            handleBootstrap(kind: kind, agentURL: agentURL)
        case .edit:
            handleEdit(agentURL: agentURL)
        case .start:
            handleStart(kind: kind, agentURL: agentURL, port: port, extra: extra)
        case .stop:
            handleStop(kind: kind, agentURL: agentURL, extra: extra)
        }
    } else {
        forwardCommand(kind: kind, agentURL: agentURL, command: command, extra: extra)
    }
}


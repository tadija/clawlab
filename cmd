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
""")
}

enum AgentTool: String, CaseIterable {
    case openclaw
    case picoclaw
    case zeroclaw
}

enum GlobalCommand: String {
    case make
    case list
}

enum AgentCommand: String {
    case edit
    case prompt
    case start
    case stop
    case remove
}

let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let agentsURL = rootURL.appendingPathComponent("agents", isDirectory: true)
let configURL = rootURL.appendingPathComponent("cfg")

var agentEntries: [URL] {
    (try? FileManager.default.contentsOfDirectory(
        at: agentsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
}

func listAgents() -> Never {
    let agents = agentEntries.compactMap { url -> String? in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }
        return url.lastPathComponent
    }.sorted()
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
    case globalMake(agentName: String)
    case globalList
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
        if args.count != 3 {
            fputs("usage: cmd make <agent-name>\n", stderr)
            exit(1)
        }
        return .globalMake(agentName: args[2])
    default:
        if args.count < 3 {
            usage()
            exit(1)
        }
        if args[2] == GlobalCommand.make.rawValue || args[2] == GlobalCommand.list.rawValue {
            fputs("usage: cmd <agent-id> <command...>\n", stderr)
            exit(1)
        }
        return .agent(agentArg: args[1], command: args[2], extra: Array(args.dropFirst(3)))
    }
}

let parsed = parseArgs(CommandLine.arguments)

func resolveAgentName(_ agentArg: String, command: String) -> String {
    if command == GlobalCommand.make.rawValue {
        if AgentTool.allCases.contains(where: { agentArg.contains($0.rawValue) }) {
            return agentArg
        }
        fputs("agent name must include kind, e.g. 007-openclaw (got: \(agentArg))\n", stderr)
        exit(1)
    }

    let agentNames = agentEntries.compactMap { url -> String? in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return nil }
        return url.lastPathComponent
    }

    if agentNames.contains(agentArg) {
        return agentArg
    }

    let matches = agentNames.filter { name in
        name.contains(agentArg) && AgentTool.allCases.contains { name.contains($0.rawValue) }
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

func portFor(agent: String) -> String? {
    guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
    guard let data = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
    let key = "\(agent)_gateway"
    var inPorts = false
    for rawLine in data.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
        if !isIndented {
            inPorts = (trimmed == "ports:" || trimmed == "ports")
            continue
        }
        if !inPorts { continue }
        if let eq = trimmed.firstIndex(of: "=") {
            let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if k == key { return String(v) }
        } else if let colon = trimmed.firstIndex(of: ":") {
            let k = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let v = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k == key { return String(v) }
        }
    }
    return nil
}

func execInteractive(_ argv: [String]) -> Never {
    var cArgs = argv.map { strdup($0) }
    cArgs.append(nil)
    execvp(cArgs[0], &cArgs)
    perror("execvp")
    exit(1)
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

func handleMake(agent: String, agentURL: URL) -> Never {
    if FileManager.default.fileExists(atPath: agentURL.path) {
        fputs("agent already exists: \(agent)\n", stderr)
        exit(1)
    }
    do {
        try FileManager.default.createDirectory(at: agentURL, withIntermediateDirectories: true)
        let gitkeepURL = agentURL.appendingPathComponent(".gitkeep")
        FileManager.default.createFile(atPath: gitkeepURL.path, contents: nil)
        print("created working dir: \(agent)")
        exit(0)
    } catch {
        fputs("failed to create working dir: \(error)\n", stderr)
        exit(1)
    }
}

func handleStart(agentTool: AgentTool, agentURL: URL, port: String?, extra: [String]) -> Never {
    switch agentTool {
    case .openclaw:
        var args = ["openclaw", "gateway"]
        if let port = port { args += ["--port", port] }
        args += extra
        setenv("OPENCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .picoclaw:
        var args = ["picoclaw", "gateway"]
        if let port = port { args += ["--port", port] }
        args += extra
        setenv("PICOCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .zeroclaw:
        var args = ["zeroclaw", "--config-dir", agentURL.path, "daemon"]
        if let port = port { args += ["--port", port] }
        args += extra
        execInteractive(args)
    }
}

func handleStop(agentTool: AgentTool, agentURL: URL, extra: [String]) -> Never {
    switch agentTool {
    case .openclaw:
        let args = ["openclaw", "gateway", "stop"] + extra
        setenv("OPENCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .picoclaw:
        let args = ["picoclaw", "gateway", "stop"] + extra
        setenv("PICOCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .zeroclaw:
        fputs("zeroclaw has no stop command yet\n", stderr)
        exit(1)
    }
}

func handleRemove(agent: String, agentURL: URL, extra: [String]) -> Never {
    let confirmArgs: Set<String> = ["-y", "--yes"]
    let unknownArgs = extra.filter { !confirmArgs.contains($0) }
    if !unknownArgs.isEmpty {
        fputs("usage: cmd <agent-id> remove [-y|--yes]\n", stderr)
        exit(1)
    }

    let autoConfirm = extra.contains(where: { confirmArgs.contains($0) })
    let isInteractive = isatty(fileno(stdin)) != 0
    if !autoConfirm {
        if !isInteractive {
            fputs("non-interactive: pass -y or --yes to confirm removal\n", stderr)
            exit(1)
        }
        fputs("Remove agent '\(agent)' at \(agentURL.path)? [y/N]: ", stderr)
        let reply = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if reply != "y" && reply != "yes" {
            fputs("aborted\n", stderr)
            exit(1)
        }
    }
    do {
        try FileManager.default.removeItem(at: agentURL)
        print("removed working dir: \(agent)")
        exit(0)
    } catch {
        fputs("failed to remove working dir: \(error)\n", stderr)
        exit(1)
    }
}

func promptMessage(extra: [String]) -> String? {
    if let message = extra.last, !message.isEmpty {
        return message
    }

    let isInteractive = isatty(fileno(stdin)) != 0
    if isInteractive {
        fputs("message: ", stderr)
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return input.isEmpty ? nil : input
    }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }
    let input = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return input.isEmpty ? nil : input
}

func handlePrompt(agentTool: AgentTool, agentURL: URL, extra: [String]) -> Never {
    guard let message = promptMessage(extra: extra) else {
        fputs("usage: cmd <agent-id> prompt [message]\n", stderr)
        fputs("tip: omit [message] for interactive input or pipe from stdin\n", stderr)
        exit(1)
    }

    switch agentTool {
    case .openclaw:
        let args = ["openclaw", "agent", "-m", message]
        setenv("OPENCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .picoclaw:
        let args = ["picoclaw", "agent", "-m", message]
        setenv("PICOCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .zeroclaw:
        let args = ["zeroclaw", "--config-dir", agentURL.path, "agent", "-m", message]
        execInteractive(args)
    }
}

func forwardCommand(agentTool: AgentTool, agentURL: URL, command: String, extra: [String]) -> Never {
    switch agentTool {
    case .openclaw:
        let args = ["openclaw", command] + extra
        setenv("OPENCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .picoclaw:
        let args = ["picoclaw", command] + extra
        setenv("PICOCLAW_HOME", agentURL.path, 1)
        execInteractive(args)
    case .zeroclaw:
        let args = ["zeroclaw", "--config-dir", agentURL.path, command] + extra
        execInteractive(args)
    }
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
case .globalMake(let agentName):
    let agentURL = agentsURL.appendingPathComponent(agentName, isDirectory: true)
    handleMake(agent: agentName, agentURL: agentURL)
case .agent(let agentArg, let command, let extra):
    let agentName = resolveAgentName(agentArg, command: command)
    let agentURL = agentsURL.appendingPathComponent(agentName, isDirectory: true)
    let port = portFor(agent: agentName)
    let kind = AgentTool.allCases.first { agentName.contains($0.rawValue) }

    guard let agentTool = kind else {
        fputs("unrecognized agent kind: \(agentName)\n", stderr)
        exit(1)
    }

    requireAgentDir(agent: agentName, agentURL: agentURL)

    if let agentCommand = AgentCommand(rawValue: command) {
        switch agentCommand {
        case .edit:
            handleEdit(agentURL: agentURL)
        case .prompt:
            handlePrompt(agentTool: agentTool, agentURL: agentURL, extra: extra)
        case .start:
            handleStart(agentTool: agentTool, agentURL: agentURL, port: port, extra: extra)
        case .stop:
            handleStop(agentTool: agentTool, agentURL: agentURL, extra: extra)
        case .remove:
            handleRemove(agent: agentName, agentURL: agentURL, extra: extra)
        }
    } else {
        forwardCommand(agentTool: agentTool, agentURL: agentURL, command: command, extra: extra)
    }
}


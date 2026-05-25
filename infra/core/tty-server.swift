#!/usr/bin/env swift

import Foundation
#if os(Linux)
import Glibc

@_silgen_name("posix_openpt")
func libc_posix_openpt(_ flags: Int32) -> Int32

@_silgen_name("grantpt")
func libc_grantpt(_ fd: Int32) -> Int32

@_silgen_name("unlockpt")
func libc_unlockpt(_ fd: Int32) -> Int32

@_silgen_name("ptsname")
func libc_ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#else
import Darwin
#endif

@_silgen_name("fork")
func libc_fork() -> pid_t

struct Config {
    let repoRoot: String
    let host: String
    let port: UInt16
    let shellPath: String
}

let logFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func log(_ message: String, level: String = "info") {
    let ts = logFormatter.string(from: Date())
#if os(Linux)
    let stream = (level == "error" ? stderr! : stdout!)
#else
    let stream = (level == "error" ? stderr : stdout)
#endif
    fputs("[\(ts)] \(level) \(message)\n", stream)
    fflush(stream)
}

enum TerminalLaunchMode {
    case shell
    case agentTui
    case agentYoloTui
    case projectTool(name: String)
    case tmuxAttach(sessionName: String, windowId: String?)
}

enum TerminalTargetKind {
    case host
    case agent
    case project
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum WebSocketMessage {
    case input(Data)
    case resize(cols: Int32, rows: Int32)
    case pin
    case unpin
    case kill
    case ping(Data)
    case close
    case unknown
}

struct TerminalContext {
    let agentId: String?
    let projectTitle: String?
    let targetKind: TerminalTargetKind
    let workspace: String
    let launchMode: TerminalLaunchMode
}

struct SessionMetadata {
    let agentId: String?
    let projectTitle: String?
    let workspace: String
    let launchMode: TerminalLaunchMode
}

struct TmuxSession {
    let name: String
    let attached: Int
    let windows: Int

    var path: String {
        "/tty/tmux/\(urlEncodePathSegment(name))/"
    }

    func dictionary() -> [String: Any] {
        [
            "name": name,
            "path": path,
            "attached": attached,
            "windows": windows
        ]
    }
}

struct TmuxDiscovery {
    let sessions: [TmuxSession]
    let tmuxPath: String?
    let socketArguments: [String]
    let exitStatus: Int32?
    let errorOutput: String?
}

struct TerminalSpawnResult {
    let masterFD: Int32
    let pid: pid_t
}

enum TerminalSpawnFailure: Error {
    case message(String)
}

func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func usage() -> Never {
    fputs("usage: tty-server.swift --repo-root <path> [--bind 127.0.0.1] [--port 1984] [--shell /bin/bash]\n", stderr)
    exit(1)
}

func serviceUserHomeDirectory() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return home
    }
    return NSHomeDirectory()
}

func parseArgs() -> Config {
    var repoRoot: String?
    var host = "127.0.0.1"
    var port: UInt16 = 1984
    var shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"

    var index = 1
    while index < CommandLine.arguments.count {
        let arg = CommandLine.arguments[index]
        switch arg {
        case "--repo-root":
            index += 1
            guard index < CommandLine.arguments.count else { usage() }
            repoRoot = CommandLine.arguments[index]
        case "--bind":
            index += 1
            guard index < CommandLine.arguments.count else { usage() }
            host = CommandLine.arguments[index]
        case "--port":
            index += 1
            guard index < CommandLine.arguments.count, let parsed = UInt16(CommandLine.arguments[index]) else { usage() }
            port = parsed
        case "--shell":
            index += 1
            guard index < CommandLine.arguments.count else { usage() }
            shellPath = CommandLine.arguments[index]
        case "-h", "--help", "help":
            usage()
        default:
            usage()
        }
        index += 1
    }

    guard let repoRoot else { usage() }
    return Config(repoRoot: repoRoot, host: host, port: port, shellPath: shellPath)
}

func makeServerSocket(host: String, port: UInt16) -> Int32 {
    #if os(Linux)
    let socketType = Int32(SOCK_STREAM.rawValue)
    #else
    let socketType = SOCK_STREAM
    #endif

    let serverFD = socket(AF_INET, socketType, 0)
    guard serverFD >= 0 else {
        perror("socket")
        exit(1)
    }

    var yes: Int32 = 1
    if setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        perror("setsockopt")
        exit(1)
    }

    var address = sockaddr_in()
    #if !os(Linux)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian

    let inetResult = host.withCString { source in
        withUnsafeMutablePointer(to: &address.sin_addr) { destination in
            inet_pton(AF_INET, source, destination)
        }
    }
    guard inetResult == 1 else {
        fputs("invalid bind address: \(host)\n", stderr)
        exit(1)
    }

    var sockAddr = address
    let bindResult = withUnsafePointer(to: &sockAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        perror("bind")
        exit(1)
    }

    guard listen(serverFD, 128) == 0 else {
        perror("listen")
        exit(1)
    }

    return serverFD
}

func sendAll(fd: Int32, data: Data) {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let result = send(fd, base.advanced(by: sent), data.count - sent, 0)
            if result <= 0 {
                break
            }
            sent += result
        }
    }
}

func response(status: String, contentType: String, body: Data, headOnly: Bool = false) -> Data {
    var headers = "HTTP/1.1 \(status)\r\n"
    headers += "Content-Type: \(contentType)\r\n"
    headers += "Cache-Control: no-store\r\n"
    headers += "Content-Length: \(body.count)\r\n"
    headers += "Connection: close\r\n"
    headers += "\r\n"

    var data = Data(headers.utf8)
    if !headOnly {
        data.append(body)
    }
    return data
}

func noContentResponse() -> Data {
    var headers = "HTTP/1.1 204 No Content\r\n"
    headers += "Cache-Control: no-store\r\n"
    headers += "Content-Length: 0\r\n"
    headers += "Connection: close\r\n"
    headers += "\r\n"
    return Data(headers.utf8)
}

func htmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func trim(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func repoConfigEntries(repoRoot: String, section wantedSection: String) -> [(key: String, value: String)] {
    let path = URL(fileURLWithPath: repoRoot).appendingPathComponent("config/custom/repo.ini").path
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }

    var entries: [(key: String, value: String)] = []
    var currentSection = ""

    for rawLine in raw.components(separatedBy: .newlines) {
        let line = trim(rawLine)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            currentSection = trim(String(line.dropFirst().dropLast()))
            continue
        }
        guard currentSection == wantedSection, let separator = line.firstIndex(of: "=") else {
            continue
        }
        let key = trim(String(line[..<separator]))
        let value = trim(String(line[line.index(after: separator)...]))
        if !key.isEmpty && !value.isEmpty {
            entries.append((key: key, value: value))
        }
    }

    return entries
}

func readHTTPRequest(fd: Int32) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)

    let headerTerminator = Data("\r\n\r\n".utf8)
    while buffer.range(of: headerTerminator) == nil {
        let count = recv(fd, &chunk, chunk.count, 0)
        if count <= 0 {
            return nil
        }
        buffer.append(chunk, count: Int(count))
        if buffer.count > 65536 {
            return nil
        }
    }

    if
        let headerEnd = buffer.range(of: headerTerminator)?.upperBound,
        let headerText = String(data: buffer.prefix(headerEnd), encoding: .utf8)
    {
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        while buffer.count - headerEnd < contentLength {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 {
                return nil
            }
            buffer.append(chunk, count: Int(count))
            if buffer.count > 1_048_576 {
                return nil
            }
        }
    }

    return buffer
}

func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    var bodyStartIndex = data.endIndex
    for line in lines.dropFirst() {
        if line.isEmpty { break }
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        headers[key] = value
    }
    if let headerRange = data.range(of: Data("\r\n\r\n".utf8)) {
        bodyStartIndex = headerRange.upperBound
    }

    return HTTPRequest(
        method: String(requestParts[0]),
        path: String(requestParts[1]),
        headers: headers,
        body: data.suffix(from: bodyStartIndex)
    )
}

func pathSegments(for path: String) -> [String] {
    let cleanPath = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
    return cleanPath
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
}

func queryItems(for path: String) -> [String: String] {
    guard let query = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else {
        return [:]
    }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = parts.first.map(String.init), !key.isEmpty else {
            continue
        }
        let value = parts.count > 1 ? String(parts[1]) : ""
        result[urlDecode(key)] = urlDecode(value)
    }
    return result
}

func initialTerminalSize(for path: String) -> (cols: Int32, rows: Int32)? {
    let query = queryItems(for: path)
    guard
        let colsText = query["cols"],
        let rowsText = query["rows"],
        let cols = Int32(colsText),
        let rows = Int32(rowsText)
    else {
        return nil
    }
    return (cols: max(20, min(cols, 300)), rows: max(8, min(rows, 120)))
}

func urlDecode(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}

func agentWorkspace(repoRoot: String, agentId: String) -> String {
    let agentsRoot = URL(fileURLWithPath: repoRoot).appendingPathComponent("agents", isDirectory: true)
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: agentsRoot.path) {
        let prefix = "\(agentId)-"
        if let match = contents.first(where: { $0.hasPrefix(prefix) }) {
            return agentsRoot.appendingPathComponent(match, isDirectory: true).path
        }
    }
    return agentsRoot.appendingPathComponent(agentId, isDirectory: true).path
}

func parseEnvAssignmentValue(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2 {
        let first = trimmed.first
        let last = trimmed.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
    }
    return trimmed
}

func hostProjects(repoRoot: String) -> [String: String] {
    let envPath = URL(fileURLWithPath: repoRoot)
        .appendingPathComponent("config/custom/host/.env")
        .path
    guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else {
        return [:]
    }

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("AELAB_PROJECTS=") else { continue }
        let rawValue = String(line.dropFirst("AELAB_PROJECTS=".count))
        let value = parseEnvAssignmentValue(rawValue)
        var projects: [String: String] = [:]
        for item in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let title = String(parts[0])
            let path = String(parts[1])
            if !title.isEmpty && !path.isEmpty {
                projects[title] = path
            }
        }
        return projects
    }

    return [:]
}

func normalizedTerminalSegments(for requestPath: String) -> [String] {
    var segments = pathSegments(for: requestPath)
    if segments.last == "ws" {
        segments.removeLast()
    }
    if segments.first == "tui" || segments.first == "tty" {
        segments.removeFirst()
    }
    return segments
}

func normalizedTerminalPath(for requestPath: String) -> String {
    let segments = normalizedTerminalSegments(for: requestPath).map(urlDecode)
    if segments.isEmpty {
        return "/tty/"
    }
    let encoded = segments.map(urlEncodePathSegment).joined(separator: "/")
    return "/tty/\(encoded)/"
}

func urlEncodePathSegment(_ value: String) -> String {
    var encoded = ""
    for byte in value.utf8 {
        if valueAllowedInPathSegment(byte) {
            encoded.append(Character(UnicodeScalar(byte)))
        } else {
            encoded += String(format: "%%%02X", byte)
        }
    }
    return encoded
}

func valueAllowedInPathSegment(_ byte: UInt8) -> Bool {
    (byte >= 48 && byte <= 57) ||
        (byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) ||
        byte == 45 || byte == 46 || byte == 95 || byte == 126
}

func terminalContext(repoRoot: String, requestPath: String) -> TerminalContext {
    let segments = normalizedTerminalSegments(for: requestPath)
    guard !segments.isEmpty else {
        return TerminalContext(agentId: nil, projectTitle: nil, targetKind: .host, workspace: serviceUserHomeDirectory(), launchMode: .shell)
    }

    if segments[0] == "tmux", segments.count >= 2 {
        let sessionName = urlDecode(segments[1])
        let windowId = segments.count >= 3 ? urlDecode(segments[2]) : nil
        return TerminalContext(agentId: nil, projectTitle: "tmux/\(sessionName)", targetKind: .host, workspace: repoRoot, launchMode: .tmuxAttach(sessionName: sessionName, windowId: windowId))
    }

    if segments[0].range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil {
        let agentId = segments[0]
        let mode: TerminalLaunchMode
        let workspace: String
        let targetKind: TerminalTargetKind
        if segments.last == "yolo" {
            mode = .agentYoloTui
            workspace = serviceUserHomeDirectory()
            targetKind = .project
        } else if segments.last == "tui" {
            mode = .agentTui
            workspace = agentWorkspace(repoRoot: repoRoot, agentId: agentId)
            targetKind = .agent
        } else {
            mode = .shell
            workspace = agentWorkspace(repoRoot: repoRoot, agentId: agentId)
            targetKind = .agent
        }
        return TerminalContext(agentId: agentId, projectTitle: nil, targetKind: targetKind, workspace: workspace, launchMode: mode)
    }

    let title = urlDecode(segments[0])
    if let workspace = hostProjects(repoRoot: repoRoot)[title] {
        if segments.count >= 2, segments[1] == "nvim" {
            return TerminalContext(agentId: nil, projectTitle: title, targetKind: .project, workspace: workspace, launchMode: .projectTool(name: "nvim"))
        }
        if segments.count >= 2, segments[1] == "lazygit" {
            return TerminalContext(agentId: nil, projectTitle: title, targetKind: .project, workspace: workspace, launchMode: .projectTool(name: "lazygit"))
        }
        if segments.count >= 3, segments[1].range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil, (segments.last == "tui" || segments.last == "yolo") {
            let mode: TerminalLaunchMode = segments.last == "yolo" ? .agentYoloTui : .agentTui
            return TerminalContext(agentId: segments[1], projectTitle: title, targetKind: .project, workspace: workspace, launchMode: mode)
        }
        return TerminalContext(agentId: nil, projectTitle: title, targetKind: .project, workspace: workspace, launchMode: .shell)
    }

    return TerminalContext(agentId: nil, projectTitle: nil, targetKind: .host, workspace: serviceUserHomeDirectory(), launchMode: .shell)
}

func sendWebSocketFrame(fd: Int32, opcode: UInt8, payload: Data) {
    var header = [UInt8]()
    header.append(0x80 | (opcode & 0x0f))

    let length = payload.count
    if length < 126 {
        header.append(UInt8(length))
    } else if length <= 0xffff {
        header.append(126)
        header.append(UInt8((length >> 8) & 0xff))
        header.append(UInt8(length & 0xff))
    } else {
        header.append(127)
        let len = UInt64(length).bigEndian
        withUnsafeBytes(of: len) { bytes in
            header.append(contentsOf: bytes)
        }
    }

    var frame = Data(header)
    frame.append(payload)
    sendAll(fd: fd, data: frame)
}

func sendWebSocketText(fd: Int32, text: String) {
    sendWebSocketFrame(fd: fd, opcode: 0x1, payload: Data(text.utf8))
}

func base64Encode(_ data: Data) -> String {
    data.base64EncodedString()
}

func base64Decode(_ value: String) -> Data? {
    Data(base64Encoded: value)
}

func sha1(_ data: Data) -> Data {
    var message = Array(data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while (message.count % 64) != 56 {
        message.append(0x00)
    }
    var length = bitLength.bigEndian
    withUnsafeBytes(of: &length) { bytes in
        message.append(contentsOf: bytes)
    }

    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        let chunk = Array(message[chunkStart..<chunkStart + 64])
        var w = [UInt32](repeating: 0, count: 80)

        for i in 0..<16 {
            let index = i * 4
            w[i] = (UInt32(chunk[index]) << 24)
                | (UInt32(chunk[index + 1]) << 16)
                | (UInt32(chunk[index + 2]) << 8)
                | UInt32(chunk[index + 3])
        }

        for i in 16..<80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotatedLeft(by: 1)
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4

        for i in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch i {
            case 0..<20:
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            case 20..<40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            default:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            }

            let temp = a.rotatedLeft(by: 5)
                &+ f
                &+ e
                &+ k
                &+ w[i]
            e = d
            d = c
            c = b.rotatedLeft(by: 30)
            b = a
            a = temp
        }

        h0 &+= a
        h1 &+= b
        h2 &+= c
        h3 &+= d
        h4 &+= e
    }

    var digest = Data()
    for word in [h0, h1, h2, h3, h4] {
        var bigEndianWord = word.bigEndian
        withUnsafeBytes(of: &bigEndianWord) { bytes in
            digest.append(contentsOf: bytes)
        }
    }
    return digest
}

extension UInt32 {
    func rotatedLeft(by amount: UInt32) -> UInt32 {
        (self << amount) | (self >> (32 - amount))
    }
}

func websocketAcceptValue(clientKey: String) -> String {
    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let combined = Data((clientKey + magic).utf8)
    return sha1(combined).base64EncodedString()
}

func parseWebSocketFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
    guard buffer.count >= 2 else { return nil }

    let b0 = buffer[buffer.startIndex]
    let b1 = buffer[buffer.index(after: buffer.startIndex)]
    let opcode = b0 & 0x0f
    let masked = (b1 & 0x80) != 0
    var length = Int(b1 & 0x7f)
    var offset = 2

    if length == 126 {
        guard buffer.count >= offset + 2 else { return nil }
        length = Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset)]) << 8
        length |= Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset + 1)])
        offset += 2
    } else if length == 127 {
        guard buffer.count >= offset + 8 else { return nil }
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value = (value << 8) | UInt64(buffer[buffer.index(buffer.startIndex, offsetBy: offset + byteIndex)])
        }
        guard value <= UInt64(Int.max) else { return nil }
        length = Int(value)
        offset += 8
    }

    var mask = [UInt8](repeating: 0, count: 4)
    if masked {
        guard buffer.count >= offset + 4 else { return nil }
        for index in 0..<4 {
            mask[index] = buffer[buffer.index(buffer.startIndex, offsetBy: offset + index)]
        }
        offset += 4
    }

    guard buffer.count >= offset + length else { return nil }
    var payload = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: offset)..<buffer.index(buffer.startIndex, offsetBy: offset + length))
    if masked {
        let payloadCount = payload.count
        payload.withUnsafeMutableBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<payloadCount {
                base.advanced(by: index).pointee ^= mask[index % 4]
            }
        }
    }

    buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset + length))
    return (opcode, payload)
}

func decodeWebSocketMessage(_ frame: (opcode: UInt8, payload: Data)) -> WebSocketMessage {
    switch frame.opcode {
    case 0x1:
        guard let text = String(data: frame.payload, encoding: .utf8) else { return .unknown }
        guard let data = text.data(using: .utf8) else { return .unknown }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? [String: Any],
            let type = dict["type"] as? String
        else {
            return .unknown
        }

        switch type {
        case "input":
            guard let base64 = dict["data"] as? String, let payload = base64Decode(base64) else { return .unknown }
            return .input(payload)
        case "resize":
            guard
                let cols = dict["cols"] as? NSNumber,
                let rows = dict["rows"] as? NSNumber
            else {
                return .unknown
            }
            return .resize(cols: cols.int32Value, rows: rows.int32Value)
        case "pin":
            return .pin
        case "unpin":
            return .unpin
        case "kill":
            return .kill
        case "ping":
            return .ping(frame.payload)
        case "close":
            return .close
        default:
            return .unknown
        }
    case 0x8:
        return .close
    case 0x9:
        return .ping(frame.payload)
    default:
        return .unknown
    }
}

func setWindowSize(fd: Int32, cols: Int32, rows: Int32) {
    var size = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(fd, UInt(TIOCSWINSZ), &size)
}

func resolveShellPath(_ candidate: String) -> String {
    if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return "/bin/bash"
}

let executableSearchDirectories = [
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
]

func executableCandidatePaths(name: String) -> [String] {
    executableSearchDirectories.map { "\($0)/\(name)" }
}

func resolveExecutablePath(_ name: String) -> String? {
    for path in executableCandidatePaths(name: name) where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in pathEnvironment.split(separator: ":", omittingEmptySubsequences: true) {
        let path = "\(directory)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

func resolveTmuxPath() -> String? {
    let preferredPaths = [
        "/home/linuxbrew/.linuxbrew/bin/tmux",
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux"
    ]
    for path in preferredPaths where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return resolveExecutablePath("tmux")
}

func tmuxSocketArguments() -> [String] {
    let uid = getuid()
    let candidates = [
        "/private/tmp/tmux-\(uid)/default",
        "/tmp/tmux-\(uid)/default"
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return ["-S", path]
    }
    return []
}

func spawnPTYProcess(workspace: String, executable: String, arguments: [String], environment: [String: String] = [:]) -> (masterFD: Int32, pid: pid_t)? {
    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1

    #if os(Linux)
    let flags = O_RDWR | O_NOCTTY
    #else
    let flags = O_RDWR | O_NOCTTY
    #endif

    #if os(Linux)
    masterFD = libc_posix_openpt(flags)
    #else
    masterFD = posix_openpt(flags)
    #endif
    guard masterFD >= 0 else {
        perror("posix_openpt")
        return nil
    }
    let grantResult: Int32
    #if os(Linux)
    grantResult = libc_grantpt(masterFD)
    #else
    grantResult = grantpt(masterFD)
    #endif
    if grantResult != 0 {
        perror("grantpt")
        close(masterFD)
        return nil
    }
    let unlockResult: Int32
    #if os(Linux)
    unlockResult = libc_unlockpt(masterFD)
    #else
    unlockResult = unlockpt(masterFD)
    #endif
    if unlockResult != 0 {
        perror("unlockpt")
        close(masterFD)
        return nil
    }

    let slaveName: UnsafeMutablePointer<CChar>?
    #if os(Linux)
    slaveName = libc_ptsname(masterFD)
    #else
    slaveName = ptsname(masterFD)
    #endif
    guard let slaveName else {
        perror("ptsname")
        close(masterFD)
        return nil
    }
    slaveFD = open(slaveName, O_RDWR | O_NOCTTY)
    guard slaveFD >= 0 else {
        perror("open slave pty")
        close(masterFD)
        return nil
    }

    let pid = libc_fork()

    if pid < 0 {
        perror("fork")
        close(masterFD)
        close(slaveFD)
        return nil
    }

    if pid == 0 {
        close(masterFD)
        if setsid() < 0 {
            perror("setsid")
            _exit(127)
        }
        #if os(Linux)
        _ = ioctl(slaveFD, UInt(TIOCSCTTY), 0)
        #else
        _ = ioctl(slaveFD, TIOCSCTTY, 0)
        #endif
        _ = dup2(slaveFD, STDIN_FILENO)
        _ = dup2(slaveFD, STDOUT_FILENO)
        _ = dup2(slaveFD, STDERR_FILENO)
        if slaveFD > STDERR_FILENO {
            close(slaveFD)
        }
        if chdir(workspace) != 0 {
            perror("chdir")
            _exit(127)
        }
        if getenv("TERM") == nil {
            _ = setenv("TERM", "xterm-256color", 1)
        }
        for (key, value) in environment {
            _ = setenv(key, value, 1)
        }

        let cStrings = ([executable] + arguments).map { strdup($0) }
        var argv: [UnsafeMutablePointer<CChar>?] = cStrings + [nil]
        execvp(executable, &argv)
        perror("execvp")
        for pointer in cStrings {
            if let pointer {
                free(pointer)
            }
        }
        _exit(127)
    }

    close(slaveFD)
    return (masterFD, pid)
}

func spawnShellShell(repoRoot: String, workspace: String, shellPath: String) -> (masterFD: Int32, pid: pid_t)? {
    let path = resolveShellPath(shellPath)
    return spawnPTYProcess(workspace: workspace, executable: path, arguments: ["-l"])
}

func spawnAgentTuiShell(repoRoot: String, agentId: String, workspace: String? = nil, yolo: Bool = false) -> (masterFD: Int32, pid: pid_t)? {
    let commandPath = URL(fileURLWithPath: repoRoot).appendingPathComponent("ae").path
    guard FileManager.default.isExecutableFile(atPath: commandPath) else {
        return nil
    }
    var environment: [String: String] = [:]
    if let workspace {
        environment["AELAB_AGENT_WORKSPACE"] = workspace
    }
    return spawnPTYProcess(workspace: repoRoot, executable: commandPath, arguments: [agentId, yolo ? "yolo" : "tui"], environment: environment)
}

func resolveProjectToolPath(_ name: String) -> String? {
    switch name {
    case "nvim", "lazygit":
        return resolveExecutablePath(name)
    default:
        return nil
    }
}

func spawnProjectToolShell(workspace: String, toolName: String) throws -> (masterFD: Int32, pid: pid_t) {
    guard let toolPath = resolveProjectToolPath(toolName) else {
        throw TerminalSpawnFailure.message("\(toolName) not found in PATH\n")
    }
    guard let spawned = spawnPTYProcess(workspace: workspace, executable: toolPath, arguments: []) else {
        throw TerminalSpawnFailure.message("failed to launch \(toolName)\n")
    }
    return spawned
}

func spawnTmuxAttachShell(repoRoot: String, sessionName: String, windowId: String?) -> (masterFD: Int32, pid: pid_t)? {
    guard let tmuxPath = resolveTmuxPath() else {
        return nil
    }
    if let windowId, !windowId.isEmpty {
        let selectProcess = Process()
        selectProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        selectProcess.arguments = tmuxSocketArguments() + ["select-window", "-t", windowId]
        try? selectProcess.run()
        selectProcess.waitUntilExit()
    }
    return spawnPTYProcess(workspace: repoRoot, executable: "/usr/bin/env", arguments: ["-u", "TMUX", tmuxPath] + tmuxSocketArguments() + ["attach-session", "-t", sessionName])
}

func launchModeName(_ mode: TerminalLaunchMode) -> String {
    switch mode {
    case .shell:
        return "shell"
    case .agentTui:
        return "agentTui"
    case .agentYoloTui:
        return "agentYoloTui"
    case .projectTool(let name):
        return name
    case .tmuxAttach:
        return "tmuxAttach"
    }
}

func discoverTmuxSessions() -> TmuxDiscovery {
    guard let tmuxPath = resolveTmuxPath() else {
        return TmuxDiscovery(sessions: [], tmuxPath: nil, socketArguments: tmuxSocketArguments(), exitStatus: nil, errorOutput: "tmux not found")
    }
    let process = Process()
    let pipe = Pipe()
    let errorPipe = Pipe()
    let socketArguments = tmuxSocketArguments()
    let command = ([tmuxPath] + socketArguments + ["list-sessions", "-F", "#{session_name}|#{session_attached}|#{session_windows}"])
        .map(shellQuote)
        .joined(separator: " ")
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", command]
    process.standardOutput = pipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return TmuxDiscovery(sessions: [], tmuxPath: tmuxPath, socketArguments: socketArguments, exitStatus: nil, errorOutput: String(describing: error))
    }
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let rawOutput = String(data: data, encoding: .utf8)
    guard process.terminationStatus == 0 else {
        return TmuxDiscovery(sessions: [], tmuxPath: tmuxPath, socketArguments: socketArguments, exitStatus: process.terminationStatus, errorOutput: errorOutput)
    }

    guard let output = rawOutput else {
        return TmuxDiscovery(sessions: [], tmuxPath: tmuxPath, socketArguments: socketArguments, exitStatus: process.terminationStatus, errorOutput: errorOutput)
    }
    let sessions: [TmuxSession] = output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return TmuxSession(
                name: fields[0],
                attached: Int(fields[1]) ?? 0,
                windows: Int(fields[2]) ?? 0
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return TmuxDiscovery(sessions: sessions, tmuxPath: tmuxPath, socketArguments: socketArguments, exitStatus: process.terminationStatus, errorOutput: errorOutput)
}

func listTmuxSessions() -> [TmuxSession] {
    discoverTmuxSessions().sessions
}

func jsonResponseObject(_ object: [String: Any], status: String = "200 OK", headOnly: Bool = false) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return response(status: status, contentType: "application/json; charset=utf-8", body: body, headOnly: headOnly)
}

func createTmuxWindow(repoRoot: String, body: Data) -> (status: String, object: [String: Any]) {
    guard let tmuxPath = resolveTmuxPath() else {
        return ("503 Service Unavailable", ["ok": false, "error": "tmux not found"])
    }
    guard
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let sessionName = payload["session"] as? String,
        let terminalPath = payload["terminalPath"] as? String,
        !sessionName.isEmpty
    else {
        return ("400 Bad Request", ["ok": false, "error": "bad tmux window payload"])
    }

    let availableSessions = Set(listTmuxSessions().map(\.name))
    guard availableSessions.contains(sessionName) else {
        return ("404 Not Found", ["ok": false, "error": "tmux session not found"])
    }

    let context = terminalContext(repoRoot: repoRoot, requestPath: terminalPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: context.workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
        return ("400 Bad Request", ["ok": false, "error": "workspace not found", "workspace": context.workspace])
    }
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tmuxPath)
    process.arguments = tmuxSocketArguments() + ["new-window", "-P", "-F", "#{window_id}", "-t", sessionName, "-c", context.workspace]
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ("500 Internal Server Error", ["ok": false, "error": String(describing: error)])
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let windowId = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
        return ("500 Internal Server Error", ["ok": false, "error": errorOutput.isEmpty ? "tmux new-window failed" : errorOutput])
    }
    if !windowId.isEmpty {
        let selectProcess = Process()
        selectProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        selectProcess.arguments = tmuxSocketArguments() + ["select-window", "-t", windowId]
        try? selectProcess.run()
        selectProcess.waitUntilExit()
    }

    return ("200 OK", [
        "ok": true,
        "path": windowId.isEmpty ? "/tty/tmux/\(urlEncodePathSegment(sessionName))/" : "/tty/tmux/\(urlEncodePathSegment(sessionName))/\(urlEncodePathSegment(windowId))/",
        "windowId": windowId,
        "workspace": context.workspace
    ])
}

func terminateSession(pid: pid_t) {
    _ = kill(pid, SIGHUP)
    _ = kill(pid, SIGTERM)

    var status: Int32 = 0
    for _ in 0..<20 {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return
        }
        if result < 0, errno != EINTR {
            break
        }
        usleep(100_000)
    }

    _ = kill(pid, SIGKILL)
    for _ in 0..<10 {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return
        }
        if result < 0, errno != EINTR {
            break
        }
        usleep(100_000)
    }
}

func jsonString(_ value: String) -> String {
    if
        let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
        let text = String(data: data, encoding: .utf8)
    {
        return String(text.dropFirst().dropLast())
    }
    return "\"\""
}

func outputMessage(_ data: Data) -> Data {
    Data(#"{"type":"output","data":""#.utf8) +
        data.base64EncodedData() +
        Data(#""}"#.utf8)
}

func sessionStatusMessage(key: String, pinned: Bool, connectedClients: Int) -> Data {
    let text = #"{"type":"session","key":\#(jsonString(key)),"pinned":\#(pinned ? "true" : "false"),"persistent":\#(pinned ? "true" : "false"),"clients":\#(connectedClients)}"#
    return Data(text.utf8)
}

final class TerminalSession {
    let key: String
    let masterFD: Int32
    let pid: pid_t
    let metadata: SessionMetadata

    private let lock = NSLock()
    private let sendLock = NSLock()
    private var clientFDs: Set<Int32> = []
    private var pinnedValue: Bool
    private var closed = false
    private var scrollback = Data()
    private let maxScrollbackBytes = 512 * 1024
    private let onClose: (TerminalSession) -> Void

    init(key: String, masterFD: Int32, pid: pid_t, metadata: SessionMetadata, pinned: Bool, onClose: @escaping (TerminalSession) -> Void) {
        self.key = key
        self.masterFD = masterFD
        self.pid = pid
        self.metadata = metadata
        self.pinnedValue = pinned
        self.onClose = onClose
    }

    var pinned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinnedValue
    }

    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clientFDs.count
    }

    func startReader() {
        Thread.detachNewThread { [weak self] in
            self?.readerLoop()
        }
    }

    func attach(fd: Int32) {
        let backlog: Data
        let status: Data
        lock.lock()
        clientFDs.insert(fd)
        backlog = scrollback
        status = sessionStatusMessage(key: key, pinned: pinnedValue, connectedClients: clientFDs.count)
        lock.unlock()

        if !backlog.isEmpty {
            sendFrame(fd: fd, opcode: 0x1, payload: outputMessage(backlog))
        }
        sendFrame(fd: fd, opcode: 0x1, payload: status)
    }

    func detach(fd: Int32) {
        var shouldKill = false
        lock.lock()
        clientFDs.remove(fd)
        shouldKill = !pinnedValue && clientFDs.isEmpty && !closed
        lock.unlock()
        if shouldKill {
            kill()
        }
    }

    func writeInput(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = write(masterFD, base.advanced(by: written), data.count - written)
                if result <= 0 {
                    break
                }
                written += result
            }
        }
    }

    func resize(cols: Int32, rows: Int32) {
        setWindowSize(fd: masterFD, cols: cols, rows: rows)
    }

    func sendFrame(fd: Int32, opcode: UInt8, payload: Data) {
        sendLock.lock()
        sendWebSocketFrame(fd: fd, opcode: opcode, payload: payload)
        sendLock.unlock()
    }

    func pin() {
        setPinned(true)
    }

    func unpin() {
        setPinned(false)
    }

    func kill() {
        var shouldClose = false
        lock.lock()
        if !closed {
            closed = true
            shouldClose = true
        }
        lock.unlock()
        guard shouldClose else { return }
        close(masterFD)
        terminateSession(pid: pid)
        onClose(self)
    }

    func dictionary() -> [String: Any] {
        lock.lock()
        let pinned = pinnedValue
        let clients = clientFDs.count
        lock.unlock()
        var result: [String: Any] = [
            "key": key,
            "path": key,
            "pinned": pinned,
            "clients": clients,
            "workspace": metadata.workspace,
            "launchMode": launchModeName(metadata.launchMode)
        ]
        if let agentId = metadata.agentId {
            result["agentId"] = agentId
        }
        if let projectTitle = metadata.projectTitle {
            result["projectTitle"] = projectTitle
        }
        return result
    }

    private func setPinned(_ pinned: Bool) {
        let status: Data
        let fds: [Int32]
        var shouldKill = false
        lock.lock()
        pinnedValue = pinned
        fds = Array(clientFDs)
        status = sessionStatusMessage(key: key, pinned: pinnedValue, connectedClients: clientFDs.count)
        shouldKill = !pinnedValue && clientFDs.isEmpty && !closed
        lock.unlock()

        for fd in fds {
            sendFrame(fd: fd, opcode: 0x1, payload: status)
        }
        if shouldKill {
            kill()
        }
    }

    private func readerLoop() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            let output = Data(buffer.prefix(Int(count)))
            let message = outputMessage(output)
            let fds: [Int32]
            lock.lock()
            scrollback.append(output)
            if scrollback.count > maxScrollbackBytes {
                scrollback.removeFirst(scrollback.count - maxScrollbackBytes)
            }
            fds = Array(clientFDs)
            lock.unlock()
            for fd in fds {
                sendFrame(fd: fd, opcode: 0x1, payload: message)
            }
        }
        kill()
    }
}

final class SessionRegistry {
    private let lock = NSLock()
    private var pinnedSessions: [String: TerminalSession] = [:]
    private var pinnedOrder: [String] = []

    func session(for key: String, context: TerminalContext, config: Config) throws -> TerminalSession {
        lock.lock()
        if let existing = pinnedSessions[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let spawned = try spawnSession(context: context, config: config)
        let metadata = SessionMetadata(agentId: context.agentId, projectTitle: context.projectTitle, workspace: context.workspace, launchMode: context.launchMode)
        let session = TerminalSession(key: key, masterFD: spawned.masterFD, pid: spawned.pid, metadata: metadata, pinned: false) { [weak self] closedSession in
            self?.remove(closedSession)
        }
        session.resize(cols: 120, rows: 34)
        session.startReader()
        return session
    }

    func promote(_ session: TerminalSession) {
        lock.lock()
        if pinnedSessions[session.key] == nil {
            pinnedOrder.append(session.key)
        }
        pinnedSessions[session.key] = session
        lock.unlock()
        session.pin()
    }

    func remove(_ session: TerminalSession) {
        lock.lock()
        if pinnedSessions[session.key] === session {
            pinnedSessions.removeValue(forKey: session.key)
            pinnedOrder.removeAll { $0 == session.key }
        }
        lock.unlock()
    }

    func pinnedDictionaries() -> [[String: Any]] {
        lock.lock()
        let ordered = pinnedOrder.compactMap { pinnedSessions[$0] }
        lock.unlock()
        return ordered.map { $0.dictionary() }
    }

    private func spawnSession(context: TerminalContext, config: Config) throws -> TerminalSpawnResult {
        let spawned: (masterFD: Int32, pid: pid_t)?
        switch context.launchMode {
        case .shell:
            spawned = spawnShellShell(repoRoot: config.repoRoot, workspace: context.workspace, shellPath: config.shellPath)
        case .agentTui, .agentYoloTui:
            guard let agentId = context.agentId else {
                throw TerminalSpawnFailure.message("agent id missing\n")
            }
            let workspace = context.targetKind == .project ? context.workspace : nil
            let yolo: Bool
            if case .agentYoloTui = context.launchMode {
                yolo = true
            } else {
                yolo = false
            }
            spawned = spawnAgentTuiShell(repoRoot: config.repoRoot, agentId: agentId, workspace: workspace, yolo: yolo)
        case .projectTool(let name):
            let projectTool = try spawnProjectToolShell(workspace: context.workspace, toolName: name)
            return TerminalSpawnResult(masterFD: projectTool.masterFD, pid: projectTool.pid)
        case .tmuxAttach(let sessionName, let windowId):
            spawned = spawnTmuxAttachShell(repoRoot: config.repoRoot, sessionName: sessionName, windowId: windowId)
        }
        guard let spawned else {
            throw TerminalSpawnFailure.message("shell failed\n")
        }
        return TerminalSpawnResult(masterFD: spawned.masterFD, pid: spawned.pid)
    }
}

func websocketHandshake(fd: Int32, request: HTTPRequest) -> Bool {
    guard let clientKey = request.headers["sec-websocket-key"] else { return false }
    let acceptValue = websocketAcceptValue(clientKey: clientKey)
    let responseText = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptValue)\r\n\r\n"
    sendAll(fd: fd, data: Data(responseText.utf8))
    return true
}

func loadTerminalTemplate(repoRoot: String) -> String? {
    let path = URL(fileURLWithPath: repoRoot).appendingPathComponent("infra/core/tty.html").path
    return try? String(contentsOfFile: path, encoding: .utf8)
}

struct TTYButton {
    let key: String
    let label: String
}

func ttyButtons(repoRoot: String) -> [TTYButton] {
    repoConfigEntries(repoRoot: repoRoot, section: "tty-buttons").map {
        TTYButton(key: $0.key, label: $0.value)
    }
}

func renderTTYButtons(repoRoot: String) -> String {
    let buttons = ttyButtons(repoRoot: repoRoot)
    guard !buttons.isEmpty else {
        return #"        <span style="color:var(--muted);font-size:13px;padding:0 4px;white-space:nowrap;line-height:36px">configure buttons in repo.ini</span>"#
    }
    return buttons.map { button in
        let label = htmlEscape(button.label)
        let key = htmlEscape(button.key)
        let pressed = button.key == "alt" ? #" aria-pressed="false""# : ""
        return #"        <button class="mobile-key" data-mobile-key="\#(key)" type="button" tabindex="-1"\#(pressed) aria-label="\#(label)" title="\#(label)">\#(label)</button>"#
    }.joined(separator: "\n")
}

func terminalPageHTML(repoRoot: String, agentId: String?, projectTitle: String?, workspace: String) -> Data {
    let title: String
    if let agentId {
        title = "aelab tty / \(agentId)"
    } else if let projectTitle {
        title = "aelab tty / \(projectTitle)"
    } else {
        title = "aelab tty"
    }
    let hostLabel = ProcessInfo.processInfo.hostName.replacingOccurrences(of: #"\.local$"#, with: "", options: .regularExpression)

    guard var page = loadTerminalTemplate(repoRoot: repoRoot) else {
        return Data("tty template not found\n".utf8)
    }

    page = page
        .replacingOccurrences(of: "__PAGE_TITLE__", with: htmlEscape(title))
        .replacingOccurrences(of: "__HOST_LABEL__", with: htmlEscape(hostLabel))
        .replacingOccurrences(of: "__WORKSPACE_LABEL__", with: htmlEscape(workspace))
        .replacingOccurrences(of: "__TTY_BUTTONS__", with: renderTTYButtons(repoRoot: repoRoot))
    return Data(page.utf8)
}

func handleWebSocketSession(fd: Int32, requestPath: String, config: Config, registry: SessionRegistry) {
    let context = terminalContext(repoRoot: config.repoRoot, requestPath: requestPath)
    let key = normalizedTerminalPath(for: requestPath)
    let session: TerminalSession
    do {
        session = try registry.session(for: key, context: context, config: config)
    } catch TerminalSpawnFailure.message(let message) {
        log("session spawn failed for \(requestPath): \(message.trimmingCharacters(in: .whitespacesAndNewlines))", level: "error")
        sendWebSocketFrame(fd: fd, opcode: 0x1, payload: outputMessage(Data(message.utf8)))
        return
    } catch {
        log("session spawn failed for \(requestPath): \(error)", level: "error")
        sendWebSocketFrame(fd: fd, opcode: 0x1, payload: outputMessage(Data("shell failed\n".utf8)))
        return
    }

    if let size = initialTerminalSize(for: requestPath) {
        session.resize(cols: size.cols, rows: size.rows)
    }
    session.attach(fd: fd)
    log("ws connect: \(requestPath)")
    defer {
        session.detach(fd: fd)
        sendWebSocketFrame(fd: fd, opcode: 0x8, payload: Data())
        log("ws close:   \(requestPath)")
    }

    var socketBuffer = Data()
    var socketReadBuffer = [UInt8](repeating: 0, count: 8192)
    var running = true

    while running {
        var pollfdValue = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        let result = poll(&pollfdValue, 1, -1)
        if result < 0 {
            if errno == EINTR {
                continue
            }
            break
        }

        if (pollfdValue.revents & Int16(POLLIN)) != 0 {
            let count = recv(fd, &socketReadBuffer, socketReadBuffer.count, 0)
            if count <= 0 {
                break
            }
            socketBuffer.append(socketReadBuffer, count: Int(count))

            while let frame = parseWebSocketFrame(from: &socketBuffer) {
                switch decodeWebSocketMessage(frame) {
                case .input(let data):
                    session.writeInput(data)
                case .resize(let cols, let rows):
                    session.resize(cols: cols, rows: rows)
                case .pin:
                    if case .tmuxAttach = session.metadata.launchMode { break }
                    registry.promote(session)
                case .unpin:
                    if case .tmuxAttach = session.metadata.launchMode { break }
                    session.unpin()
                    registry.remove(session)
                case .kill:
                    session.kill()
                    running = false
                case .ping(let payload):
                    session.sendFrame(fd: fd, opcode: 0xA, payload: payload)
                case .close:
                    running = false
                case .unknown:
                    break
                }
                if !running { break }
            }
        }

        if (pollfdValue.revents & Int16(POLLHUP | POLLERR)) != 0 {
            break
        }
    }
}

func sessionsJSON(registry: SessionRegistry) -> Data {
    let tmuxDiscovery = discoverTmuxSessions()
    let object: [String: Any] = [
        "labSessions": registry.pinnedDictionaries(),
        "tmuxSessions": tmuxDiscovery.sessions.map { $0.dictionary() }
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data(#"{"labSessions":[],"tmuxSessions":[]}"#.utf8)
}

func lookPath(repoRoot: String) -> URL {
    URL(fileURLWithPath: repoRoot)
        .appendingPathComponent("infra/generated", isDirectory: true)
        .appendingPathComponent("look.json")
}

func readLook(repoRoot: String) -> [String: Any] {
    let url = lookPath(repoRoot: repoRoot)
    guard
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return [:]
    }
    var result: [String: Any] = [:]
    if let theme = object["theme"] as? String, isTheme(theme) {
        result["theme"] = theme
    }
    for key in ["tintByHost", "terminalBgByHost", "terminalBgByPath"] {
        if let rawValues = object[key] as? [String: Any] {
            var values: [String: String] = [:]
            for (scope, value) in rawValues {
                guard isLookScope(scope), let color = value as? String, isHexColor(color) else {
                    continue
                }
                values[scope] = color
            }
            if !values.isEmpty {
                result[key] = values
            }
        }
    }
    return result
}

func writeLook(repoRoot: String, values: [String: Any]) {
    let url = lookPath(repoRoot: repoRoot)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: [.atomic])
    }
}

func isHexColor(_ value: String) -> Bool {
    value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
}

func isTheme(_ value: String) -> Bool {
    value == "dark" || value == "light"
}

func isLookScope(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 4096 && value.rangeOfCharacter(from: .controlCharacters) == nil
}

func lookJSON(repoRoot: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: readLook(repoRoot: repoRoot), options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
}

func updateLook(repoRoot: String, body: Data) -> Bool {
    guard
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
        return false
    }
    var values = readLook(repoRoot: repoRoot)
    if let theme = object["theme"] as? String, isTheme(theme) {
        values["theme"] = theme
    }
    for key in ["tintByHost", "terminalBgByHost", "terminalBgByPath"] {
        if let updates = object[key] as? [String: Any] {
            var stored = values[key] as? [String: String] ?? [:]
            for (scope, rawValue) in updates {
                guard isLookScope(scope) else {
                    continue
                }
                if rawValue is NSNull {
                    stored.removeValue(forKey: scope)
                    continue
                }
                if let value = rawValue as? String, isHexColor(value) {
                    stored[scope] = value
                }
            }
            if stored.isEmpty {
                values.removeValue(forKey: key)
            } else {
                values[key] = stored
            }
        }
    }
    writeLook(repoRoot: repoRoot, values: values)
    return true
}

func handleConnection(fd: Int32, config: Config, registry: SessionRegistry) {
    defer { close(fd) }

    guard let requestData = readHTTPRequest(fd: fd), let request = parseHTTPRequest(requestData) else {
        sendAll(fd: fd, data: response(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("bad request\n".utf8)))
        return
    }

    let cleanPath = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? request.path
    let headOnly = request.method == "HEAD"
    guard request.method == "GET" || request.method == "HEAD" || request.method == "POST" else {
        sendAll(fd: fd, data: response(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("method not allowed\n".utf8), headOnly: headOnly))
        return
    }

    if cleanPath == "/health" {
        sendAll(fd: fd, data: response(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("ok\n".utf8), headOnly: headOnly))
        return
    }

    if cleanPath == "/sessions" || cleanPath == "/tty/sessions" {
        sendAll(fd: fd, data: response(status: "200 OK", contentType: "application/json; charset=utf-8", body: sessionsJSON(registry: registry), headOnly: headOnly))
        return
    }

    if cleanPath == "/tmux/window" || cleanPath == "/tty/tmux/window" {
        guard request.method == "POST" else {
            sendAll(fd: fd, data: response(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("method not allowed\n".utf8), headOnly: headOnly))
            return
        }
        let result = createTmuxWindow(repoRoot: config.repoRoot, body: request.body)
        sendAll(fd: fd, data: jsonResponseObject(result.object, status: result.status, headOnly: headOnly))
        return
    }

    if cleanPath == "/look" || cleanPath == "/tty/look" {
        if request.method == "POST" {
            guard updateLook(repoRoot: config.repoRoot, body: request.body) else {
                sendAll(fd: fd, data: response(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("bad look payload\n".utf8), headOnly: headOnly))
                return
            }
            sendAll(fd: fd, data: noContentResponse())
            return
        }
        sendAll(fd: fd, data: response(status: "200 OK", contentType: "application/json; charset=utf-8", body: lookJSON(repoRoot: config.repoRoot), headOnly: headOnly))
        return
    }

    let isWebSocketUpgrade = request.headers["upgrade"]?.lowercased() == "websocket"
    if isWebSocketUpgrade && request.headers["sec-websocket-key"] != nil {
        guard websocketHandshake(fd: fd, request: request) else {
            sendAll(fd: fd, data: response(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("bad websocket request\n".utf8), headOnly: headOnly))
            return
        }
        handleWebSocketSession(fd: fd, requestPath: request.path, config: config, registry: registry)
        return
    }

    let context = terminalContext(repoRoot: config.repoRoot, requestPath: request.path)
    let html = terminalPageHTML(repoRoot: config.repoRoot, agentId: context.agentId, projectTitle: context.projectTitle, workspace: context.workspace)
    sendAll(fd: fd, data: response(status: "200 OK", contentType: "text/html; charset=utf-8", body: html, headOnly: headOnly))
}

let config = parseArgs()
let registry = SessionRegistry()
signal(SIGPIPE, SIG_IGN)
let serverFD = makeServerSocket(host: config.host, port: config.port)
log("tty server listening on \(config.host):\(config.port) (repo: \(config.repoRoot))")

while true {
    let clientFD = accept(serverFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        perror("accept")
        log("accept failed: errno=\(errno)", level: "error")
        continue
    }
    Thread.detachNewThread {
        handleConnection(fd: clientFD, config: config, registry: registry)
    }
}

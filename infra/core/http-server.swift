#!/usr/bin/env swift

import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct Config {
    let repoRoot: String
    let host: String
    let port: UInt16
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

final class IndexPageCache {
    private let repoRoot: String
    private let refreshInterval: TimeInterval
    private let lock = NSLock()
    private var html: Data?
    private var lastRefresh = Date.distantPast
    private var refreshInFlight = false

    init(repoRoot: String, refreshInterval: TimeInterval = 2.0) {
        self.repoRoot = repoRoot
        self.refreshInterval = refreshInterval
        self.html = loadIndexHTML(repoRoot: repoRoot)
    }

    func page() -> (html: Data?, renderError: String?) {
        lock.lock()
        let cached = html
        let shouldRefresh = Date().timeIntervalSince(lastRefresh) >= refreshInterval && !refreshInFlight
        if shouldRefresh {
            refreshInFlight = true
            lastRefresh = Date()
        }
        lock.unlock()

        if cached == nil {
            let result = renderIndex(repoRoot: repoRoot)
            guard result.status == 0 else {
                finishRefresh(html: nil)
                return (nil, result.output)
            }
            let rendered = loadIndexHTML(repoRoot: repoRoot)
            finishRefresh(html: rendered)
            return (rendered, nil)
        }

        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [repoRoot] in
                let result = renderIndex(repoRoot: repoRoot)
                self.finishRefresh(html: result.status == 0 ? loadIndexHTML(repoRoot: repoRoot) : nil)
            }
        }

        return (cached, nil)
    }

    private func finishRefresh(html rendered: Data?) {
        lock.lock()
        if let rendered {
            html = rendered
        }
        refreshInFlight = false
        lock.unlock()
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

func usage() -> Never {
    fputs("usage: http-server.swift --repo-root <path> [--bind 127.0.0.1] [--port 2108]\n", stderr)
    exit(1)
}

func parseArgs() -> Config {
    var repoRoot: String?
    var host = "127.0.0.1"
    var port: UInt16 = 2108

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
        case "-h", "--help", "help":
            usage()
        default:
            usage()
        }
        index += 1
    }

    guard let repoRoot else { usage() }
    return Config(repoRoot: repoRoot, host: host, port: port)
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

func renderIndex(repoRoot: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [URL(fileURLWithPath: repoRoot).appendingPathComponent("infra/commands/render.sh").path, "front"]
    process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    } catch {
        return (1, "failed to render index page: \(error)\n")
    }
}

func loadIndexHTML(repoRoot: String) -> Data? {
    let path = URL(fileURLWithPath: repoRoot).appendingPathComponent("infra/generated/index.html").path
    return FileManager.default.contents(atPath: path)
}

func localHostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    if gethostname(&buffer, buffer.count) == 0 {
        let name = String(cString: buffer)
        if let shortName = name.split(separator: ".").first, !shortName.isEmpty {
            return String(shortName)
        }
        return name
    }
    return "localhost"
}

func redirectHostName(headers: [String: String]) -> String {
    if let hostHeader = headers["host"] {
        let host = hostHeader.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        if let host, !host.isEmpty {
            return host
        }
    }
    return localHostName()
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
    headers += "Content-Length: \(body.count)\r\n"
    headers += "Connection: close\r\n"
    headers += "\r\n"

    var data = Data(headers.utf8)
    if !headOnly {
        data.append(body)
    }
    return data
}

func redirectResponse(location: String, headOnly: Bool = false) -> Data {
    let body = Data("redirecting\n".utf8)
    var headers = "HTTP/1.1 302 Found\r\n"
    headers += "Location: \(location)\r\n"
    headers += "Content-Type: text/plain; charset=utf-8\r\n"
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

func handleConnection(fd: Int32, config: Config, indexPageCache: IndexPageCache) {
    defer { close(fd) }

    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0 else { return }

    let request = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    let requestLines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let line = requestLines.first else { return }

    var headers: [String: String] = [:]
    for line in requestLines.dropFirst() {
        if line.isEmpty { break }
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        headers[key] = value
    }

    let parts = line.split(separator: " ")
    guard parts.count >= 2 else {
        sendAll(fd: fd, data: response(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("bad request\n".utf8)))
        return
    }

    let method = String(parts[0])
    let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    let headOnly = method == "HEAD"

    guard method == "GET" || method == "HEAD" else {
        sendAll(fd: fd, data: response(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("method not allowed\n".utf8), headOnly: headOnly))
        return
    }

    if rawPath == "/health" {
        sendAll(fd: fd, data: response(status: "200 OK", contentType: "text/plain; charset=utf-8", body: Data("ok\n".utf8), headOnly: headOnly))
        return
    }

    if rawPath == "/tty" {
        sendAll(fd: fd, data: redirectResponse(location: "/tty/", headOnly: headOnly))
        return
    }

    guard rawPath == "/" || rawPath == "/index.html" else {
        sendAll(fd: fd, data: response(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8), headOnly: headOnly))
        return
    }

    let page = indexPageCache.page()
    guard let html = page.html else {
        let message = page.renderError ?? "index page not found\n"
        sendAll(fd: fd, data: response(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data(message.utf8), headOnly: headOnly))
        return
    }

    sendAll(fd: fd, data: response(status: "200 OK", contentType: "text/html; charset=utf-8", body: html, headOnly: headOnly))
}

let config = parseArgs()
let indexPageCache = IndexPageCache(repoRoot: config.repoRoot)
let serverFD = makeServerSocket(host: config.host, port: config.port)
log("http server listening on \(config.host):\(config.port) (repo: \(config.repoRoot))")

while true {
    let clientFD = accept(serverFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        perror("accept")
        log("accept failed: errno=\(errno)", level: "error")
        continue
    }
    handleConnection(fd: clientFD, config: config, indexPageCache: indexPageCache)
}

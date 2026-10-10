// Supervise the broker and compatibility command for one direct-controller session.
import Darwin
import Foundation

struct LaunchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func tick(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

func stop(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date(timeIntervalSinceNow: 3)
    while process.isRunning && Date() < deadline { tick(0.02) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

// The broker prints one small readiness/probe object. Bound both time and size
// so a failed helper cannot hang the launcher or fill memory.
func readJSON(_ pipe: Pipe, timeout: Double) throws -> [String: Any] {
    var data = Data()
    let fd = pipe.fileHandleForReading.fileDescriptor
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 50)
        if result < 0 && errno != EINTR {
            throw LaunchError("Cannot read controller service readiness")
        }
        if result > 0 {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &bytes, bytes.count)
            if n <= 0 { break }
            data.append(contentsOf: bytes.prefix(n))
            if data.count > 65536 { throw LaunchError("Controller service response too large") }
            if let newline = data.firstIndex(of: 10) {
                guard
                    let object = try JSONSerialization.jsonObject(with: data[..<newline])
                        as? [String: Any]
                else {
                    throw LaunchError("Invalid controller service response")
                }
                return object
            }
        }
        tick(0.001)
    }
    throw LaunchError("Controller service readiness timed out or exited")
}

func writeJSON(_ object: [String: Any], to path: URL) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let temporary = path.deletingLastPathComponent().appendingPathComponent(
        ".session-\(UUID().uuidString)")
    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw LaunchError("Cannot create controller session record") }
    defer {
        close(fd)
        try? FileManager.default.removeItem(at: temporary)
    }
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
    guard rename(temporary.path, path.path) == 0 else {
        throw LaunchError("Cannot save controller session record")
    }
}

func execute(_ command: [String], environment: [String: String]) throws -> Never {
    for key in ProcessInfo.processInfo.environment.keys where environment[key] == nil {
        unsetenv(key)
    }
    for (key, value) in environment { setenv(key, value, 1) }
    let arguments = command.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    arguments.withUnsafeBufferPointer { _ = execvp(command[0], $0.baseAddress!) }
    throw LaunchError("Cannot run compatibility tool: \(String(cString: strerror(errno)))")
}

func main() throws -> Int32 {
    let command = Array(CommandLine.arguments.dropFirst())
    guard !command.isEmpty else { return 64 }
    let files = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    var environment = ProcessInfo.processInfo.environment
    // Never inherit credentials from another session. User options are retained.
    for key in ["DSB_PORT", "DSB_TOKEN", "DSB_RAW", "DSB_LIBRARY"] {
        environment.removeValue(forKey: key)
    }
    environment["DSB_SESSION"] = "1"
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try files.createDirectory(
        at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let candidate = environment["STEAM_COMPAT_APP_ID"] ?? environment["SteamAppId"] ?? ""
    let app =
        !candidate.isEmpty && candidate.utf8.allSatisfy({ (48...57).contains($0) })
        ? candidate : "unknown"
    let info = sessions.appendingPathComponent(app + ".json")
    let stats = sessions.appendingPathComponent(app + "-status.json")
    func bypass(_ reason: String) throws -> Never {
        try writeJSON(
            ["state": "bypass", "route": reason, "updated": Date().timeIntervalSince1970], to: stats
        )
        return try execute(command, environment: environment)
    }
    if environment["DSB_DISABLED"] == "1" { try bypass("disabled") }
    if environment["NOTPROTON_RAW_CONTROLLERS"] != "1" { try bypass("steam-input") }

    var brokerEnvironment = environment
    brokerEnvironment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    func probe() throws -> (eligible: Bool, usb: Int) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = root.appendingPathComponent("broker")
        process.arguments = ["--probe"]
        process.environment = brokerEnvironment
        process.standardOutput = pipe
        try process.run()
        defer { stop(process) }
        let state = try readJSON(pipe, timeout: 5)
        guard let eligible = state["eligible"] as? Bool, let usb = state["usb"] as? Int,
            state["bluetooth"] is Int
        else { throw LaunchError("Incomplete controller probe") }
        return (eligible, usb)
    }
    var state: (eligible: Bool, usb: Int)?
    var probeError: Error?
    for attempt in 0..<3 {
        do {
            state = try probe()
            probeError = nil
        } catch { probeError = error }
        if let state, state.eligible || state.usb > 0 { break }
        if attempt < 2 { tick(0.75) }
    }
    if let probeError { throw probeError }
    guard let state else { throw LaunchError("Cannot verify controller transport") }
    if !state.eligible {
        try bypass(state.usb > 0 ? "original-usb" : "no-single-bluetooth-dualsense")
    }

    let lock = open(
        sessions.appendingPathComponent("controller.lock").path,
        O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw LaunchError("Cannot lock controller session") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw LaunchError("Another direct-controller game owns the wireless bridge")
    }
    let logURL = sessions.appendingPathComponent(app + ".log")
    let logFD = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard logFD >= 0 else { throw LaunchError("Cannot open controller log") }
    let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
    var random = [UInt8](repeating: 0, count: 16)
    arc4random_buf(&random, random.count)
    let token = random.map { String(format: "%02x", $0) }.joined()
    let pcm = environment["DSB_PCM"] != "0"
    environment["DSB_PCM"] = pcm ? "1" : "0"
    var broker: Process?
    var brokerPipe: Pipe?
    var child: Process?
    let signals = [SIGTERM, SIGINT, SIGHUP].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
        source.setEventHandler {
            if let child, child.isRunning {
                kill(child.processIdentifier, value)
            } else {
                stop(broker)
                exit(128 + value)
            }
        }
        source.resume()
        return source
    }
    defer {
        signals.forEach { $0.cancel() }
        stop(broker)
        try? files.removeItem(at: info)
        try? log.close()
    }
    func startBroker(port: Int? = nil) throws -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = root.appendingPathComponent("broker")
        process.arguments =
            ["--token", token, "--parent", String(getpid()), "--status", stats.path]
            + (pcm ? ["--pcm"] : []) + (port.map { ["--port", String($0)] } ?? [])
        process.environment = brokerEnvironment
        process.standardOutput = pipe
        process.standardError = log
        broker = process
        brokerPipe = pipe
        try process.run()
        let ready = try readJSON(pipe, timeout: 8)
        guard ready["ready"] as? Bool == true, let assigned = ready["port"] as? Int,
            (1024...65535).contains(assigned), port == nil || port == assigned
        else {
            throw LaunchError("Controller transport did not become ready")
        }
        return assigned
    }
    let port = try startBroker()
    environment["DSB_PORT"] = String(port)
    environment["DSB_TOKEN"] = token
    environment["DSB_RAW"] = pcm ? "1:pcm" : "1"
    environment["DSB_LIBRARY"] = root.appendingPathComponent("bridge.dylib").path
    func saveSession() throws {
        try writeJSON(
            [
                "pid": getpid(), "brokerPid": broker!.processIdentifier,
                "started": Date().timeIntervalSince1970,
                "prefix": (environment["STEAM_COMPAT_DATA_PATH"] ?? "") + "/pfx",
                "environment": environment.filter {
                    ["DSB_PORT", "DSB_TOKEN", "DSB_RAW", "DSB_LIBRARY", "DSB_PCM"].contains($0.key)
                },
            ], to: info)
    }
    try saveSession()
    let game = Process()
    // Commands supplied by compat_run.sh are absolute. /usr/bin/env also
    // preserves normal PATH lookup for standalone use without shell parsing.
    game.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    game.arguments = command
    game.environment = environment
    child = game
    try game.run()
    var reconnects = [Date]()
    var disabled = false
    while game.isRunning {
        if !disabled, let service = broker, !service.isRunning {
            reconnects.removeAll { Date().timeIntervalSince($0) >= 60 }
            if service.terminationStatus == 10 && reconnects.count < 3 {
                reconnects.append(Date())
                let deadline = Date(timeIntervalSinceNow: 60)
                while game.isRunning && Date() < deadline {
                    tick(0.5)
                    guard let reconnected = try? probe(), reconnected.eligible else { continue }
                    do {
                        _ = try startBroker(port: port)
                        try saveSession()
                    } catch {
                        stop(broker)
                        disabled = true
                    }
                    break
                }
            }
            if broker?.isRunning != true {
                disabled = true
                fputs("DualSense transport stopped; reconnect and relaunch the game.\n", stderr)
            }
        }
        tick(0.05)
    }
    withExtendedLifetime(brokerPipe) {}
    return game.terminationReason == .exit ? game.terminationStatus : 128 + game.terminationStatus
}

do { exit(try main()) } catch {
    fputs("DualSense launch: \(error)\n", stderr)
    exit(70)
}

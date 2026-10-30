import Darwin
import Foundation

/// The outcome of running a tool to its end.
public struct ProcessResult: Sendable {
    public var code: Int32
    public var stderr: String
}

/// Runs external tools in a process group of their own, so that stopping one also stops what it started (yt-dlp starts
/// ffmpeg and aria2c, and its PyInstaller launcher has a child of its own). macOS has no equivalent of a Windows job
/// object: if VidFlow itself is killed, the group outlives it, so running groups are recorded in a file and
/// `killOrphans()` ends them at the next launch.
public enum ProcessRunner {
    private static let groups = Locked<Set<pid_t>>([])
    private static var pidFile: URL { AppPaths.dataDir.appendingPathComponent("running.pids") }

    /// Runs `exe` and streams stdout lines to `onLine` (on a background queue). Cancelling the task stops the group:
    /// SIGTERM first so yt-dlp and aria2c can leave resumable partial files, then SIGKILL.
    public static func run(_ exe: String, _ args: [String], environment: [String: String] = [:],
                           onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ProcessResult {
        try Task.checkCancellation()
        var out: [Int32] = [0, 0]
        var err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { throw POSIXError(.EMFILE) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // A new group led by the child; CLOEXEC_DEFAULT keeps VidFlow's other descriptors out of the tool.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)

        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        defer {
            envp.forEach { free($0) }
            argv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, exe, &actions, &attrs, argv, envp)
        close(out[1])
        close(err[1])
        guard spawned == 0 else {
            close(out[0])
            close(err[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .ENOENT)
        }
        track(pid)
        defer { untrack(pid) }

        let finished = Locked(false)
        let (stdoutFD, stderrFD) = (out[0], err[0])
        return try await withTaskCancellationHandler {
            async let stdoutDone: Void = readLines(stdoutFD, onLine)
            async let stderrText = readAll(stderrFD)
            let code = await waitForExit(pid)
            finished.current = true
            await stdoutDone
            let stderr = await stderrText
            try Task.checkCancellation()
            return ProcessResult(code: code, stderr: stderr)
        } onCancel: {
            stop(group: pid, finished: finished)
        }
    }

    /// Runs a tool and returns its stdout (nil when it can't be started or fails), for version checks and the like.
    public static func capture(_ exe: String, _ args: [String]) async -> String? {
        let lines = Locked<[String]>([])
        guard let result = try? await run(exe, args, onLine: { line in lines.withLock { $0.append(line) } }),
              result.code == 0 else { return nil }
        return lines.current.joined(separator: "\n")
    }

    private static func stop(group: pid_t, finished: Locked<Bool>) {
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if !finished.current { kill(-group, SIGKILL) }
        }
    }

    /// Ends every running tool, for when VidFlow quits.
    public static func stopAll() {
        for group in groups.current { kill(-group, SIGTERM) }
    }

    /// Waits until the tools have gone, escalating to SIGKILL (blocking; VidFlow is quitting).
    public static func waitForAllToExit(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if groups.current.allSatisfy({ kill(-$0, 0) != 0 }) { return }
            usleep(50_000)
        }
        for group in groups.current { kill(-group, SIGKILL) }
    }

    /// Groups left running by a VidFlow that crashed or was force-quit. Only ends processes that are still VidFlow's
    /// tools: a recorded id may have been reused by now.
    public static func killOrphans() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        let bin = AppPaths.binDir.path
        for pid in text.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasPrefix(bin) || path.contains("/Helpers/aria2c") {
                Log.info("Ending orphaned tool \(path) (\(pid))")
                kill(-pid, SIGTERM)
            }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func track(_ pid: pid_t) { record { $0.insert(pid) } }
    private static func untrack(_ pid: pid_t) { record { $0.remove(pid) } }

    private static func record(_ change: (inout Set<pid_t>) -> Void) {
        groups.withLock { set in
            change(&set)
            try? AppPaths.ensureDirectory(AppPaths.dataDir)
            try? set.map(String.init).joined(separator: "\n").write(to: pidFile, atomically: true, encoding: .utf8)
        }
    }

    /// aria2c and ffmpeg can use "\r" to rewrite a line, so both end a line.
    private static func readLines(_ fd: Int32, _ onLine: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                defer { close(fd) }
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    pending.append(contentsOf: buffer[0..<n])
                    while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                        let line = pending[pending.startIndex..<end]
                        if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                        pending = pending[pending.index(after: end)...]
                    }
                    // Without this the slice keeps its base index and old storage alive.
                    pending = Data(pending)
                }
                if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                done.resume()
            }
        }
    }

    /// Collected up to 16 KB from the end, which is where the error is.
    private static func readAll(_ fd: Int32) async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                defer { close(fd) }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    collected.append(contentsOf: buffer[0..<n])
                    if collected.count > 32 * 1024 { collected = Data(collected.suffix(16 * 1024)) }
                }
                done.resume(returning: String(decoding: collected.suffix(16 * 1024), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private static func waitForExit(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                let terminatedBySignal = status & 0x7f
                done.resume(returning: terminatedBySignal == 0 ? (status >> 8) & 0xff : 128 + terminatedBySignal)
            }
        }
    }
}

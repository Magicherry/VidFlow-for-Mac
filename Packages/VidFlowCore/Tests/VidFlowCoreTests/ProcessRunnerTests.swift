import Darwin
import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("ProcessRunner")
    struct ProcessRunnerTests {
        init() { TestEnv.prepare() }

        static func collect(_ exe: String, _ args: [String], environment: [String: String] = [:]) async throws -> (lines: [String], result: ProcessResult) {
            let lines = Locked<[String]>([])
            let result = try await ProcessRunner.run(exe, args, environment: environment) { line in lines.withLock { $0.append(line) } }
            return (lines.current, result)
        }

        /// The process group the runner has recorded in running.pids.
        static func recordedGroup() async throws -> pid_t {
            let file = AppPaths.dataDir.appendingPathComponent("running.pids")
            for _ in 0..<100 {
                if let text = try? String(contentsOf: file, encoding: .utf8), let pid = text.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }).first {
                    return pid
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TestError("the process was never recorded")
        }

        static func groupIsGone(_ pid: pid_t) async throws -> Bool {
            for _ in 0..<60 {
                if kill(-pid, 0) != 0, errno == ESRCH { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        @Test func streamsStdoutLinesAndReturnsTheExitCode() async throws {
            let (lines, result) = try await Self.collect("/bin/sh", ["-c", "echo one; echo two; printf three"])
            #expect(lines == ["one", "two", "three"])
            #expect(result.code == 0)
            #expect(result.stderr == "")
        }

        @Test func carriageReturnEndsALineToo() async throws {
            let (lines, _) = try await Self.collect("/bin/sh", ["-c", "printf 'a\\rb\\n\\n'"])
            #expect(lines == ["a", "b"])
        }

        @Test func nonZeroExitCodeAndStderr() async throws {
            let (lines, result) = try await Self.collect("/bin/sh", ["-c", "echo out; echo oops >&2; exit 3"])
            #expect(lines == ["out"])
            #expect(result.code == 3)
            #expect(result.stderr == "oops")
        }

        @Test func aProcessKilledBySignalReports128PlusTheSignal() async throws {
            let (_, result) = try await Self.collect("/bin/sh", ["-c", "kill -9 $$"])
            #expect(result.code == 128 + 9)
        }

        @Test func environmentIsMergedOverTheCurrentOne() async throws {
            let (lines, _) = try await Self.collect("/bin/sh", ["-c", "echo $VF_TEST_VALUE"], environment: ["VF_TEST_VALUE": "hello"])
            #expect(lines == ["hello"])
        }

        @Test func stdinIsEmpty() async throws {
            let (lines, result) = try await Self.collect("/bin/sh", ["-c", "cat; echo done"])
            #expect(lines == ["done"])
            #expect(result.code == 0)
        }

        @Test func missingExecutableThrows() async {
            await #expect(throws: (any Error).self) { _ = try await ProcessRunner.run("/nonexistent/tool", []) }
        }

        @Test func captureReturnsStdoutOrNil() async {
            #expect(await ProcessRunner.capture("/bin/echo", ["hi"]) == "hi")
            #expect(await ProcessRunner.capture("/bin/sh", ["-c", "echo x; exit 1"]) == nil)
            #expect(await ProcessRunner.capture("/nonexistent/tool", []) == nil)
        }

        @Test func alreadyCancelledTaskDoesNotStartAnything() async {
            let task = Task { () -> ProcessResult in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ProcessRunner.run("/bin/sleep", ["30"])
            }
            let started = ContinuousClock.now
            let outcome = await task.result
            #expect(throws: CancellationError.self) { try outcome.get() }
            #expect(ContinuousClock.now - started < .seconds(5))
        }

        @Test(.timeLimit(.minutes(1)))
        func cancellationKillsASleepQuickly() async throws {
            try await withDataDirAsync { _ in
                let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"]) }
                let group = try await Self.recordedGroup()
                #expect(kill(-group, 0) == 0)

                let started = ContinuousClock.now
                task.cancel()
                let outcome = await task.result
                let elapsed = ContinuousClock.now - started

                #expect(throws: CancellationError.self) { try outcome.get() }
                #expect(elapsed < .seconds(5), "took \(elapsed)")
                #expect(try await Self.groupIsGone(group))
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func cancellationKillsAChildTheToolSpawned() async throws {
            try await withDataDirAsync { _ in
                // sh stays up waiting for its background sleep: both must go, or the output pipe never closes.
                let task = Task { try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & wait"]) }
                let group = try await Self.recordedGroup()
                try await Task.sleep(for: .milliseconds(300)) // let sh start its child

                let started = ContinuousClock.now
                task.cancel()
                let outcome = await task.result
                let elapsed = ContinuousClock.now - started

                #expect(throws: CancellationError.self) { try outcome.get() }
                #expect(elapsed < .seconds(5), "took \(elapsed)")
                #expect(try await Self.groupIsGone(group), "a member of the process group survived")
            }
        }

        @Test func runningGroupsAreForgottenWhenTheyEnd() async throws {
            try await withDataDirAsync { dir in
                _ = try await Self.collect("/bin/sh", ["-c", "exit 0"])
                let text = (try? String(contentsOf: dir.appendingPathComponent("running.pids"), encoding: .utf8)) ?? ""
                #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

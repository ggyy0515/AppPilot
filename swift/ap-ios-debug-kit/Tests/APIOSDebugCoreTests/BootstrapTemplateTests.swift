import APIOSDebugCore
import Foundation
import Testing

@Test func bootstrapTemplateHasStableEntryPoint() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appending(path: "Templates/APIOSDebugBootstrap.swift")
    let bytes = try Data(contentsOf: url)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(SHA256.hexDigest(bytes) == "25b18c5af01a33b4cad50d5905174f0c55119db074922f0473f332ffe553524f")
    #expect(bytes.count > 1)
    #expect(bytes.last == 0x0a)
    #expect(bytes.dropLast().last != 0x0a)
    #expect(!text.contains("\r\n"))
    #expect(text.hasPrefix("#if DEBUG\n"))
    #expect(text.contains("static func start() async throws {"))
    #expect(text.contains("static func stop() async {"))
    #expect(text.contains("ProcessInfo.processInfo.environment[\"IOS_DEBUG_TOKEN\"]"))
}

#if os(macOS)
@Test func bootstrapTemplateSerializesConcurrentLifecycleOperations() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let templateURL = packageRoot.appending(path: "Templates/APIOSDebugBootstrap.swift")
    var template = try String(contentsOf: templateURL, encoding: .utf8)
    template =
        template
        .replacingOccurrences(of: "import Foundation\n", with: "")
        .replacingOccurrences(of: "import APIOSDebugCore\n", with: "")
        .replacingOccurrences(of: "import APIOSDebugKit\n", with: "")

    let harness = #"""
        import Foundation

        indirect enum JSONValue {
            case object([String: JSONValue])
            case string(String)
            case bool(Bool)
        }

        @MainActor protocol DebugStateProvider: AnyObject {
            func debugState() throws -> JSONValue
        }

        enum HarnessFailure: Error {
            case requested
        }

        @MainActor final class APIOSDebugRuntime {
            struct Configuration {
                init(bearerToken: String?) throws {}
            }

            static var startCount = 0
            static var stopCount = 0
            static var failNextStart = false
            static var blockStarts = false
            static var blockStops = false
            static var startWaiters: [CheckedContinuation<Void, Never>] = []
            static var stopWaiters: [CheckedContinuation<Void, Never>] = []

            init(configuration: Configuration, stateProvider: any DebugStateProvider) {}

            func start() async throws {
                Self.startCount += 1
                if Self.failNextStart {
                    Self.failNextStart = false
                    throw HarnessFailure.requested
                }
                if Self.blockStarts {
                    await withCheckedContinuation { continuation in
                        Self.startWaiters.append(continuation)
                    }
                }
            }

            func stop() async {
                Self.stopCount += 1
                if Self.blockStops {
                    await withCheckedContinuation { continuation in
                        Self.stopWaiters.append(continuation)
                    }
                }
            }

            static func reset() {
                startCount = 0
                stopCount = 0
                failNextStart = false
                blockStarts = false
                blockStops = false
                startWaiters = []
                stopWaiters = []
            }

            static func releaseStarts() {
                blockStarts = false
                let waiters = startWaiters
                startWaiters = []
                waiters.forEach { $0.resume() }
            }

            static func releaseStops() {
                blockStops = false
                let waiters = stopWaiters
                stopWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
        """#

    let main = #"""

        @main
        @MainActor
        struct HarnessMain {
            static func waitForStarts(_ count: Int) async {
                while APIOSDebugRuntime.startCount < count { await Task.yield() }
            }

            static func waitForStops(_ count: Int) async {
                while APIOSDebugRuntime.stopCount < count { await Task.yield() }
            }

            static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
                guard condition() else { fatalError(message) }
            }

            static func main() async throws {
                APIOSDebugRuntime.reset()
                APIOSDebugRuntime.blockStarts = true
                let first = Task { @MainActor in try await APIOSDebugBootstrap.start() }
                await waitForStarts(1)
                let second = Task { @MainActor in try await APIOSDebugBootstrap.start() }
                for _ in 0..<20 { await Task.yield() }
                APIOSDebugRuntime.releaseStarts()
                try await first.value
                try await second.value
                require(APIOSDebugRuntime.startCount == 1, "concurrent start created multiple runtimes")
                await APIOSDebugBootstrap.stop()
                require(APIOSDebugRuntime.stopCount == 1, "shared runtime was not stopped exactly once")

                APIOSDebugRuntime.reset()
                APIOSDebugRuntime.failNextStart = true
                do {
                    try await APIOSDebugBootstrap.start()
                    fatalError("requested start failure did not propagate")
                } catch HarnessFailure.requested {}
                try await APIOSDebugBootstrap.start()
                require(APIOSDebugRuntime.startCount == 2, "failed start did not roll back for retry")
                await APIOSDebugBootstrap.stop()

                APIOSDebugRuntime.reset()
                APIOSDebugRuntime.blockStarts = true
                let starting = Task { @MainActor in try await APIOSDebugBootstrap.start() }
                await waitForStarts(1)
                let stopping = Task { @MainActor in await APIOSDebugBootstrap.stop() }
                for _ in 0..<20 { await Task.yield() }
                APIOSDebugRuntime.releaseStarts()
                await stopping.value
                try await starting.value
                require(APIOSDebugRuntime.stopCount == 1, "stop during start returned before runtime shutdown")
                try await APIOSDebugBootstrap.start()
                require(APIOSDebugRuntime.startCount == 2, "stop during start left a retained runtime")
                await APIOSDebugBootstrap.stop()

                APIOSDebugRuntime.reset()
                try await APIOSDebugBootstrap.start()
                APIOSDebugRuntime.blockStops = true
                let firstStop = Task { @MainActor in await APIOSDebugBootstrap.stop() }
                await waitForStops(1)
                let secondStop = Task { @MainActor in await APIOSDebugBootstrap.stop() }
                for _ in 0..<20 { await Task.yield() }
                APIOSDebugRuntime.releaseStops()
                await firstStop.value
                await secondStop.value
                require(APIOSDebugRuntime.stopCount == 1, "concurrent stop was not idempotent")
            }
        }
        """#

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "APIOSDebugBootstrapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceURL = temporaryDirectory.appending(path: "BootstrapHarness.swift")
    let executableURL = temporaryDirectory.appending(path: "BootstrapHarness")
    try Data((harness + "\n" + template + main).utf8).write(to: sourceURL)

    let compile = try run(
        "/usr/bin/xcrun",
        arguments: ["swiftc", "-parse-as-library", "-swift-version", "6", "-D", "DEBUG", sourceURL.path, "-o", executableURL.path]
    )
    #expect(compile.status == 0, Comment(rawValue: compile.output))
    guard compile.status == 0 else { return }

    let execute = try run(executableURL.path, arguments: [])
    #expect(execute.status == 0, Comment(rawValue: execute.output))
}

private func run(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
#endif

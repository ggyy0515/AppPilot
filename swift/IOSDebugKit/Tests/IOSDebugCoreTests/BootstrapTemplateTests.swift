import Foundation
import Testing
import IOSDebugCore

@Test func bootstrapTemplateHasStableEntryPoint() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appending(path: "Templates/IOSDebugBootstrap.swift")
    let bytes = try Data(contentsOf: url)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(SHA256.hexDigest(bytes) == "f937fc1aa51947e79651485150c2a5c41475b3352e45e120389b72171a243555")
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
    let templateURL = packageRoot.appending(path: "Templates/IOSDebugBootstrap.swift")
    var template = try String(contentsOf: templateURL, encoding: .utf8)
    template = template
        .replacingOccurrences(of: "import Foundation\n", with: "")
        .replacingOccurrences(of: "import IOSDebugCore\n", with: "")
        .replacingOccurrences(of: "import IOSDebugKit\n", with: "")

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

    @MainActor final class IOSDebugRuntime {
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
            while IOSDebugRuntime.startCount < count { await Task.yield() }
        }

        static func waitForStops(_ count: Int) async {
            while IOSDebugRuntime.stopCount < count { await Task.yield() }
        }

        static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        static func main() async throws {
            IOSDebugRuntime.reset()
            IOSDebugRuntime.blockStarts = true
            let first = Task { @MainActor in try await IOSDebugBootstrap.start() }
            await waitForStarts(1)
            let second = Task { @MainActor in try await IOSDebugBootstrap.start() }
            for _ in 0..<20 { await Task.yield() }
            IOSDebugRuntime.releaseStarts()
            try await first.value
            try await second.value
            require(IOSDebugRuntime.startCount == 1, "concurrent start created multiple runtimes")
            await IOSDebugBootstrap.stop()
            require(IOSDebugRuntime.stopCount == 1, "shared runtime was not stopped exactly once")

            IOSDebugRuntime.reset()
            IOSDebugRuntime.failNextStart = true
            do {
                try await IOSDebugBootstrap.start()
                fatalError("requested start failure did not propagate")
            } catch HarnessFailure.requested {}
            try await IOSDebugBootstrap.start()
            require(IOSDebugRuntime.startCount == 2, "failed start did not roll back for retry")
            await IOSDebugBootstrap.stop()

            IOSDebugRuntime.reset()
            IOSDebugRuntime.blockStarts = true
            let starting = Task { @MainActor in try await IOSDebugBootstrap.start() }
            await waitForStarts(1)
            let stopping = Task { @MainActor in await IOSDebugBootstrap.stop() }
            for _ in 0..<20 { await Task.yield() }
            IOSDebugRuntime.releaseStarts()
            await stopping.value
            try await starting.value
            require(IOSDebugRuntime.stopCount == 1, "stop during start returned before runtime shutdown")
            try await IOSDebugBootstrap.start()
            require(IOSDebugRuntime.startCount == 2, "stop during start left a retained runtime")
            await IOSDebugBootstrap.stop()

            IOSDebugRuntime.reset()
            try await IOSDebugBootstrap.start()
            IOSDebugRuntime.blockStops = true
            let firstStop = Task { @MainActor in await IOSDebugBootstrap.stop() }
            await waitForStops(1)
            let secondStop = Task { @MainActor in await IOSDebugBootstrap.stop() }
            for _ in 0..<20 { await Task.yield() }
            IOSDebugRuntime.releaseStops()
            await firstStop.value
            await secondStop.value
            require(IOSDebugRuntime.stopCount == 1, "concurrent stop was not idempotent")
        }
    }
    """#

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "IOSDebugBootstrapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

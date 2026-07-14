#if DEBUG
import Foundation
import IOSDebugCore
import IOSDebugKit

@MainActor
private final class IOSDebugBootstrapState: DebugStateProvider {
    func debugState() throws -> JSONValue {
        .object([
            "integration": .string("IOSDebugKit"),
            "running": .bool(true),
        ])
    }
}

@MainActor
enum IOSDebugBootstrap {
    private static let stateProvider = IOSDebugBootstrapState()
    private static var lifecycle = Lifecycle.stopped

    private final class StartOperation {
        let task: Task<IOSDebugRuntime, Error>
        var stopRequested = false

        init(task: Task<IOSDebugRuntime, Error>) {
            self.task = task
        }
    }

    private final class StopOperation {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    private enum Lifecycle {
        case stopped
        case starting(StartOperation)
        case running(IOSDebugRuntime)
        case stopping(StopOperation)
    }

    static func start() async throws {
        while true {
            switch lifecycle {
            case .stopped:
                let task = Task { @MainActor in
                    let configuration = try IOSDebugRuntime.Configuration(
                        bearerToken: ProcessInfo.processInfo.environment["IOS_DEBUG_TOKEN"]
                    )
                    let instance = IOSDebugRuntime(configuration: configuration, stateProvider: stateProvider)
                    try await instance.start()
                    return instance
                }
                let operation = StartOperation(task: task)
                lifecycle = .starting(operation)
                try await settleStart(operation)
                return
            case let .starting(operation):
                try await settleStart(operation)
                return
            case .running:
                return
            case let .stopping(operation):
                await settleStop(operation)
            }
        }
    }

    static func stop() async {
        while true {
            switch lifecycle {
            case .stopped:
                return
            case let .starting(operation):
                operation.stopRequested = true
                do {
                    try await settleStart(operation)
                } catch {
                    return
                }
            case let .running(runtime):
                let operation = StopOperation(task: Task { @MainActor in
                    await runtime.stop()
                })
                lifecycle = .stopping(operation)
                await settleStop(operation)
                return
            case let .stopping(operation):
                await settleStop(operation)
                return
            }
        }
    }

    private static func settleStart(_ operation: StartOperation) async throws {
        do {
            let runtime = try await operation.task.value
            if case let .starting(current) = lifecycle, current === operation {
                if operation.stopRequested {
                    let stopOperation = StopOperation(task: Task { @MainActor in
                        await runtime.stop()
                    })
                    lifecycle = .stopping(stopOperation)
                    await settleStop(stopOperation)
                } else {
                    lifecycle = .running(runtime)
                }
            } else if case let .stopping(stopOperation) = lifecycle {
                await settleStop(stopOperation)
            }
        } catch {
            if case let .starting(current) = lifecycle, current === operation {
                lifecycle = .stopped
            }
            throw error
        }
    }

    private static func settleStop(_ operation: StopOperation) async {
        await operation.task.value
        if case let .stopping(current) = lifecycle, current === operation {
            lifecycle = .stopped
        }
    }
}
#endif

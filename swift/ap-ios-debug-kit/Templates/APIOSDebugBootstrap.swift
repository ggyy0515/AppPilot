#if DEBUG
import Foundation
import APIOSDebugCore
import APIOSDebugKit

@MainActor
private final class APIOSDebugBootstrapState: DebugStateProvider {
    func debugState() throws -> JSONValue {
        .object([
            "integration": .string("APIOSDebugKit"),
            "running": .bool(true),
        ])
    }
}

@MainActor
enum APIOSDebugBootstrap {
    private static let stateProvider = APIOSDebugBootstrapState()
    private static var lifecycle = Lifecycle.stopped

    private final class StartOperation {
        let task: Task<APIOSDebugRuntime, Error>
        var stopRequested = false

        init(task: Task<APIOSDebugRuntime, Error>) {
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
        case running(APIOSDebugRuntime)
        case stopping(StopOperation)
    }

    static func start() async throws {
        while true {
            switch lifecycle {
            case .stopped:
                let task = Task { @MainActor in
                    let configuration = try APIOSDebugRuntime.Configuration(
                        bearerToken: ProcessInfo.processInfo.environment["AP_IOS_DEBUG_TOKEN"]
                    )
                    let instance = APIOSDebugRuntime(configuration: configuration, stateProvider: stateProvider)
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

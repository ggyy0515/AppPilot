#if DEBUG && canImport(UIKit)
import Foundation
import IOSDebugCore

public enum DebugActionRole: String, Codable, Sendable {
    case navigation
    case mutation
    case destructive
}

public struct DebugActionToken: Hashable, Sendable {
    fileprivate let value: UUID
}

public struct DebugActionDescriptor: Codable, Sendable, Equatable {
    public let identifier: String
    public let role: DebugActionRole
    public let description: String
    public let isEnabled: Bool
    public let generation: UInt64

    enum CodingKeys: String, CodingKey {
        case identifier
        case role
        case description
        case generation
        case isEnabled = "enabled"
    }
}

public struct DebugActionSnapshot: Codable, Sendable, Equatable {
    public let generation: UInt64
    public let actions: [DebugActionDescriptor]
}

@MainActor
public final class DebugActionRegistry {
    public static let shared = DebugActionRegistry()

    private struct Entry {
        let token: DebugActionToken
        let role: DebugActionRole
        let description: String
        let generation: UInt64
        let isEnabled: @MainActor () -> Bool
        let perform: @MainActor () async throws -> Void
    }

    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public func register(
        identifier: String,
        role: DebugActionRole,
        description: String,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        perform: @escaping @MainActor () async throws -> Void
    ) throws -> DebugActionToken {
        guard
            identifier.range(
                of: #"^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)+$"#,
                options: .regularExpression
            ) != nil
        else {
            throw ProtocolError(
                code: AppErrorCode.configInvalid.rawValue,
                message: "Action identifier is invalid.",
                hint: "Use a stable dot-separated identifier such as header.settings."
            )
        }

        generation &+= 1
        let token = DebugActionToken(value: UUID())
        entries[identifier] = Entry(
            token: token,
            role: role,
            description: description,
            generation: generation,
            isEnabled: isEnabled,
            perform: perform
        )
        return token
    }

    public func unregister(_ token: DebugActionToken) {
        guard let match = entries.first(where: { $0.value.token == token }) else {
            return
        }
        entries.removeValue(forKey: match.key)
        generation &+= 1
    }

    public func snapshot() -> DebugActionSnapshot {
        let actions = entries.map { identifier, entry in
            DebugActionDescriptor(
                identifier: identifier,
                role: entry.role,
                description: entry.description,
                isEnabled: entry.isEnabled(),
                generation: entry.generation
            )
        }.sorted { $0.identifier < $1.identifier }
        return DebugActionSnapshot(generation: generation, actions: actions)
    }

    public func activate(identifier: String) async throws -> UInt64 {
        guard let entry = entries[identifier] else {
            throw ProtocolError(
                code: AppErrorCode.actionNotFound.rawValue,
                message: "Action was not found.",
                hint: "Run actions list and retry; latest registration generation is \(generation)."
            )
        }
        guard entry.isEnabled() else {
            throw ProtocolError(
                code: AppErrorCode.actionDisabled.rawValue,
                message: "Action is disabled.",
                hint: "Wait for the App state to enable the action, then list actions again; latest registration generation is \(generation)."
            )
        }

        do {
            try await entry.perform()
        } catch {
            throw ProtocolError(
                code: AppErrorCode.actionFailed.rawValue,
                message: "Action failed.",
                hint: "Inspect the App state and Debug logs, then retry."
            )
        }
        return entry.generation
    }
}
#endif

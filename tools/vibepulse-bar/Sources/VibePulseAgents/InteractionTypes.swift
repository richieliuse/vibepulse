import Foundation

public enum InteractionProvider: String, Sendable, Equatable, Codable {
    case claude
    case codex
}

public enum InteractionError: Error, Equatable, Sendable {
    case unsupportedVerdict
    case negativeOptionIndex
}

/// Provider-neutral answer. `optionIndex` is set only for an approved question.
public struct InteractionResult: Sendable, Equatable {
    public let verdict: String
    public let optionIndex: Int?

    public init(verdict: String, optionIndex: Int? = nil) throws {
        guard verdict == "approve" || verdict == "deny" || verdict == "leave_it" else {
            throw InteractionError.unsupportedVerdict
        }
        if let optionIndex, optionIndex < 0 {
            throw InteractionError.negativeOptionIndex
        }
        self.verdict = verdict
        self.optionIndex = optionIndex
    }
}

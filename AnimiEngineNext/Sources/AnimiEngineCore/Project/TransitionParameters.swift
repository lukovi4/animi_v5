/// A single typed transition-effect parameter value (Task-002 plan, §7.1).
public enum TransitionParameterValue: Equatable, Sendable {
    case integer(Int64)
    case fixed(ScaleScalar)
    case identifier(String)
    case boolean(Bool)
}

/// A single key/value transition-effect parameter (Task-002 plan, §7.1).
public struct TransitionParameter: Equatable, Sendable {
    public let key: String
    public let value: TransitionParameterValue

    public init(key: String, value: TransitionParameterValue) {
        self.key = key
        self.value = value
    }
}

/// A canonical, sorted, duplicate-free parameter set (Task-002 plan, §7.1).
///
/// Construction sorts by key and rejects duplicate keys, so canonical encoding is deterministic and
/// equality is structural.
public struct TransitionParameterSet: Equatable, Sendable {
    public let sortedUniqueParameters: [TransitionParameter]

    /// Builds a parameter set from arbitrary input, rejecting duplicate keys.
    public init(_ parameters: [TransitionParameter]) throws {
        var seen = Set<String>()
        for parameter in parameters {
            guard seen.insert(parameter.key).inserted else {
                throw ProjectValidationError.duplicateTransitionParameter(key: parameter.key)
            }
        }
        self.sortedUniqueParameters = parameters.sorted { $0.key < $1.key }
    }

    /// The empty parameter set.
    public static let empty = TransitionParameterSet(sortedUnchecked: [])

    init(sortedUnchecked parameters: [TransitionParameter]) {
        self.sortedUniqueParameters = parameters
    }

    /// Looks up a parameter by key.
    public func value(for key: String) -> TransitionParameterValue? {
        sortedUniqueParameters.first { $0.key == key }?.value
    }
}

// RegistryError.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - RegistryError

/// Errors thrown when a registry lookup fails.
public enum RegistryError: Error, Sendable, Equatable, CustomStringConvertible {

    /// No policy has been registered under the given name.
    case notFound(name: String)

    /// A policy exists under the given name but its type does not match the
    /// requested accessor.
    case typeMismatch(name: String, expected: String, found: String)

    /// A human-readable description including the lookup key and type details.
    public var description: String {
        switch self {
        case .notFound(let name):
            "No policy registered under the name \"\(name)\""
        case .typeMismatch(let name, let expected, let found):
            "Policy \"\(name)\" has type \(found), expected \(expected)"
        }
    }
}

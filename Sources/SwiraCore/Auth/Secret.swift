import Foundation

/// A wrapper that keeps a secret out of logs, error descriptions, and structure dumps.
///
/// The value is only reachable through an explicit `reveal()`. Every automatic textual
/// representation (`print`, string interpolation, `dump`) yields a placeholder — the only
/// reliable way to guarantee a token never lands in a log by accident.
public struct Secret: Sendable, Hashable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Explicitly unwrap the value. The one place where a secret becomes an ordinary string.
    public func reveal() -> String {
        value
    }

    public var isEmpty: Bool {
        value.isEmpty
    }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

extension Secret: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    /// Encoding is deliberately refused: a secret must not reach the cache or any export.
    public func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(
            self,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Secret must not be serialized"
            )
        )
    }
}

import Foundation

/// The shared encoder and decoder for all traffic with Jira.
///
/// Both are configured in one place so that different services cannot drift apart in how they
/// interpret dates.
enum JSONCoding {
    /// Jira emits dates as `2024-03-14T09:41:00.000+0000` — ISO 8601 with milliseconds and no
    /// colon in the offset. The stock `.iso8601` strategy rejects that, so parsing goes through
    /// an explicit list of formats.
    static let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd",
    ]

    /// Formatters are expensive to build, and the decoder below runs per date field, so they are
    /// created once. `DateFormatter` is thread-safe for parsing once fully configured.
    private static let parsers: [DateFormatter] = dateFormats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    /// Parses a Jira timestamp, or returns `nil` if it matches none of the known formats.
    ///
    /// Exposed separately because issue fields are decoded as untyped JSON, so their dates arrive
    /// as strings and never pass through `JSONDecoder`'s date strategy.
    static func parseDate(_ raw: String) -> Date? {
        for parser in parsers {
            if let date = parser.date(from: raw) {
                return date
            }
        }
        return nil
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            for parser in parsers {
                if let date = parser.date(from: raw) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(parsers[0])
        return encoder
    }
}

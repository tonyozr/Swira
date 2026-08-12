import Foundation

/// Request descriptions for the JQL endpoints.
public enum JQLEndpoints {
    public static func parse(validation: JQLValidationLevel) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            path: "jql/parse",
            queryItems: [URLQueryItem(name: "validation", value: validation.rawValue)]
        )
    }

    /// The full field and function vocabulary.
    ///
    /// - Parameter projectIds: narrows the vocabulary to fields visible in these projects. On a
    ///   large site the unfiltered response is very large, so passing them matters.
    public static func autocompleteData(projectIds: [Int] = []) -> HTTPRequest {
        var queryItems: [URLQueryItem] = []
        for id in projectIds {
            queryItems.append(URLQueryItem(name: "projectIds", value: String(id)))
        }
        return HTTPRequest(method: .get, path: "jql/autocompletedata", queryItems: queryItems)
    }

    /// Value suggestions for one field.
    public static func suggestions(
        fieldName: String,
        fieldValue: String? = nil,
        predicateName: String? = nil,
        predicateValue: String? = nil
    ) -> HTTPRequest {
        var queryItems = [URLQueryItem(name: "fieldName", value: fieldName)]
        if let fieldValue {
            queryItems.append(URLQueryItem(name: "fieldValue", value: fieldValue))
        }
        if let predicateName {
            queryItems.append(URLQueryItem(name: "predicateName", value: predicateName))
        }
        if let predicateValue {
            queryItems.append(URLQueryItem(name: "predicateValue", value: predicateValue))
        }
        return HTTPRequest(
            method: .get,
            path: "jql/autocompletedata/suggestions",
            queryItems: queryItems
        )
    }

    public static func sanitize() -> HTTPRequest {
        HTTPRequest(method: .post, path: "jql/sanitize")
    }
}

// MARK: - Wire envelopes

struct JQLParseRequest: Encodable, Sendable {
    let queries: [String]
}

struct JQLParseResponse: Decodable, Sendable {
    let queries: [JQLValidation]
}

struct JQLSuggestionsResponse: Decodable, Sendable {
    let results: [JQLSuggestion]
}

struct JQLSanitizeRequest: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        let query: String
        /// Whose visibility to sanitize for. Omitted means the authenticated user.
        let accountId: String?
    }

    let queries: [Item]
}

struct JQLSanitizeResponse: Decodable, Sendable {
    let queries: [JQLSanitization]
}

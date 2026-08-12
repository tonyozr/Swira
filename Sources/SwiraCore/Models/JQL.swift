import Foundation

/// The verdict on one JQL query.
public struct JQLValidation: Sendable, Hashable, Codable {
    public let query: String
    /// Problems that make the query unusable.
    public let errors: [String]
    /// Problems Jira will tolerate — an unknown value, a field the user cannot see.
    public let warnings: [String]
    /// Jira's parsed form of the query. Untyped because the shape varies by clause kind, and
    /// Swira only needs to hand it to a UI, never to reason about it.
    public let structure: JSONValue?

    public init(
        query: String,
        errors: [String] = [],
        warnings: [String] = [],
        structure: JSONValue? = nil
    ) {
        self.query = query
        self.errors = errors
        self.warnings = warnings
        self.structure = structure
    }

    private enum CodingKeys: String, CodingKey {
        case query, errors, warnings, structure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        structure = try container.decodeIfPresent(JSONValue.self, forKey: .structure)
    }

    public var isValid: Bool {
        errors.isEmpty
    }
}

/// How strictly Jira should check a query.
public enum JQLValidationLevel: String, Sendable, Hashable {
    /// Report everything, including problems Jira would otherwise run past.
    case strict
    /// Report hard errors as errors and the rest as warnings.
    case warn
    /// Parse only.
    case none
}

/// A field that may appear in a JQL clause.
public struct JQLField: Sendable, Hashable, Codable {
    /// The token to insert into the query, already quoted by Jira when it needs to be.
    public let value: String
    public let displayName: String
    /// Custom field id, when the field is a custom field.
    public let cfid: String?
    public let operators: [String]
    public let types: [String]

    /// Jira sends these as the *strings* `"true"` / `"false"`, not JSON booleans.
    private let orderable: String?
    private let searchable: String?
    private let auto: String?

    public var isOrderable: Bool { orderable == "true" }
    public var isSearchable: Bool { searchable == "true" }
    /// Whether Jira can suggest values for this field.
    public var supportsAutocomplete: Bool { auto == "true" }

    public var isCustomField: Bool { cfid != nil }

    private enum CodingKeys: String, CodingKey {
        case value, displayName, cfid, operators, types, orderable, searchable, auto
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? value
        cfid = try container.decodeIfPresent(String.self, forKey: .cfid)
        operators = try container.decodeIfPresent([String].self, forKey: .operators) ?? []
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        orderable = try container.decodeIfPresent(String.self, forKey: .orderable)
        searchable = try container.decodeIfPresent(String.self, forKey: .searchable)
        auto = try container.decodeIfPresent(String.self, forKey: .auto)
    }
}

/// A function that may appear on the right-hand side of a clause, e.g. `currentUser()`.
public struct JQLFunction: Sendable, Hashable, Codable {
    public let value: String
    public let displayName: String
    /// Whether the function returns a list, and so pairs with `in` rather than `=`.
    public let isList: Bool
    public let types: [String]

    private enum CodingKeys: String, CodingKey {
        case value, displayName, isList, types
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? value
        // Another string-typed boolean, for the same historical reasons as `JQLField.orderable`.
        isList = (try container.decodeIfPresent(String.self, forKey: .isList)) == "true"
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
    }
}

/// The vocabulary a JQL editor needs in order to offer completions.
public struct JQLAutocompleteData: Sendable, Hashable, Codable {
    public let visibleFieldNames: [JQLField]
    public let visibleFunctionNames: [JQLFunction]
    /// Words that must be quoted to be used as values.
    public let jqlReservedWords: [String]

    private enum CodingKeys: String, CodingKey {
        case visibleFieldNames, visibleFunctionNames, jqlReservedWords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleFieldNames = try container.decodeIfPresent(
            [JQLField].self, forKey: .visibleFieldNames
        ) ?? []
        visibleFunctionNames = try container.decodeIfPresent(
            [JQLFunction].self, forKey: .visibleFunctionNames
        ) ?? []
        jqlReservedWords = try container.decodeIfPresent(
            [String].self, forKey: .jqlReservedWords
        ) ?? []
    }
}

/// One suggested value for a field.
public struct JQLSuggestion: Sendable, Hashable, Codable {
    public let value: String
    /// Jira wraps the matched substring in `<b>` tags here, so this is markup, not plain text.
    public let displayName: String

    public init(value: String, displayName: String) {
        self.value = value
        self.displayName = displayName
    }

    /// `displayName` with Jira's match-highlighting markup removed.
    public var plainDisplayName: String {
        displayName
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }
}

/// The result of stripping clauses the given user is not allowed to see.
public struct JQLSanitization: Sendable, Hashable, Codable {
    public let initialQuery: String
    public let sanitizedQuery: String?
    public let errors: [String]

    private enum CodingKeys: String, CodingKey {
        case initialQuery, sanitizedQuery, errors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        initialQuery = try container.decodeIfPresent(String.self, forKey: .initialQuery) ?? ""
        sanitizedQuery = try container.decodeIfPresent(String.self, forKey: .sanitizedQuery)
        errors = try container.decodeIfPresent([String].self, forKey: .errors) ?? []
    }
}

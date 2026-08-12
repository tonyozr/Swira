import Foundation

/// JQL validation and autocompletion.
///
/// The point of this service is that a filter editor can tell the user what is wrong with their
/// query *before* they save it, rather than surfacing a raw 400 from the create call.
public actor JQLService {
    private let client: JiraClient
    private let deployment: JiraDeployment

    public init(client: JiraClient, deployment: JiraDeployment = .cloud) {
        self.client = client
        self.deployment = deployment
    }

    /// Checks one query.
    public func validate(
        _ query: String,
        level: JQLValidationLevel = .strict
    ) async throws -> JQLValidation {
        let results = try await validate([query], level: level)
        // Jira answers one result per submitted query; an empty answer means it accepted nothing
        // and said nothing, which is not something a caller can act on.
        guard let first = results.first else {
            throw SwiraError.decoding(
                path: "queries",
                snippet: "Jira returned no validation result for the submitted query"
            )
        }
        return first
    }

    /// Checks several queries — one round trip on Cloud, one per query on Data Center.
    public func validate(
        _ queries: [String],
        level: JQLValidationLevel = .strict
    ) async throws -> [JQLValidation] {
        guard !queries.isEmpty else { return [] }

        switch deployment {
        case .cloud:
            let response: JQLParseResponse = try await client.send(
                JQLEndpoints.parse(validation: level),
                body: JQLParseRequest(queries: queries),
                as: JQLParseResponse.self
            )
            return response.queries

        case .dataCenter:
            // No `jql/parse` here. A zero-result dry run answers the same question: the server
            // parses the query and, on a bad one, returns the same error envelope the editor
            // wants to show. `level` cannot be honored — Server has one strictness.
            var results: [JQLValidation] = []
            for query in queries {
                do {
                    _ = try await client.send(
                        SearchEndpoints.legacySearch(),
                        body: LegacyIssueSearchRequest(
                            jql: query, startAt: 0, maxResults: 0, fields: []
                        ),
                        as: LegacyIssueSearchResponse.self
                    )
                    results.append(JQLValidation(query: query))
                } catch let error as SwiraError {
                    guard case .jira(400, let messages, let fieldErrors) = error else {
                        throw error
                    }
                    let fieldMessages = fieldErrors.sorted { $0.key < $1.key }.map(\.value)
                    results.append(
                        JQLValidation(query: query, errors: messages + fieldMessages)
                    )
                }
            }
            return results
        }
    }

    /// The field and function vocabulary for a JQL editor.
    ///
    /// - Parameter projectIds: narrow the vocabulary to these projects. Worth passing on a large
    ///   site, where the unfiltered response runs to megabytes.
    public func autocompleteData(projectIds: [Int] = []) async throws -> JQLAutocompleteData {
        try await client.send(
            JQLEndpoints.autocompleteData(projectIds: projectIds),
            as: JQLAutocompleteData.self
        )
    }

    /// Suggested values for a field, filtered by what the user has typed so far.
    ///
    /// - Parameters:
    ///   - fieldName: the field's JQL name, e.g. `status` or `cf[10001]`.
    ///   - fieldValue: the partial value typed so far.
    public func suggestions(
        fieldName: String,
        fieldValue: String? = nil,
        predicateName: String? = nil,
        predicateValue: String? = nil
    ) async throws -> [JQLSuggestion] {
        let response: JQLSuggestionsResponse = try await client.send(
            JQLEndpoints.suggestions(
                fieldName: fieldName,
                fieldValue: fieldValue,
                predicateName: predicateName,
                predicateValue: predicateValue
            ),
            as: JQLSuggestionsResponse.self
        )
        return response.results
    }

    /// Rewrites a query so it contains nothing the given user is not allowed to see.
    ///
    /// Use before showing one person's filter JQL to another — otherwise project names and field
    /// values leak through the query text even when the results themselves are filtered.
    public func sanitize(_ query: String, forAccountId accountId: String? = nil) async throws -> JQLSanitization {
        let response: JQLSanitizeResponse = try await client.send(
            JQLEndpoints.sanitize(),
            body: JQLSanitizeRequest(
                queries: [JQLSanitizeRequest.Item(query: query, accountId: accountId)]
            ),
            as: JQLSanitizeResponse.self
        )
        guard let first = response.queries.first else {
            throw SwiraError.decoding(
                path: "queries",
                snippet: "Jira returned no sanitization result for the submitted query"
            )
        }
        return first
    }
}

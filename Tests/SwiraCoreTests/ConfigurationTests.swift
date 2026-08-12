import Foundation
import Testing

@testable import SwiraCore

@Suite("Configuration")
struct ConfigurationTests {
    @Test("Site URLs are normalized as a human would type them")
    func normalizesSiteURL() throws {
        #expect(try JiraSite(urlString: "example.atlassian.net").baseURL.absoluteString
            == "https://example.atlassian.net")
        #expect(try JiraSite(urlString: "  https://example.atlassian.net/  ").baseURL.absoluteString
            == "https://example.atlassian.net")
        #expect(try JiraSite(urlString: "http://jira.internal:8080").baseURL.absoluteString
            == "http://jira.internal:8080")
    }

    @Test("An empty site URL is rejected rather than producing a broken client")
    func rejectsEmptyURL() {
        #expect(throws: SwiraError.self) {
            _ = try JiraSite(urlString: "   ")
        }
    }

    @Test("API URLs carry the version and query parameters")
    func buildsAPIURL() throws {
        let site = try JiraSite(urlString: "https://example.atlassian.net")
        let url = site.apiURL(
            path: "filter/search",
            queryItems: [URLQueryItem(name: "maxResults", value: "50")]
        )
        #expect(url?.absoluteString
            == "https://example.atlassian.net/rest/api/3/filter/search?maxResults=50")
    }

    @Test("An email plus token selects basic auth")
    func environmentSelectsBasicAuth() throws {
        let (configuration, auth) = try SwiraConfiguration.fromEnvironment([
            "JIRA_URL": "example.atlassian.net",
            "JIRA_EMAIL": "mia@example.com",
            "JIRA_API_TOKEN": "secret-token",
        ])

        #expect(configuration.site.baseURL.absoluteString == "https://example.atlassian.net")
        #expect(auth is BasicAuthProvider)
    }

    @Test("A token without an email falls back to bearer auth")
    func environmentFallsBackToBearer() throws {
        let (_, auth) = try SwiraConfiguration.fromEnvironment([
            "JIRA_URL": "jira.internal",
            "JIRA_PAT": "personal-access-token",
        ])
        #expect(auth is BearerAuthProvider)
    }

    @Test("Variables are consulted in priority order")
    func respectsVariablePriority() throws {
        let (configuration, _) = try SwiraConfiguration.fromEnvironment([
            "SWIRA_JIRA_URL": "https://preferred.atlassian.net",
            "JIRA_URL": "https://ignored.atlassian.net",
            "JIRA_API_TOKEN": "token",
        ])
        #expect(configuration.site.baseURL.absoluteString == "https://preferred.atlassian.net")
    }

    @Test("A missing token names every variable that was checked")
    func missingTokenIsExplicit() {
        do {
            _ = try SwiraConfiguration.fromEnvironment(["JIRA_URL": "example.atlassian.net"])
            Issue.record("Expected a configuration error")
        } catch let error as SwiraError {
            guard case .configuration(_, let searched) = error else {
                Issue.record("Expected .configuration, got \(error)")
                return
            }
            #expect(searched == SwiraConfiguration.tokenVariables)
            #expect(error.suggestsReauth)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Blank values are treated as absent, not as a valid empty token")
    func blankValuesAreIgnored() {
        #expect(throws: SwiraError.self) {
            _ = try SwiraConfiguration.fromEnvironment([
                "JIRA_URL": "example.atlassian.net",
                "JIRA_API_TOKEN": "   ",
            ])
        }
    }
}

@Suite("JiraUser decoding")
struct JiraUserDecodingTests {
    @Test("A Server/DC user without accountId falls back to key, then name")
    func decodesServerUsers() throws {
        let byKey = Data(#"""
        {"key":"JIRAUSER10142168","name":"mia.krystof","displayName":"Mia Krystof","active":true}
        """#.utf8)
        let userByKey = try JSONCoding.makeDecoder().decode(JiraUser.self, from: byKey)
        #expect(userByKey.accountId == "JIRAUSER10142168")
        #expect(userByKey.displayName == "Mia Krystof")

        let byName = Data(#"{"name":"mia.krystof","active":true}"#.utf8)
        let userByName = try JSONCoding.makeDecoder().decode(JiraUser.self, from: byName)
        #expect(userByName.accountId == "mia.krystof")
        // With no displayName, the identifier stands in rather than leaving the UI blank.
        #expect(userByName.displayName == "mia.krystof")
    }

    @Test("A Cloud user still decodes by accountId, ignoring any legacy keys")
    func prefersAccountId() throws {
        let body = Data(#"""
        {"accountId":"5b10a2844c20165700ede21g","key":"legacy","displayName":"Mia Krystof"}
        """#.utf8)
        let user = try JSONCoding.makeDecoder().decode(JiraUser.self, from: body)
        #expect(user.accountId == "5b10a2844c20165700ede21g")
    }
}

@Suite("Secret")
struct SecretTests {
    @Test("A secret never renders its value in text")
    func neverRendersValue() {
        let secret = Secret("super-secret-token")
        #expect("\(secret)" == "<redacted>")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        #expect(secret.reveal() == "super-secret-token")
    }

    @Test("A secret refuses to be serialized")
    func refusesEncoding() {
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(Secret("token"))
        }
    }
}

import Foundation
import SwiraCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reverse-proxies arbitrary Jira paths so the browser's Split View pane (docs/CLIENT-SPEC.md
/// §3.2) can embed a real, fully-interactive Jira page in an `<iframe>`.
///
/// Loading Jira directly in that frame doesn't work: cross-origin requests from the page's own
/// script (and, on many instances, `X-Frame-Options`/CSP `frame-ancestors`) block it outright.
/// Serving the same bytes from our own origin instead sidesteps both — the framed document and
/// its parent share an origin, so nothing about it looks cross-origin to the browser. This isn't
/// mounted under one fixed prefix like `/secure`: Jira itself spreads its UI across many
/// top-level paths (`/secure/...`, `/browse/...`, `/rest/...`, `/images/...`, `/s/<hash>/_/...`
/// for versioned static assets, and — when a Data Center instance's site URL bakes in a context
/// path — `/jira/...` too). `WebAPI`'s routing forwards anything that isn't one of its own
/// `/api/...` calls here unchanged, so whatever path a given Jira page actually uses just works.
///
/// Headers are forwarded as close to verbatim as HTTP allows — the proxy's only deliberate
/// addition is the `Authorization` header, via the same `AuthProvider` every other Swira request
/// uses. The exceptions are hop-by-hop headers a proxy must not forward as-is (`Host`,
/// `Content-Length`, `Connection`), `Accept-Encoding` (dropped so `URLSession`'s own transparent
/// gzip/deflate handling applies predictably — forwarding the browser's, which may list `br`,
/// risks a Brotli body this transport can't decode), and response headers that would otherwise
/// defeat the whole point of proxying (`X-Frame-Options`, CSP `frame-ancestors`, and a
/// `Set-Cookie` scoped to Jira's own origin).
///
/// Redirects that stay on Jira's own host are followed here, server-side
/// (`sendFollowingRedirects`), rather than relayed to the browser — the embedded frame otherwise
/// visibly jumps to whatever Jira redirected to (most often a login page on a lapsed session),
/// which reads as the split view breaking rather than as a normal page load. A redirect that
/// leaves Jira's host entirely (Atlassian SSO's `id.atlassian.com` is the common case) is neither
/// followed nor relayed as a raw 3xx: `handle` turns it into a small same-origin page
/// (`externalRedirectPage`) that asks the parent window, via `postMessage`, to offer opening that
/// URL in a new tab instead — see the `message` listener in `Resources/index.html`.
///
/// That covers redirects this proxy's own request sees. It doesn't cover Jira Cloud's own
/// client-side behavior: confirmed live against a real issue page, Jira Cloud's web app treats
/// this proxy's header-based `Authorization` as no session at all (its embedded state carries
/// `"user":null` even though the very same request's data — issue fields, etc. — came back
/// correctly), and its JS bundle reacts by navigating the frame itself to Atlassian SSO with
/// `prompt=none`. That's a plain in-page script navigation, invisible to this proxy since no HTTP
/// request for it ever reaches here. `injectNavigationGuard` patches the served HTML with a small
/// script — installed before any of Jira's own — that intercepts exactly that kind of
/// script-driven cross-origin navigation and routes it through the same `postMessage` bridge.
actor JiraProxy {
    private let site: JiraSite
    private let auth: AuthProvider
    private let session: URLSession
    private let redirectBlocker = NoRedirectDelegate()

    init(site: JiraSite, auth: AuthProvider) {
        self.site = site
        self.auth = auth

        // Ephemeral: no on-disk cache or cookie storage. In-memory cookies still work for the
        // lifetime of the process, which is enough for whatever session state a Jira page sets
        // while the app is running.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard let targetURL = URL(string: request.rawTarget, relativeTo: site.baseURL)?.absoluteURL else {
            return errorResponse("Could not resolve a Jira URL for '\(request.rawTarget)'.")
        }

        var outbound = URLRequest(url: targetURL)
        outbound.httpMethod = request.method
        outbound.httpBody = request.body.isEmpty ? nil : request.body

        let excludedRequestHeaders: Set<String> = ["host", "content-length", "connection", "accept-encoding"]
        for (name, value) in request.headers where !excludedRequestHeaders.contains(name.lowercased()) {
            outbound.setValue(value, forHTTPHeaderField: name)
        }

        // Reuses the same `AuthProvider` (Basic email+token, Bearer PAT, …) every other Swira
        // request authorizes with, rather than re-deriving the header scheme here.
        var authCarrier = HTTPRequest(method: .get, path: "")
        do {
            try await auth.authorize(&authCarrier)
        } catch {
            return errorResponse("Could not authorize the Jira request: \(error)")
        }
        for (name, value) in authCarrier.headers {
            outbound.setValue(value, forHTTPHeaderField: name)
        }

        let result: (data: Data, response: HTTPURLResponse)
        do {
            result = try await sendFollowingRedirects(outbound, redirectsRemaining: 10)
        } catch {
            return errorResponse("Jira proxy request failed: \(error.localizedDescription)", status: 502)
        }

        // A redirect `sendFollowingRedirects` declined to chase itself — i.e. one leaving Jira's
        // own host entirely (Atlassian's `id.atlassian.com` SSO login is the common case). We
        // can't proxy a different site's origin under this one, and following it here would hand
        // that site a request with Jira's Authorization header attached, which is not this site's
        // credential to receive. Surface it to the user instead of relaying the raw redirect,
        // which the framed page has no sensible way to act on.
        if (300..<400).contains(result.response.statusCode),
           let location = result.response.value(forHTTPHeaderField: "Location"),
           let redirectURL = URL(string: location, relativeTo: outbound.url)?.absoluteURL,
           !isJiraHost(redirectURL) {
            return externalRedirectPage(to: redirectURL)
        }

        return buildResponse(
            status: result.response.statusCode, headers: result.response.allHeaderFields, body: result.data
        )
    }

    private func send(_ request: URLRequest) async throws -> (data: Data, response: URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: SwiraError.transport(description: "no response"))
                }
            }
            task.resume()
        }
    }

    /// Follows same-host redirects on the server side instead of relaying a 3xx to the browser:
    /// the frame's own navigation would otherwise visibly jump — most commonly to a login page
    /// when the session has lapsed — momentarily showing Jira's raw (unproxied, unstyled-by-us)
    /// redirect target inside the split-view pane. `NoRedirectDelegate` stops `URLSession` from
    /// chasing the chain itself so this loop stays in control of each hop; `redirectsRemaining` is
    /// the same kind of backstop `PagedSequence` uses against a runaway chain.
    ///
    /// A redirect that leaves Jira's own host — Atlassian SSO (`id.atlassian.com`) is the case
    /// this exists for — is deliberately NOT followed here: chasing it would send that other
    /// site Jira's `Authorization` header, and proxying its origin under this one isn't what this
    /// type does. The 3xx is returned as-is for `handle` to turn into the external-redirect
    /// prompt instead.
    ///
    /// Method/body handling on a followed redirect mirrors what browsers actually do (not the
    /// RFC): 303 always downgrades to GET, and so do legacy 301/302 for a non-GET/HEAD request;
    /// 307/308 preserve the original method and body.
    private func sendFollowingRedirects(
        _ request: URLRequest, redirectsRemaining: Int
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SwiraError.transport(description: "Jira proxy response was not HTTP.")
        }
        guard redirectsRemaining > 0,
              (300..<400).contains(httpResponse.statusCode),
              let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location, relativeTo: request.url)?.absoluteURL,
              isJiraHost(redirectURL)
        else {
            return (data, httpResponse)
        }

        var next = request
        next.url = redirectURL
        let downgradesToGET = httpResponse.statusCode == 303
            || (httpResponse.statusCode != 307 && httpResponse.statusCode != 308
                && request.httpMethod != "GET" && request.httpMethod != "HEAD")
        if downgradesToGET {
            next.httpMethod = "GET"
            next.httpBody = nil
        }
        return try await sendFollowingRedirects(next, redirectsRemaining: redirectsRemaining - 1)
    }

    private func isJiraHost(_ url: URL) -> Bool {
        guard let host = url.host, let jiraHost = site.baseURL.host else { return false }
        return host.caseInsensitiveCompare(jiraHost) == .orderedSame
    }

    /// A same-origin bridge page: rather than the browser navigating the frame straight to a
    /// site we can't proxy (and, again, must not silently be handed Jira's auth header), the
    /// frame loads this instead and asks the parent page to offer opening it in a new window.
    /// `postMessage` (rather than reaching into `window.parent`'s DOM directly) is what keeps
    /// this legitimate cross-frame communication instead of exactly the kind of unchecked
    /// cross-origin reach embedding real, third-party Jira content deliberately avoids elsewhere.
    private func externalRedirectPage(to url: URL) -> HTTPServer.Response {
        let payload = (try? JSONEncoder().encode(["url": url.absoluteString])) ?? Data()
        let payloadLiteral = String(decoding: payload, as: UTF8.self)
        let html = """
        <!doctype html>
        <meta charset="utf-8">
        <script>
          window.parent.postMessage(
            { swiraExternalRedirect: \(payloadLiteral).url },
            window.location.origin
          );
        </script>
        """
        return HTTPServer.Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    // MARK: - Response assembly

    private func buildResponse(
        status: Int, headers rawHeaders: [AnyHashable: Any], body: Data
    ) -> HTTPServer.Response {
        var headers: [(name: String, value: String)] = []
        var contentType = "application/octet-stream"

        for (key, rawValue) in rawHeaders {
            guard let name = key as? String, let value = rawValue as? String else { continue }
            switch name.lowercased() {
            case "content-type":
                contentType = value
            // Recomputed by HTTPServer.serve() from the (possibly rewritten) body, or simply not
            // meaningful to replay on this hop.
            case "content-length", "transfer-encoding", "content-encoding", "connection":
                continue
            // Jira's own framing/embedding rules were written for Jira's origin, not ours — the
            // whole point of this proxy is to make the framed page share an origin with the app
            // embedding it, so honoring these would just reintroduce the problem being solved.
            case "x-frame-options", "content-security-policy":
                continue
            case "location":
                headers.append(("Location", rewriteJiraOrigin(in: value)))
            // `URLSession` hands back every repeated response header — Set-Cookie included —
            // joined into one comma-separated string (confirmed live: Jira sends two Set-Cookie
            // lines for a single response, and `allHeaderFields` arrives with one "Set-Cookie"
            // key holding both, comma-joined). Relaying that straight through produces one
            // malformed Set-Cookie line the browser can only parse the first cookie out of,
            // silently dropping the rest — `atl-sticky-version` (Atlassian's edge backend-pinning
            // cookie) was the casualty observed here, and its loss is the likely cause of the
            // 503s later API calls got back through this proxy. `splitSetCookieHeader` undoes the
            // join first so every cookie survives as its own header line.
            case "set-cookie":
                for cookie in splitSetCookieHeader(value) {
                    headers.append(("Set-Cookie", rescopeCookie(cookie)))
                }
            default:
                headers.append((name, value))
            }
        }

        var rewrittenBody = isTextual(contentType) ? rewriteBody(body) : body
        if contentType.lowercased().hasPrefix("text/html") {
            rewrittenBody = injectNavigationGuard(into: rewrittenBody)
        }
        return HTTPServer.Response(status: status, contentType: contentType, body: rewrittenBody, headers: headers)
    }

    private func errorResponse(_ message: String, status: Int = 502) -> HTTPServer.Response {
        HTTPServer.Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    // MARK: - Rewriting

    /// Content types worth scanning for embedded absolute Jira URLs. Binary types (images, fonts)
    /// are passed through untouched.
    private func isTextual(_ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        return lowered.hasPrefix("text/")
            || lowered.contains("javascript")
            || lowered.contains("json")
            || lowered.contains("xml")
            || lowered.contains("svg")
    }

    /// Strips `https://host[:port]` / `http://host[:port]` (and their `\/`-escaped forms, as
    /// found inside inline JSON blobs Jira's pages embed) wherever they point back at this same
    /// Jira instance, so the URL that's left is root-relative and resolves against our own origin
    /// instead — which the catch-all route above then proxies just the same. This is deliberately
    /// best-effort text substitution, not an HTML/CSS/JS parser: it catches ordinary `href`/`src`/
    /// `url(...)` references and JSON string values, not every conceivable way a URL could be
    /// constructed (e.g. assembled piecemeal by a script from `location.origin`).
    private func rewriteBody(_ body: Data) -> Data {
        guard let text = String(data: body, encoding: .utf8) else {
            // Not UTF-8 text despite the Content-Type — leave it alone rather than corrupt it.
            return body
        }
        var result = text
        for origin in jiraOriginStrings() {
            result = result.replacingOccurrences(of: origin, with: "")
            result = result.replacingOccurrences(
                of: origin.replacingOccurrences(of: "/", with: "\\/"), with: ""
            )
        }
        return Data(result.utf8)
    }

    /// Installs `navigationGuardScript` as the first thing inside `<head>`, so it runs before any
    /// script of Jira's own — needed for a case `sendFollowingRedirects` can't see at all:
    /// Jira Cloud's web app treats this proxy's `Authorization` header as no session (`"user":
    /// null` in the page's own embedded state — confirmed live against a real issue page), and
    /// its client-side bundle reacts by navigating straight to Atlassian's SSO
    /// (`id.atlassian.com/login?...&prompt=none&continue=...`) — a plain in-page JS navigation,
    /// not an HTTP redirect this proxy's request ever sees, so there is nothing at the HTTP layer
    /// to intercept. No `<head>` (a redirect stub, a non-HTML-document fragment) means nothing to
    /// guard.
    private func injectNavigationGuard(into body: Data) -> Data {
        guard let text = String(data: body, encoding: .utf8),
              let headTagRange = text.range(of: "<head", options: [.caseInsensitive]),
              let headCloseRange = text.range(of: ">", range: headTagRange.upperBound..<text.endIndex)
        else {
            return body
        }
        var result = text
        result.insert(contentsOf: navigationGuardScript, at: headCloseRange.upperBound)
        return Data(result.utf8)
    }

    /// Splits a `URLSession`-joined multi-cookie `Set-Cookie` value back into individual cookies.
    /// Not a plain comma split: `Expires=Wed, 21-Oct-2026 07:28:00 GMT` — a valid, common
    /// attribute of a single cookie — contains a comma of its own that must NOT be treated as a
    /// cookie boundary. The distinguishing mark of an actual boundary is what follows it: a new
    /// cookie starts with `<name>=`, immediately (only optional whitespace before the `=`) — an
    /// `Expires` date's comma is always followed by the rest of that date (`21-Oct-2026...`),
    /// which has no `=` before its next `;` or `,`. Matches the technique used by the handful of
    /// other HTTP proxies/clients that hit this same `HTTPURLResponse.allHeaderFields` quirk.
    private func splitSetCookieHeader(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #",(?=\s*[^;,=\s]+=)"#) else {
            return [value]
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var pieces: [String] = []
        var cursor = value.startIndex
        for match in regex.matches(in: value, range: range) {
            guard let matchRange = Range(match.range, in: value) else { continue }
            pieces.append(String(value[cursor..<matchRange.lowerBound]))
            cursor = matchRange.upperBound
        }
        pieces.append(String(value[cursor...]))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func rewriteJiraOrigin(in value: String) -> String {
        for origin in jiraOriginStrings() where value.hasPrefix(origin) {
            return String(value.dropFirst(origin.count))
        }
        return value
    }

    /// Drops `Domain=...` (scoping the cookie to Jira's own host, which our origin isn't) and
    /// `Secure` (this server is plain HTTP loopback, and a browser silently discards a `Secure`
    /// cookie set over it) from a `Set-Cookie` value. Everything else — name, value, `Path`,
    /// `HttpOnly`, `SameSite`, expiry — is kept.
    private func rescopeCookie(_ value: String) -> String {
        value
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { attribute in
                let lowered = attribute.lowercased()
                return !lowered.hasPrefix("domain=") && lowered != "secure"
            }
            .joined(separator: "; ")
    }

    private func jiraOriginStrings() -> [String] {
        guard let host = site.baseURL.host else { return [] }
        let portSuffix = site.baseURL.port.map { ":\($0)" } ?? ""
        return ["https://\(host)\(portSuffix)", "http://\(host)\(portSuffix)"]
    }

    /// Redirects the `externalRedirectPage` bridge to the same `postMessage` the browser's parent
    /// listens for, but reached from inside a page the browser loaded normally — not one this
    /// proxy chose to serve instead of the real content. Covers the two idiomatic ways a script
    /// silently navigates itself (`location.assign`/`location.replace` — what a `prompt=none` SSO
    /// check, like Jira Cloud's, would reasonably use so the redirect doesn't add a history entry;
    /// `window.open`) plus an ordinary link click, checking each target's origin before letting it
    /// through. One thing this deliberately cannot catch: a raw `location.href = url` or
    /// `location = url` assignment — `window.location` is a platform-"unforgeable" property no
    /// script, however early it runs, can shadow or intercept — so a page using that form still
    /// navigates the frame directly, same as it would in any other third-party embed.
    private var navigationGuardScript: String {
        """
        <script>(function(){function isExternal(u){try{return new URL(u,window.location.href)\
        .origin!==window.location.origin}catch(e){return false}}function reportExternal(u){try{\
        var r=new URL(u,window.location.href).href;window.parent.postMessage(\
        {swiraExternalRedirect:r},window.location.origin)}catch(e){}}var LP=Object.getPrototypeOf(\
        window.location);["assign","replace"].forEach(function(m){var o=LP[m];if(typeof o!=="\
        function")return;LP[m]=function(u){if(isExternal(u)){reportExternal(u);return}\
        return o.call(this,u)}});var oo=window.open;window.open=function(u){if(u&&isExternal(u)){\
        reportExternal(u);return null}return oo.apply(this,arguments)};document.addEventListener(\
        "click",function(e){var el=e.target;while(el&&el.tagName!=="A")el=el.parentElement;\
        if(el&&el.href&&isExternal(el.href)){e.preventDefault();e.stopPropagation();\
        reportExternal(el.href)}},true)})();\(snapshotBroadcastScript)</script>
        """
    }

    /// Keeps the parent window supplied with a running copy of this page's DOM, so that if the
    /// page turns out to navigate itself away by a means nothing above can catch or even see (a
    /// raw `location = url`/`location.href = url` assignment — see the doc comment on
    /// `navigationGuardScript`), the parent has *something* real to fall back to instead of a
    /// blank pane.
    ///
    /// Waiting for the framed `<iframe>`'s own `load` event to read this from the parent's side
    /// turns out to be too late in practice — confirmed live: `load` doesn't fire until every
    /// subresource (images, fonts, the async JS chunks Jira's bundle itself pulls in) finishes,
    /// and Jira Cloud's session check finishes and redirects well before that, despite the page
    /// having visibly rendered seconds earlier. So this pushes snapshots outward instead of the
    /// parent pulling one: on the earliest signal available (`DOMContentLoaded`) and periodically
    /// after, for as long as the page survives, each one overwriting the last.
    private var snapshotBroadcastScript: String {
        "function swiraSnapshot(){try{window.parent.postMessage({swiraSnapshot:"
            + "document.documentElement.outerHTML},window.location.origin)}catch(e){}}"
            + "document.addEventListener(\"DOMContentLoaded\",swiraSnapshot);"
            + "var swiraSnapshotTimer=setInterval(swiraSnapshot,500);"
            + "window.addEventListener(\"pagehide\",function(){clearInterval(swiraSnapshotTimer)});"
    }
}

/// Blocks automatic redirect-following so a 3xx response (and its `Location` header) reaches
/// `JiraProxy.handle` to rewrite, instead of `URLSession` silently chasing it — which for a
/// same-origin-relative `Location` would be harmless, but for one that's still absolute against
/// Jira's host would send the browser's follow-up straight back through Jira, unproxied.
///
/// `@unchecked Sendable` matches the same exception `HTTPServer`/`ResponseBox` already take in
/// this module (not `SwiraCore`, which avoids it) for platform-interop types that hold no mutable
/// state of their own.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

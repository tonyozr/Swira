import Foundation
import Logging

#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A deliberately minimal HTTP/1.1 server for serving the Swira web client on localhost.
///
/// Hand-rolled over blocking sockets rather than built on SwiftNIO/Hummingbird, because those
/// do not support Windows — and this project's development happens on Windows. The trade-offs
/// are acceptable for the job: one local user, small responses, `Connection: close` per
/// request, no TLS (the server binds to the loopback interface only and must never listen on
/// anything else).
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: Data

        static func json(_ data: Data, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }

        static func html(_ text: String) -> Response {
            Response(status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
        }

        static func notFound() -> Response {
            Response(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let port: UInt16
    private let handler: Handler
    private let logger: Logger

    init(port: UInt16, logger: Logger, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        self.logger = logger
    }

    /// Binds the loopback interface and serves until the process exits.
    func run() throws {
        #if os(Windows)
        var wsaData = WSADATA()
        guard WSAStartup(0x0202, &wsaData) == 0 else {
            throw ServerError.startup("WSAStartup failed")
        }
        #endif

        let listener = socket(AF_INET, sockOptStream, 0)
        guard listener != invalidSocket else {
            throw ServerError.startup("socket() failed")
        }

        var yes: Int32 = 1
        _ = withUnsafeBytes(of: &yes) { buffer in
            setsockopt(
                listener, SOL_SOCKET, SO_REUSEADDR,
                buffer.baseAddress!.assumingMemoryBound(to: sockOptValue.self),
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_family = addressFamily(AF_INET)
        address.sin_port = port.bigEndian
        // Loopback only: this server has no authentication and must not be reachable from
        // the network.
        address.sin_addr = loopbackAddress

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            closeSocket(listener)
            throw ServerError.startup("bind() failed — is port \(port) already in use?")
        }
        guard listen(listener, 16) == 0 else {
            closeSocket(listener)
            throw ServerError.startup("listen() failed")
        }

        logger.info("Serving", metadata: ["url": "http://127.0.0.1:\(port)/"])

        while true {
            let client = accept(listener, nil, nil)
            guard client != invalidSocket else { continue }
            let thread = Thread { [weak self] in
                self?.serve(client: client)
            }
            thread.start()
        }
    }

    // MARK: - Per-connection handling

    private func serve(client: SocketHandle) {
        defer { closeSocket(client) }
        guard let request = readRequest(from: client) else { return }

        // Bridge the blocking connection thread into the async handler.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task { [handler] in
            box.response = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        let response = box.response ?? Response(status: 500, contentType: "text/plain", body: Data())

        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = sendBytes(client, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    private func readRequest(from client: SocketHandle) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)

        // Read until the end of headers.
        while !data.containsHeaderTerminator {
            let n = recvBytes(client, &buffer, buffer.count)
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
            if data.count > 1_048_576 { return nil }
        }

        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]

        var contentLength = 0
        for line in lines {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        // Read the remainder of the body, if any.
        var body = Data(data[headerEnd.upperBound...])
        while body.count < contentLength {
            let n = recvBytes(client, &buffer, buffer.count)
            guard n > 0 else { break }
            body.append(contentsOf: buffer[0..<n])
        }

        // Split path and query.
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let path = String(pathAndQuery[0]).removingPercentEncoding ?? String(pathAndQuery[0])
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                    : ""
                query[key] = value
            }
        }

        return Request(method: method, path: path, query: query, body: body)
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    enum ServerError: Error, CustomStringConvertible {
        case startup(String)
        var description: String {
            if case .startup(let message) = self { return message }
            return "server error"
        }
    }
}

/// Mutable cell for passing the handler's result back to the blocking connection thread.
private final class ResponseBox: @unchecked Sendable {
    var response: HTTPServer.Response?
}

extension Data {
    fileprivate var containsHeaderTerminator: Bool {
        range(of: Data("\r\n\r\n".utf8)) != nil
    }
}

// MARK: - Platform shims

#if os(Windows)
private typealias SocketHandle = SOCKET
private let invalidSocket = INVALID_SOCKET
private let sockOptStream = SOCK_STREAM
private typealias sockOptValue = CChar
// Winsock's sockaddr_in.sin_family is an ADDRESS_FAMILY (UInt16).
private func addressFamily(_ family: Int32) -> ADDRESS_FAMILY { ADDRESS_FAMILY(family) }
private var loopbackAddress: IN_ADDR {
    var addr = IN_ADDR()
    addr.S_un.S_addr = UInt32(0x7f_00_00_01).bigEndian
    return addr
}
private func closeSocket(_ socket: SocketHandle) { closesocket(socket) }
private func recvBytes(_ socket: SocketHandle, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Int(recv(socket, buffer.assumingMemoryBound(to: CChar.self), Int32(count), 0))
}
private func sendBytes(_ socket: SocketHandle, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Int(send(socket, buffer.assumingMemoryBound(to: CChar.self), Int32(count), 0))
}
#else
private typealias SocketHandle = Int32
private let invalidSocket: Int32 = -1
#if canImport(Glibc)
private let sockOptStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockOptStream = SOCK_STREAM
#endif
private typealias sockOptValue = Int32
private func addressFamily(_ family: Int32) -> sa_family_t { sa_family_t(family) }
private var loopbackAddress: in_addr {
    in_addr(s_addr: UInt32(0x7f_00_00_01).bigEndian)
}
private func closeSocket(_ socket: SocketHandle) { close(socket) }
private func recvBytes(_ socket: SocketHandle, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    recv(socket, buffer, count, 0)
}
private func sendBytes(_ socket: SocketHandle, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    send(socket, buffer, count, 0)
}
#endif

import Foundation
import Network

/// Minimal single-purpose HTTP server so a guest can scan a QR code and
/// download their photo directly, entirely offline (no cloud, no backend).
/// Only reachable when this device and the guest's phone share a network —
/// which requires the camera to be joined to that same venue Wi-Fi
/// (infrastructure mode) rather than creating its own private AP, since
/// that's what puts the booth device and guests on one subnet together.
///
/// Deliberately not a general-purpose HTTP server: one route, GET only,
/// serves a single file straight off disk. No third-party dependency,
/// matching the rest of this app's "no backend" constraint.
public actor LocalPhotoServer {
    public static let shared = LocalPhotoServer()

    /// Fixed rather than ephemeral so the QR code's URL doesn't depend on
    /// waiting for NWListener to report an assigned port before it can be
    /// rendered.
    public static let port: UInt16 = 8942

    private var listener: NWListener?

    /// Random per-photo token -> file, minted only when a guest actually
    /// requests a share URL. Filenames alone were predictable timestamps
    /// (IMG_<millisecond-epoch>.jpg) served with no access control — any
    /// device on the venue Wi-Fi, not just the guest who scanned the QR
    /// code, could enumerate nearby timestamps and pull down other guests'
    /// photos. The URL now carries an unguessable token instead of the
    /// real filename, and the server only ever serves tokens it minted.
    private var tokens: [String: URL] = [:]

    private init() {}

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw LocalPhotoServerError.invalidPort
        }
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { connection in
            Task { await Self.shared.handle(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// URL a guest's phone can reach this photo at — nil if we don't have a
    /// Wi-Fi IPv4 address (e.g. not actually joined to a network). Mints a
    /// fresh random token for this photo each call rather than exposing its
    /// real filename.
    public func url(forPhoto photoURL: URL) -> URL? {
        guard let ip = NetworkInfo.wifiIPv4Address() else { return nil }
        let token = (0..<24).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }
        let tokenString = String(token)
        tokens[tokenString] = photoURL
        return URL(string: "http://\(ip):\(Self.port)/photos/\(tokenString)")
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let requestLine = try await readRequestLine(on: connection)
            guard let path = parsePath(fromRequestLine: requestLine) else {
                await respond(connection, status: "400 Bad Request", body: Data())
                return
            }
            guard let fileURL = resolvePhotoPath(path), let data = try? Data(contentsOf: fileURL) else {
                await respond(connection, status: "404 Not Found", body: Data("Not found".utf8))
                return
            }
            let contentType = fileURL.pathExtension.lowercased() == "gif" ? "image/gif" : "image/jpeg"
            await respond(connection, status: "200 OK", body: data, contentType: contentType)
        } catch {
            connection.cancel()
        }
    }

    /// Reads up to the end of the request line ("GET /path HTTP/1.1\r\n") —
    /// that's the only thing this server needs to route. Any headers after
    /// it are left unread on the socket; harmless here since we send the
    /// full response and close immediately after, and a browser's simple
    /// GET request typically arrives in one packet anyway.
    private func readRequestLine(on connection: NWConnection) async throws -> String {
        var collected = Data()
        let terminator = Data("\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: LocalPhotoServerError.connectionClosed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            collected.append(chunk)
            if collected.count > 8192 { throw LocalPhotoServerError.requestTooLarge }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private func parsePath(fromRequestLine line: String) -> String? {
        // "GET /photos/IMG_123.jpg HTTP/1.1\r\n..."
        let firstLine = line.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? line
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return parts[1].removingPercentEncoding ?? String(parts[1])
    }

    private func resolvePhotoPath(_ path: String) -> URL? {
        guard path.hasPrefix("/photos/") else { return nil }
        let token = String(path.dropFirst("/photos/".count))
        // Only ever serves a token this server itself minted via
        // url(forPhoto:) — no path traversal surface at all, since the
        // request never supplies a filename or path, just an opaque token
        // looked up against server-side state.
        return tokens[token]
    }

    private func respond(_ connection: NWConnection, status: String, body: Data, contentType: String = "text/plain") async {
        var response = Data("HTTP/1.1 \(status)\r\n".utf8)
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum LocalPhotoServerError: Error {
    case invalidPort
    case connectionClosed
    case requestTooLarge
}

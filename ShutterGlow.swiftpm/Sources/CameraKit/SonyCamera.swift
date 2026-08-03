import Foundation

public enum SonyCameraError: Error, LocalizedError {
    case apiError(method: String, code: Int)
    case badLiveviewStream
    case noPostviewURL
    case invalidHost(String)

    public var errorDescription: String? {
        switch self {
        case .apiError(let method, let code): "Sony API \(method) failed (code \(code))"
        case .badLiveviewStream: "Sony liveview stream ended unexpectedly"
        case .noPostviewURL: "Sony camera returned no image URL after capture"
        case .invalidHost(let host): "Couldn't build a camera URL from '\(host)'"
        }
    }
}

/// Sony body over the (legacy but widely supported) Camera Remote API —
/// JSON-RPC over HTTP on the camera's own Wi-Fi, NOT PTP/IP, which is why
/// this conforms to TetheredCamera directly with no PTP transport
/// underneath. Covers the many α/RX bodies with "Smart Remote
/// Control"/"Control with Smartphone". UNVERIFIED on hardware — beta.
///
/// Protocol summary (Sony Camera Remote API v1.x):
/// - endpoint: http://<ip>:8080/sony/camera, JSON-RPC bodies
/// - startRecMode -> remote session; setPostviewImageSize("Original") best-effort
/// - startLiveview -> URL of a chunked stream: 8-byte common header +
///   128-byte payload header (start code 24 35 68 79, 3-byte big-endian
///   JPEG size, 1-byte padding size) + JPEG + padding, repeating
/// - actTakePicture -> postview URL (40403 = still busy -> awaitTakePicture)
public actor SonyCamera: TetheredCamera {
    private let endpoint: URL
    private let session: URLSession
    private var requestId = 0
    private var liveViewTask: Task<Void, Never>?
    private var liveViewContinuation: AsyncStream<Data>.Continuation?

    /// Fails rather than force-unwrapping when `host` can't form a valid
    /// URL — notably IPv6 link-local addresses with a zone ID (e.g.
    /// `fe80::1%en0`, which iOS network APIs can hand back) aren't valid
    /// inside a bare URL string, and `URL(string:)` returns nil for them.
    public init?(host: String) {
        guard let url = URL(string: "http://\(host):8080/sony/camera") else { return nil }
        endpoint = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        // Battery arrives via getEvent on this API — not polled yet (beta).
    }

    public func enterRemoteMode() async throws {
        _ = try await call("startRecMode")
        // Full-resolution postview when the body supports it; the 2M
        // default still works everywhere else, so a failure here is fine.
        _ = try? await call("setPostviewImageSize", params: ["Original"])
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let result = try await call("startLiveview")
        guard let urlString = (result.first as? String), let url = URL(string: urlString) else {
            throw SonyCameraError.badLiveviewStream
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(1))
        liveViewContinuation = continuation
        startLiveviewReader(url: url)
        return stream
    }

    private var chunkedReader: ChunkedHTTPStream?

    /// Sony's stream runs at several fps of continuous JPEG data — the
    /// previous `for try await byte in bytes` drove Swift's AsyncSequence
    /// machinery (and a single-byte Data.append call) once PER BYTE, real
    /// overhead on a hot path with no built-in "read in chunks" option on
    /// URLSession's async-bytes API. A URLSessionDataDelegate instead
    /// receives whole network chunks (tens of KB) per callback — the
    /// parser below is unchanged; only how bytes arrive into its buffer is
    /// different.
    private func startLiveviewReader(url: URL) {
        liveViewTask?.cancel()
        // Cancel the previous reader before replacing it — otherwise the old
        // HTTP data task keeps downloading multipart JPEG from the camera
        // forever (cancelling liveViewTask stops the CONSUMER, not the
        // underlying URLSession task), leaking bandwidth/battery per restart.
        chunkedReader?.cancel()
        let reader = ChunkedHTTPStream()
        chunkedReader = reader
        let chunks = reader.start(url: url)
        liveViewTask = Task { [weak self] in
            var buffer = Data()
            for await chunk in chunks {
                if Task.isCancelled { break }
                buffer.append(chunk)
                while let (jpeg, consumed) = SonyLiveviewParser.nextFrame(in: buffer) {
                    if let jpeg {
                        await self?.yieldFrame(jpeg)
                    }
                    buffer.removeFirst(consumed)
                }
                // Runaway guard — a corrupt stream must not grow forever.
                if buffer.count > 4_000_000 { buffer.removeAll(keepingCapacity: true) }
            }
            await self?.finishLiveview()
        }
    }

    private func yieldFrame(_ jpeg: Data) {
        liveViewContinuation?.yield(jpeg)
    }

    private func finishLiveview() {
        liveViewContinuation?.finish()
        liveViewContinuation = nil
    }

    public func capturePhoto() async throws -> Data {
        var postviewURL: URL?
        do {
            let result = try await call("actTakePicture")
            postviewURL = Self.firstURL(in: result)
        } catch SonyCameraError.apiError(_, let code) where code == 40403 {
            // Body still processing — long-poll until the shot resolves.
            for _ in 0..<10 {
                if let result = try? await call("awaitTakePicture"),
                   let url = Self.firstURL(in: result) {
                    postviewURL = url
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        guard let postviewURL else { throw SonyCameraError.noPostviewURL }
        let (data, _) = try await session.data(from: postviewURL)
        return data
    }

    /// actTakePicture returns [[String]] — the postview URL nested one deep.
    private static func firstURL(in result: [Any]) -> URL? {
        for element in result {
            if let urls = element as? [String], let first = urls.first, let url = URL(string: first) {
                return url
            }
            if let string = element as? String, string.hasPrefix("http"), let url = URL(string: string) {
                return url
            }
        }
        return nil
    }

    public func disconnect() async {
        liveViewTask?.cancel()
        chunkedReader?.cancel()
        chunkedReader = nil
        liveViewContinuation?.finish()
        liveViewContinuation = nil
        // Awaited: a camera left in RecMode keeps its own session open, and
        // the next connect can be refused because the previous one was never
        // closed. Same class of bug as the Canon PC-mode lockup.
        _ = try? await call("stopRecMode")
    }

    // MARK: - JSON-RPC plumbing

    private func call(_ method: String, params: [Any] = []) async throws -> [Any] {
        requestId += 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "params": params,
            "id": requestId,
            "version": "1.0"
        ])

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? [Any], let code = error.first as? Int {
            throw SonyCameraError.apiError(method: method, code: code)
        }
        return json["result"] as? [Any] ?? []
    }
}

/// Bridges a long-lived streaming HTTP GET into an `AsyncStream<Data>` of
/// network-sized chunks, using `URLSessionDataDelegate` (callback-based,
/// whole-chunk `didReceive data:`) instead of `URLSession.bytes(from:)`'s
/// per-byte AsyncSequence — see startLiveviewReader's doc comment for why.
/// `@unchecked Sendable`: NSObject/delegate callbacks aren't actor-isolated,
/// but every mutable property here is only ever touched from those
/// callbacks (URLSession's own internal delegate queue), which serializes
/// them for us.
private final class ChunkedHTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncStream<Data>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    func start(url: URL) -> AsyncStream<Data> {
        let config = URLSessionConfiguration.ephemeral
        // No request timeout — this is a long-lived streaming connection,
        // not a single request/response; a fixed timeout would cut the
        // live feed off mid-session.
        config.timeoutIntervalForRequest = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
        return stream
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.finish()
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation?.finish()
        continuation = nil
        // URLSession holds a STRONG reference to its delegate (self) until
        // invalidated. Without this, every naturally-ended live view leaks a
        // ChunkedHTTPStream + URLSession pair for the life of the process —
        // only the explicit cancel() path used to invalidate.
        session.finishTasksAndInvalidate()
    }
}

/// Frame extractor for Sony's liveview stream format.
public enum SonyLiveviewParser {
    /// Attempts to parse one complete payload off the front of `buffer`.
    /// Returns (jpeg-or-nil, bytesConsumed) when a full payload is present
    /// — jpeg is nil for non-image payload types, which are skipped — or
    /// nil when more bytes are needed.
    public static func nextFrame(in buffer: Data) -> (Data?, Int)? {
        // Resync: find the 0xFF start byte of a common header.
        guard let start = buffer.firstIndex(of: 0xFF) else {
            return buffer.isEmpty ? nil : (nil, buffer.count)
        }
        let skipped = start - buffer.startIndex
        let b = buffer[start...]
        // 8-byte common header + 128-byte payload header
        guard b.count >= 136 else { return skipped > 0 ? (nil, skipped) : nil }

        let payloadType = b[b.startIndex + 1]
        let header = b.dropFirst(8)
        // payload header start code 24 35 68 79
        guard header[header.startIndex] == 0x24,
              header[header.startIndex + 1] == 0x35,
              header[header.startIndex + 2] == 0x68,
              header[header.startIndex + 3] == 0x79 else {
            // Not a real header — skip this 0xFF and resync.
            return (nil, skipped + 1)
        }

        let size = (Int(header[header.startIndex + 4]) << 16)
            | (Int(header[header.startIndex + 5]) << 8)
            | Int(header[header.startIndex + 6])
        let padding = Int(header[header.startIndex + 7])
        let total = 8 + 128 + size + padding
        guard b.count >= total else { return skipped > 0 ? (nil, skipped) : nil }

        let jpegStart = b.startIndex + 136
        let jpeg = b.subdata(in: jpegStart..<(jpegStart + size))
        // type 0x01 = liveview image; anything else (frame info etc.) skipped
        return (payloadType == 0x01 ? jpeg : nil, skipped + total)
    }
}

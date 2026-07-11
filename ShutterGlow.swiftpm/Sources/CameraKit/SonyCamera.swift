import Foundation

public enum SonyCameraError: Error, LocalizedError {
    case apiError(method: String, code: Int)
    case badLiveviewStream
    case noPostviewURL

    public var errorDescription: String? {
        switch self {
        case .apiError(let method, let code): "Sony API \(method) failed (code \(code))"
        case .badLiveviewStream: "Sony liveview stream ended unexpectedly"
        case .noPostviewURL: "Sony camera returned no image URL after capture"
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

    public init(host: String) {
        endpoint = URL(string: "http://\(host):8080/sony/camera")!
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

    private func startLiveviewReader(url: URL) {
        liveViewTask?.cancel()
        liveViewTask = Task { [weak self, session] in
            do {
                let (bytes, _) = try await session.bytes(from: url)
                var buffer = Data()
                for try await byte in bytes {
                    if Task.isCancelled { return }
                    buffer.append(byte)
                    // Parse complete frames off the front of the buffer.
                    while let (jpeg, consumed) = SonyLiveviewParser.nextFrame(in: buffer) {
                        if let jpeg {
                            await self?.yieldFrame(jpeg)
                        }
                        buffer.removeFirst(consumed)
                    }
                    // Runaway guard — a corrupt stream must not grow forever.
                    if buffer.count > 4_000_000 { buffer.removeAll(keepingCapacity: true) }
                }
            } catch {
                // Stream dropped — surface as a finished feed; the booth
                // shows its no-feed state rather than crashing the flow.
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

    public func disconnect() {
        liveViewTask?.cancel()
        liveViewContinuation?.finish()
        liveViewContinuation = nil
        Task { _ = try? await call("stopRecMode") }
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

/// Frame extractor for Sony's liveview stream format.
enum SonyLiveviewParser {
    /// Attempts to parse one complete payload off the front of `buffer`.
    /// Returns (jpeg-or-nil, bytesConsumed) when a full payload is present
    /// — jpeg is nil for non-image payload types, which are skipped — or
    /// nil when more bytes are needed.
    static func nextFrame(in buffer: Data) -> (Data?, Int)? {
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

import Foundation

/// Synthesizes a rough "live view" for cameras with no real live-view path
/// at all — today that's standard PTP bodies (Fujifilm, generic/other)
/// whose PTP dialect has no live-view extension, unlike Canon's vendor
/// opcodes. Wraps any TetheredCamera and samples real captures on a slow
/// interval instead of a true continuous feed.
///
/// Real trade-off, disclosed in the UI, never hidden: every "frame" here
/// fires the camera's actual mechanical shutter — this is not free like
/// Wi-Fi PTP/IP or UVC live view (see UVCWebcamCamera). Sampled slowly on
/// purpose (default every 2.5s) to bound shutter-actuation wear and
/// flash-strobing. Last-resort fallback only — never wrap a camera that
/// already has a real feed (Canon/Nikon), since this would strictly
/// downgrade it.
public actor BurstLiveViewCamera: TetheredCamera {
    private let wrapped: any TetheredCamera
    private let intervalNanoseconds: UInt64
    private var previewTask: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?

    public init(wrapping camera: any TetheredCamera, intervalSeconds: Double = 2.5) {
        self.wrapped = camera
        self.intervalNanoseconds = UInt64(intervalSeconds * 1_000_000_000)
    }

    public func enterRemoteMode() async throws {
        try await wrapped.enterRemoteMode()
    }

    public func startLiveView() async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        previewTask?.cancel()
        previewTask = Task { [weak self, wrapped, intervalNanoseconds] in
            while !Task.isCancelled {
                if let jpeg = try? await wrapped.capturePhoto() {
                    await self?.yieldFrame(jpeg)
                }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
        return stream
    }

    private func yieldFrame(_ jpeg: Data) {
        continuation?.yield(jpeg)
    }

    /// The guest's real photo — the same call the preview loop uses
    /// internally, so a request arriving mid-cycle simply waits its turn
    /// on the wrapped camera's own actor isolation rather than colliding
    /// with it. Slightly higher worst-case latency than a camera with a
    /// real live-view feed; acceptable for a last-resort fallback.
    public func capturePhoto() async throws -> Data {
        try await wrapped.capturePhoto()
    }

    public func setBatterySink(_ sink: @escaping @Sendable (UInt32) -> Void) {
        let wrapped = wrapped
        Task { await wrapped.setBatterySink(sink) }
    }

    public func disconnect() {
        previewTask?.cancel()
        previewTask = nil
        continuation?.finish()
        continuation = nil
        let wrapped = wrapped
        Task { await wrapped.disconnect() }
    }
}

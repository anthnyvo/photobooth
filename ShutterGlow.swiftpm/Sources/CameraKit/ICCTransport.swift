import Foundation
import ImageCaptureCore

/// Events the transport surfaces to the protocol layer / UI.
public enum TransportEvent: Sendable {
    case deviceFound(name: String)
    case sessionOpened
    /// Fired after ImageCaptureCore finishes indexing the camera's content
    /// catalog. PTP passthrough is NOT authorized before this point
    /// (error -21249 notAuthorizedToSendCommand) — see FB7593726.
    case ready
    case deviceRemoved
    case fileAdded(name: String, sizeBytes: Int)
    case log(String)
}

public struct PTPTransactionResult: Sendable {
    public let payload: Data
    public let response: PTPContainer?
    /// The response-container blob as the transport received it.
    public let rawInbound: Data
    /// ImageCaptureCore's passthrough completion hands back TWO blobs, and
    /// the FIRST is the device-to-host data phase. Kept separately because
    /// PassthroughDiagnostic reports on it; `payload` is normally what you
    /// want. Empty on PTPIPTransport, which speaks the wire protocol
    /// directly and has no such split.
    public var rawFirstParam: Data = Data()

    /// Assembles a result from ImageCaptureCore's two-blob reply.
    ///
    /// This is the whole fix for the bug that cost three weeks and an entire
    /// Wi-Fi transport. `requestSendPTPCommand`'s completion splits the reply:
    /// the FIRST blob is the data phase, the SECOND is the response container.
    /// The transport read only the second, so `payload` came back empty for
    /// every command that actually returns data — live view above all, but
    /// also GetEvent and property reads. A bare 12-to-20-byte `0x2001` was
    /// then misread as proof that iOS never surfaces the data phase at all.
    ///
    /// Hardware-verified on the EOS R, 2026-08-01: param 1 carried a
    /// 184KB live-view JPEG (structured Canon framing, no PTP header of its
    /// own), param 2 was a 20-byte response container. See PHASE0.md.
    ///
    /// A pure function so it can be tested without an ICCameraDevice.
    public static func from(dataPhase: Data, responseBlob: Data) -> PTPTransactionResult {
        // The response always comes from blob 2. splitInboundBlob also copes
        // with a transport that appends the response to its data rather than
        // splitting, which is why the fallback below is not dead code.
        let (fallbackPayload, response) = PTPContainer.splitInboundBlob(responseBlob)
        // Prefer the real data phase. Falling back to the old single-blob
        // split when it is empty keeps commands that return no data (capture,
        // SetRemoteMode) behaving exactly as they already did — those were
        // never broken, and this fix must not "repair" them into something
        // different.
        let payload = dataPhase.isEmpty ? fallbackPayload : dataPhase
        return PTPTransactionResult(payload: payload, response: response,
                                    rawInbound: responseBlob, rawFirstParam: dataPhase)
    }
}

public enum TransportError: Error {
    case noDevice
    case notReady
    case sendFailed(underlying: Error?)
    case downloadFailed(underlying: Error?)
    case timeout(String)
}

/// Wraps ICDeviceBrowser/ICCameraDevice. Sole ImageCaptureCore touchpoint in
/// the codebase. PTPIPTransport is the Wi-Fi sibling, conforming to the same
/// PTPTransport protocol so EOSCamera's logic is unchanged either way.
///
/// Phase 0 concluded USB live view's data phase was unreachable on iOS and
/// built the entire Wi-Fi transport because of it. **That was wrong, and this
/// class was where it was wrong**: the passthrough completion returns two
/// blobs, the data phase is in the first, and this code read only the second
/// and discarded the first with `_`. Fixed 2026-08-01 after a hardware test
/// found a 184KB live-view JPEG in the discarded parameter. See
/// `PTPTransactionResult.from` and docs/PHASE0.md.
public final class ICCTransport: NSObject, PTPTransport, @unchecked Sendable {

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var isReady = false
    private var transactionID: UInt32 = 0
    private let sendGate = SerialGate()

    private var eventContinuation: AsyncStream<TransportEvent>.Continuation?
    public private(set) lazy var events: AsyncStream<TransportEvent> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    /// Single-slot waiter design (not a FIFO queue): only one capture is
    /// ever in flight, so a FIFO here just misattributes files across
    /// captures. A timed-out capture whose file-added event arrives late
    /// used to hand that stale file to the NEXT capture (silently wrong
    /// photo), or — if the waiter rather than the file was what timed out —
    /// leave every later capture's waiter permanently queued behind an
    /// abandoned one (permanent stall). generation guards a captured file
    /// arriving right as a new wait is being armed.
    private var pendingFile: (file: ICCameraFile, at: Date)?
    private var currentWaiter: (continuation: CheckedContinuation<ICCameraFile, Error>, generation: Int)?
    private var waiterGeneration = 0

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        // iOS only browses local (USB) cameras; the mask setup that macOS
        // needs is not required, but setting it is harmless.
        browser.start()
        emit(.log("ICDeviceBrowser started"))
    }

    public func stop() {
        camera?.requestCloseSession()
        browser.stop()
    }

    /// PTPTransport conformance. Same teardown as `stop()`, under the name
    /// callers holding `any PTPTransport` can reach.
    public func disconnect() {
        stop()
    }

    /// Whether a camera has been seen on the cable. Lets a caller probe for a
    /// USB body and fall back to Wi-Fi when there isn't one, without having to
    /// consume the event stream (which has a single consumer) to find out.
    public var hasDevice: Bool { camera != nil }

    /// Name ImageCaptureCore reports for the attached body, e.g. "Canon EOS R".
    /// Used to pick which protocol actor to drive it with — see
    /// `TetheredCameraFactory`.
    public private(set) var deviceName: String?

    // MARK: - PTP passthrough

    /// Send one PTP transaction and wait for the reply blob.
    /// Serialized: PTP is strictly one-transaction-at-a-time per session.
    public func send(code: UInt16, parameters: [UInt32] = [],
                     outData: Data? = nil) async throws -> PTPTransactionResult {
        try await sendGate.run {
            guard let camera = self.camera else { throw TransportError.noDevice }
            guard self.isReady else { throw TransportError.notReady }
            self.transactionID &+= 1
            let container = PTPContainer(kind: .command, code: code,
                                         transactionID: self.transactionID,
                                         parameters: parameters)
            let command = container.encoded()

            return try await withCheckedThrowingContinuation { continuation in
                camera.requestSendPTPCommand(command, outData: outData) { dataPhase, responseBlob, error in
                    if let error {
                        continuation.resume(throwing: TransportError.sendFailed(underlying: error))
                        return
                    }
                    // `as Data?` rather than a plain `??`: ImageCaptureCore's
                    // block has no nullability annotations, so these import as
                    // Data, Data? or Data! depending on SDK, and this form
                    // compiles (and stays nil-safe) in all three.
                    continuation.resume(returning: PTPTransactionResult.from(
                        dataPhase: (dataPhase as Data?) ?? Data(),
                        responseBlob: (responseBlob as Data?) ?? Data()))
                }
            }
        }
    }

    // MARK: - File retrieval (via ImageCaptureCore's own catalog)

    /// Wait for the next file the camera announces (i.e. the shot just taken),
    /// then read its bytes. Spike strategy: let ICC do object transfer rather
    /// than hand-rolling GetPartialObject — revisit in Phase 1 if too slow.
    public func nextCapturedFile(timeout: TimeInterval = 15) async throws -> Data {
        let file = try await waitForCapturedFile(timeout: timeout)

        return try await withCheckedThrowingContinuation { continuation in
            let size = Int(truncatingIfNeeded: file.fileSize)
            file.requestReadData(atOffset: 0, length: off_t(size)) { data, error in
                if let data, error == nil {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TransportError.downloadFailed(underlying: error))
                }
            }
        }
    }

    // MARK: - Internals

    /// All mutation of pendingFile/currentWaiter/waiterGeneration happens on
    /// the main queue, matching where ICDeviceBrowserDelegate callbacks
    /// land (this class predates Swift concurrency and isn't an actor).
    private func waitForCapturedFile(timeout: TimeInterval) async throws -> ICCameraFile {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                // Supersede any stale waiter (a previous capture that
                // errored above this layer without ever resolving it).
                self.currentWaiter?.continuation.resume(throwing: TransportError.timeout("superseded by a new capture"))
                self.currentWaiter = nil
                self.waiterGeneration += 1
                let generation = self.waiterGeneration

                if let pending = self.pendingFile, Date().timeIntervalSince(pending.at) < 2 {
                    self.pendingFile = nil
                    continuation.resume(returning: pending.file)
                    return
                }
                self.pendingFile = nil
                self.currentWaiter = (continuation, generation)

                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    DispatchQueue.main.async { self.expireWaiter(generation: generation) }
                }
            }
        }
    }

    private func expireWaiter(generation: Int) {
        guard generation == waiterGeneration, let waiter = currentWaiter else { return }
        currentWaiter = nil
        waiter.continuation.resume(throwing: TransportError.timeout("no file announced within timeout of capture"))
    }

    private func emit(_ event: TransportEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ICCTransport: ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        camera = cam
        cam.delegate = self
        deviceName = device.name
        emit(.deviceFound(name: device.name ?? "unknown camera"))
        cam.requestOpenSession()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera {
            camera = nil
            isReady = false
            emit(.deviceRemoved)
        }
    }
}

// MARK: - ICCameraDeviceDelegate

extension ICCTransport: ICCameraDeviceDelegate {
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            emit(.log("open session failed: \(error)"))
        } else {
            emit(.sessionOpened)
        }
    }

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        isReady = true
        // Note: requestEnableTethering() is macOS-only (compiler-confirmed
        // unavailable on iOS). On iPadOS the PTP passthrough itself is the
        // whole tethering surface — nothing to enable first.
        emit(.ready)
    }

    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        for item in items {
            guard let file = item as? ICCameraFile else { continue }
            emit(.fileAdded(name: file.name ?? "?", sizeBytes: Int(truncatingIfNeeded: file.fileSize)))
            DispatchQueue.main.async {
                if let waiter = self.currentWaiter {
                    self.currentWaiter = nil
                    waiter.continuation.resume(returning: file)
                } else {
                    self.pendingFile = (file, Date())
                }
            }
        }
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        isReady = false
        emit(.log("session closed \(error.map { "with error: \($0)" } ?? "cleanly")"))
    }

    public func didRemove(_ device: ICDevice) {
        if device === camera {
            camera = nil
            isReady = false
            emit(.deviceRemoved)
        }
    }

    // Required-but-unused delegate methods.
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        emit(.log("PTP event: \(eventData as NSData)"))
    }
    public func deviceDidBecomeReady(_ device: ICDevice) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Serializes async operations (PTP allows one in-flight transaction).
/// Shared by both transports (USB and PTP/IP), hence not file-private.
///
/// Two earlier designs both failed under real hardware traffic — an
/// acquire/release flag (actor-isolated `isLocked` + waiter continuations)
/// and, after that, explicit Task-handle chaining (each call awaiting the
/// previous call's `Task.value` before starting its own). Both should have
/// worked by every reasoning about Swift's actor/Task semantics available,
/// and both still let two different PTP transactions' packets interleave on
/// the same TCP connection — e.g. transaction 9's own Start Data Packet
/// immediately followed by a read that transaction 10 (a completely
/// separate call) attributed to itself, proven by tagging every packet log
/// with its owning (opcode, transactionID) at the point of origin, not by
/// display order.
///
/// This version doesn't reason about isolation/suspension semantics at
/// all — it sidesteps the question by construction. A single background
/// Task consumes jobs from an AsyncStream one at a time in a plain
/// `for await job in stream { await job() }` loop; the next job's body
/// cannot start running until `await job()` for the current one returns,
/// because that's just what a single sequential loop is. There's no shared
/// flag or task handle for a subtle bug to hide in.
actor SerialGate {
    private let stream: AsyncStream<@Sendable () async -> Void>
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private var workerTask: Task<Void, Never>?

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        let jobs = stream
        workerTask = Task {
            for await job in jobs {
                await job()
            }
        }
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        startWorkerIfNeeded()
        return try await withCheckedThrowingContinuation { (resume: CheckedContinuation<T, Error>) in
            continuation.yield {
                do {
                    let result = try await operation()
                    resume.resume(returning: result)
                } catch {
                    resume.resume(throwing: error)
                }
            }
        }
    }
}

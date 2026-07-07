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
    /// Raw blob exactly as ImageCaptureCore returned it — Phase 0 needs this
    /// to learn the real shape of passthrough replies on the EOS R.
    public let rawInbound: Data
}

public enum TransportError: Error {
    case noDevice
    case notReady
    case sendFailed(underlying: Error?)
    case downloadFailed(underlying: Error?)
    case timeout(String)
}

/// Wraps ICDeviceBrowser/ICCameraDevice. Sole ImageCaptureCore touchpoint in
/// the codebase. USB live view's data phase turned out not to be retrievable
/// through this API on iOS (Phase 0 finding) — PTPIPTransport is the Wi-Fi
/// sibling that exists because of that, conforming to the same PTPTransport
/// protocol so EOSCamera's logic is unchanged either way.
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

    /// Files ImageCaptureCore surfaces after a capture, keyed by name.
    private var pendingFiles: [String: ICCameraFile] = [:]
    private var fileWaiters: [(CheckedContinuation<ICCameraFile, Error>)] = []

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
                camera.requestSendPTPCommand(command, outData: outData) { _, inData, error in
                    if let error {
                        continuation.resume(throwing: TransportError.sendFailed(underlying: error))
                        return
                    }
                    let blob = inData
                    let (payload, response) = PTPContainer.splitInboundBlob(blob)
                    continuation.resume(returning: PTPTransactionResult(
                        payload: payload, response: response, rawInbound: blob))
                }
            }
        }
    }

    // MARK: - File retrieval (via ImageCaptureCore's own catalog)

    /// Wait for the next file the camera announces (i.e. the shot just taken),
    /// then read its bytes. Spike strategy: let ICC do object transfer rather
    /// than hand-rolling GetPartialObject — revisit in Phase 1 if too slow.
    public func nextCapturedFile(timeout: TimeInterval = 15) async throws -> Data {
        let file: ICCameraFile = try await withThrowingTaskGroup(of: ICCameraFile.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.main.async {
                        if let (_, existing) = self.pendingFiles.popFirst() {
                            continuation.resume(returning: existing)
                        } else {
                            self.fileWaiters.append(continuation)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TransportError.timeout("no file announced within \(timeout)s of capture")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

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
                if let waiter = self.fileWaiters.first {
                    self.fileWaiters.removeFirst()
                    waiter.resume(returning: file)
                } else {
                    self.pendingFiles[file.name ?? UUID().uuidString] = file
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
/// Hardware proof this needs to be airtight: with an earlier acquire/release
/// version of this gate (isLocked flag + a waiter queue, both actor-isolated),
/// real traffic still showed two different PTP transactions' packets
/// interleaved mid-read on the same TCP connection — e.g. transaction 8's
/// Start Data Packet immediately followed by transaction 9's Data Packet,
/// each tagged at the point of origin, so it wasn't a logging artifact.
/// The likely cause: once `operation()` suspends on a *different* actor
/// (PTPIPTransport, for the actual socket I/O), the gate's own actor
/// executor is free again — an isLocked check doesn't stop a *new* call to
/// `run` from being serviced by that free executor, because the flag lives
/// in the same isolation domain the runtime is happy to re-enter.
///
/// This version doesn't depend on any of that: each call explicitly chains
/// onto a `Task` handle for the previous call and awaits its completion via
/// `.value` before running its own operation. A `Task.value` await is
/// documented to only resume once that exact task's body has finished, full
/// stop — there's no isolation-domain subtlety left to get wrong.
actor SerialGate {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previousTail = tail
        let resultTask = Task<T, Error> {
            _ = await previousTail.value
            return try await operation()
        }
        tail = Task {
            _ = try? await resultTask.value
        }
        return try await resultTask.value
    }
}

import Foundation
import Network

/// Canon PTP over Wi-Fi (PTP/IP, CIPA DC-005). Same Canon vendor opcodes as
/// the USB path, different wire framing and (critically) full unrestricted
/// byte access — no ImageCaptureCore abstraction sitting between us and the
/// bytes, which is exactly the limitation that blocked USB live view.
///
/// Camera pairing: enable Wi-Fi on the body (Wireless communication settings
/// -> Wi-Fi -> connect to smartphone / EOS Utility), join that network from
/// the phone's Wi-Fi settings, then connect() with the camera's IP (Canon's
/// direct-connect mode typically hands out 192.168.1.1 to itself).
public actor PTPIPTransport: PTPTransport {

    // Opcodes with a data phase (either direction) — everything else is a
    // bare command/response with no payload.
    private static let dataPhaseOpcodes: Set<UInt16> = [
        CanonOp.getEvent, CanonOp.getViewFinderData, CanonOp.setDevicePropValueEx,
        CanonOp.getPartialObject, StandardPTPOp.getObjectInfo, StandardPTPOp.getObject,
        NikonOp.getLiveViewImage
    ]

    private let host: String
    private let port: UInt16
    private let friendlyName: String

    /// Fixed, not random: Canon's pairing model remembers a connecting
    /// client by this GUID (Bluetooth-like trust), so it must be identical
    /// across every connection attempt from this app, not regenerated per
    /// launch — a random GUID looks like a different, unrecognized device
    /// every time and gets an Init Fail.
    private static let clientGUID: [UInt8] = [
        0x50, 0x68, 0x6F, 0x74, 0x6F, 0x62, 0x6F, 0x6F,
        0x74, 0x68, 0x53, 0x70, 0x69, 0x6B, 0x65, 0x00
    ]

    private var commandConnection: NWConnection?
    private var eventConnection: NWConnection?
    private var transactionID: UInt32 = 0
    private var connectionNumber: UInt32 = 0
    private let sendGate = SerialGate()

    // Built eagerly in init rather than lazily, so `events` can be a plain
    // nonisolated `let` — callers subscribe without needing to hop onto this
    // actor first, same as ICCTransport's (non-actor) property.
    public nonisolated let events: AsyncStream<TransportEvent>
    private let eventContinuation: AsyncStream<TransportEvent>.Continuation

    /// Standard PTP events (ObjectAdded in particular) arrive on the
    /// dedicated event connection established during the handshake — a
    /// separate mechanism from Canon's own GetEvent command/response
    /// polling on the command connection. Phase 1 finding: capture was
    /// timing out waiting for ObjectAdded via GetEvent polling alone;
    /// this connection is what actually carries it.
    ///
    /// One-shot waiter, NOT an AsyncStream: an AsyncStream terminates for
    /// good the moment its consuming task is cancelled or its iterator is
    /// dropped — which is exactly what racing it against a timeout (or even
    /// finishing one successful wait) does. With the stream, the first
    /// capture killed the channel and every capture after it timed out.
    /// nil resume = timed out / superseded.
    private var objectAddedWaiter: CheckedContinuation<UInt32?, Never>?
    private var objectAddedWaiterGeneration = 0
    private var eventReaderTask: Task<Void, Never>?

    public init(host: String, port: UInt16 = PTPIPDefaults.port, friendlyName: String = "Photobooth") {
        self.host = host
        self.port = port
        self.friendlyName = friendlyName
        (self.events, self.eventContinuation) = AsyncStream<TransportEvent>.makeStream()
    }

    private func emit(_ event: TransportEvent) { eventContinuation.yield(event) }
    private func log(_ message: String) { emit(.log("[PTPIP] \(message)")) }

    // MARK: - Connect

    public func connect() async throws {
        log("connecting to \(host):\(port)")
        let command = try await openConnection()
        commandConnection = command

        let initReq = PTPIPPacket(type: .initCommandRequest,
                                  payload: PTPIPCodec.initCommandRequestPayload(guid: Self.clientGUID, friendlyName: friendlyName))
        try await write(initReq.encoded(), on: command)

        let ackPacket = try await readPacket(on: command)
        guard ackPacket.type == .initCommandAck else {
            if ackPacket.type == .initFail {
                throw PTPIPError.initFailed("camera rejected Init Command Request (Init Fail)")
            }
            throw PTPIPError.unexpectedPacketType(ackPacket.type.rawValue)
        }
        guard let ack = PTPIPCodec.parseInitCommandAck(ackPacket.payload) else {
            throw PTPIPError.malformedPacket("Init Command Ack too short")
        }
        connectionNumber = ack.connectionNumber
        log("Init Command Ack ok, connection #\(ack.connectionNumber), camera name '\(ack.cameraName)'")

        let event = try await openConnection()
        eventConnection = event
        let eventReq = PTPIPPacket(type: .initEventRequest,
                                   payload: PTPIPCodec.initEventRequestPayload(connectionNumber: connectionNumber))
        try await write(eventReq.encoded(), on: event)
        let eventAck = try await readPacket(on: event)
        guard eventAck.type == .initEventAck else {
            throw PTPIPError.unexpectedPacketType(eventAck.type.rawValue)
        }
        log("Init Event Ack ok — both connections established")
        startEventConnectionReader(on: event)

        // Standard PTP requires an explicit OpenSession before anything else
        // works (0x2003 SessionNotOpen otherwise). USB's ImageCaptureCore
        // does this invisibly via requestOpenSession(); over raw PTP/IP we
        // have to do it ourselves.
        let openResult = try await send(code: StandardPTPOp.openSession, parameters: [1], outData: nil)
        guard openResult.response?.code == PTPResponseCode.ok else {
            throw PTPIPError.initFailed("OpenSession failed: \(openResult.response.map { String(format: "0x%04X", $0.code) } ?? "no response")")
        }
        log("OpenSession ok")

        emit(.deviceFound(name: ack.cameraName.isEmpty ? "Canon (PTP/IP)" : ack.cameraName))
        emit(.sessionOpened)
        emit(.ready) // no ImageCaptureCore catalog-index gate over Wi-Fi
    }

    /// Continuously reads standard PTP Event packets (type 8) off the
    /// dedicated event connection and republishes ObjectAdded ones with
    /// their handle. This connection is otherwise idle — the Canon vendor
    /// GetEvent command polls the command connection instead — but per the
    /// PTP/IP spec this is precisely what it's for, and it's the channel
    /// that actually carries ObjectAdded on this body.
    private func startEventConnectionReader(on connection: NWConnection) {
        eventReaderTask?.cancel()
        eventReaderTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let packet = try await self.readPacket(on: connection, context: "event-channel")
                    guard packet.type == .event, packet.payload.count >= 10 else { continue }
                    let code = packet.payload.readLE(UInt16.self, at: 0)
                    if code == StandardPTPEvent.objectAdded {
                        let handle = packet.payload.readLE(UInt32.self, at: 6) // skip 2-byte code + 4-byte txn
                        await self.log("event channel: ObjectAdded handle 0x\(String(handle, radix: 16))")
                        await self.publishObjectAdded(handle)
                    }
                } catch {
                    await self.log("event channel read error: \(error)")
                    return
                }
            }
        }
    }

    private func publishObjectAdded(_ handle: UInt32) {
        if let waiter = objectAddedWaiter {
            objectAddedWaiter = nil
            waiter.resume(returning: handle)
        } else {
            // A fast body can emit ObjectAdded while the capture command's
            // own response is still in flight — before the caller has armed
            // the waiter. Hold it briefly; the freshness window in
            // nextCapturedFileViaObjectAdded keeps a stale between-captures
            // notification (card write, etc.) from satisfying a later wait.
            pendingObjectAdded = (handle, Date())
        }
    }

    private var pendingObjectAdded: (handle: UInt32, at: Date)?

    /// Awaits both sockets actually reaching `.cancelled`, unlike a bare
    /// `.cancel()` fire-and-forget — cancellation is asynchronous, and a fast
    /// reconnect that opens a new PTPIPTransport against the same host before
    /// the old sockets finish tearing down is the same class of race
    /// ICCTransport's USB disconnect() was fixed for: "that wait is the
    /// difference between reconnecting and not." Each wait is bounded so a
    /// yanked cable / dead Wi-Fi link (stateUpdateHandler never reaches
    /// `.cancelled`) cannot hang teardown.
    public func disconnect() async {
        objectAddedWaiter?.resume(returning: nil)
        objectAddedWaiter = nil
        eventReaderTask?.cancel()

        if let commandConnection { await Self.cancelAndAwait(commandConnection) }
        if let eventConnection { await Self.cancelAndAwait(eventConnection) }

        commandConnection = nil
        eventConnection = nil
        emit(.deviceRemoved)
    }

    private static func cancelAndAwait(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish() {
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                guard !already else { return }
                continuation.resume()
            }
            connection.stateUpdateHandler = { state in
                if case .cancelled = state { finish() }
            }
            connection.cancel()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                finish()
            }
        }
    }

    // MARK: - PTPTransport

    // Actor-isolated stored-property access has to go through methods (not
    // bare reads/writes) when called from inside the SerialGate closure
    // below, which executes on a different actor's isolation.
    private func requireCommandConnection() throws -> NWConnection {
        guard let commandConnection else { throw TransportError.noDevice }
        return commandConnection
    }

    private func nextTransactionID() -> UInt32 {
        transactionID &+= 1
        return transactionID
    }

    // Hard reentrancy guard: three separate serialization designs (an
    // acquire/release flag, explicit Task-chaining, a single-worker job
    // queue) all still showed two transactions' packets interleaved on the
    // wire under real hardware traffic, despite each looking airtight by
    // reasoning alone. Rather than trust reasoning further, this makes a
    // real violation impossible to miss: if a second call's network I/O
    // ever starts before the first one's finishes, this crashes immediately
    // with both contexts in the message, instead of silently corrupting
    // the byte stream the way the last several attempts did.
    private var busyContext: String?

    public func send(code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPTransactionResult {
        try await sendGate.run {
            let command = try await self.requireCommandConnection()
            let txn = await self.nextTransactionID()
            let hasDataPhase = Self.dataPhaseOpcodes.contains(code)
            let context = String(format: "opcode=0x%04X txn=%d", code, txn)
            // GetEvent and GetViewFinderData poll continuously (10ms/150ms
            // cadence) and drown a capped diagnostics log buffer in wire
            // noise within seconds — real evidence (e.g. the shutter
            // command's own response) scrolls out before anyone can read it.
            // Every other opcode is rare enough to log in full.
            let verbose = code != CanonOp.getViewFinderData && code != CanonOp.getEvent

            try await self.enterExclusive(context)
            do {
                // Data-Phase-Info per the PTP/IP spec: 1 = data-in (camera
                // → host), 2 = data-out (host → camera). Previously hardcoded
                // to 1 regardless of direction — masked because Canon bodies
                // tolerate it on SetDevicePropValueEx (the only data-out
                // opcode this app sends today), but a stricter body, or any
                // future data-out opcode on the beta Nikon/generic paths,
                // could reject the operation outright on a wrong direction.
                let dataPhase: UInt32 = hasDataPhase ? (outData != nil ? 2 : 1) : 0
                let reqPayload = PTPIPCodec.operationRequestPayload(
                    dataPhase: dataPhase, opcode: code, transactionID: txn, parameters: parameters)
                try await self.write(PTPIPPacket(type: .operationRequest, payload: reqPayload).encoded(), on: command)

                if let outData, hasDataPhase {
                    try await self.write(PTPIPPacket(type: .startDataPacket,
                        payload: PTPIPCodec.startDataPacketPayload(transactionID: txn, totalLength: UInt64(outData.count))).encoded(), on: command)
                    try await self.write(PTPIPPacket(type: .endDataPacket,
                        payload: PTPIPCodec.dataPacketPayload(transactionID: txn, chunk: outData)).encoded(), on: command)
                }

                var inboundPayload = Data()
                if outData == nil && hasDataPhase {
                    inboundPayload = try await self.readDataPhase(on: command, context: context, verbose: verbose)
                }

                let responsePacket = try await self.readPacket(on: command, context: context)
                guard responsePacket.type == .operationResponse else {
                    throw PTPIPError.unexpectedPacketType(responsePacket.type.rawValue)
                }
                guard let parsed = PTPIPCodec.parseOperationResponse(responsePacket.payload) else {
                    throw PTPIPError.malformedPacket("Operation Response too short")
                }
                let response = PTPContainer(kind: .response, code: parsed.code,
                                            transactionID: parsed.transactionID, parameters: parsed.parameters)
                if verbose {
                    await self.log("[\(context)] response: \(response.code == PTPResponseCode.ok ? "OK" : String(format: "0x%04X", response.code))")
                }
                await self.exitExclusive()
                return PTPTransactionResult(payload: inboundPayload, response: response, rawInbound: inboundPayload)
            } catch {
                await self.exitExclusive()
                throw error
            }
        }
    }

    private func enterExclusive(_ context: String) async throws {
        if let busyContext {
            log("!!! REENTRANCY DETECTED: '\(context)' started while '\(busyContext)' was still in flight")
            // Was `preconditionFailure` — a hard, unrecoverable crash mid-shot
            // at a live paid event if this guard ever fires for real. It
            // exists to catch a class of bug three earlier designs all hit
            // (see comment above), not to protect against something expected
            // to recur once shipped, so a thrown, catchable error is the
            // right severity now: the caller drops this transaction and the
            // booth keeps running instead of the whole app going down.
            throw PTPIPError.reentrancy("PTPIPTransport network section entered concurrently: '\(context)' vs '\(busyContext)'")
        }
        busyContext = context
    }

    private func exitExclusive() {
        busyContext = nil
    }

    /// Reads Start Data Packet -> zero or more Data/End Data Packets,
    /// concatenating the payload bytes.
    ///
    /// Terminates once the Start Data Packet's own *declared total length*
    /// has been collected, rather than trusting the End Data Packet marker
    /// alone. Hardware traffic showed a persistent, non-concurrency related
    /// desync (proven separately via a reentrancy assertion that never
    /// fired) where trusting packet *type* to signal completion went wrong
    /// somewhere — using the length this camera already tells us up front
    /// is a stronger, independently-checkable signal than guessing its
    /// exact type-sequence convention.
    private func readDataPhase(on connection: NWConnection, context: String, verbose: Bool) async throws -> Data {
        let start = try await readPacket(on: connection, context: context)
        guard start.type == .startDataPacket else {
            throw PTPIPError.unexpectedPacketType(start.type.rawValue)
        }
        guard start.payload.count >= 12 else {
            throw PTPIPError.malformedPacket("Start Data Packet payload too short for declared length")
        }
        let declaredLength = start.payload.readLE(UInt64.self, at: 4)
        // Cap at 256MB: a corrupted or spoofed declared length (this is
        // cleartext, unauthenticated PTP/IP on a shared LAN — any device on
        // the network can send bytes here) previously drove an unbounded
        // reserveCapacity() and an Int(UInt64) conversion that TRAPS the
        // process outright for declared lengths >= 2^63. The largest real
        // capture this app handles is an EOS R RAW+JPEG frame, nowhere
        // close to this ceiling.
        guard declaredLength < 256_000_000 else {
            throw PTPIPError.malformedPacket("Start Data Packet declared length \(declaredLength) exceeds sane bound")
        }
        let totalLength = Int(declaredLength)
        if verbose { log("[\(context)] data phase declared length: \(totalLength) bytes") }

        var collected = Data()
        collected.reserveCapacity(totalLength)
        while collected.count < totalLength {
            let packet = try await readPacket(on: connection, context: context)
            switch packet.type {
            case .dataPacket:
                collected.append(packet.payload.dropFirst(4)) // strip leading transaction ID
            case .endDataPacket:
                collected.append(packet.payload.dropFirst(4))
                if collected.count < totalLength {
                    // The camera has sent its terminal packet and won't send
                    // more until the NEXT command — looping back into
                    // readPacket here previously hung forever waiting for
                    // bytes that were never coming, deadlocking this actor
                    // (SerialGate serializes every future send() behind it)
                    // until Wi-Fi itself eventually died. Trust the End
                    // marker over the Start packet's declared length instead.
                    log("!! [\(context)] End Data Packet arrived with only \(collected.count)/\(totalLength) bytes collected — returning short")
                }
                return collected
            default:
                log("!! [\(context)] unexpected \(packet.type) mid-data-phase with \(collected.count)/\(totalLength) bytes collected — treating as end of phase")
                return collected
            }
        }
        return collected
    }

    // MARK: - Object download (capture retrieval over Wi-Fi)

    /// Polls Canon's own GetEvent for RequestObjectTransfer (0xC186) — the
    /// signal that actually fires for CaptureDestination=Host (SDRAM)
    /// captures. Standard PTP ObjectAdded (card-based) never arrives for a
    /// host-only capture, on either the command connection's GetEvent or the
    /// dedicated PTP/IP event connection — both were tried and neither ever
    /// saw anything during a real capture. ObjectAddedEx/64 checked too, in
    /// case a card happens to be inserted and mirrors the notification.
    public func nextCapturedFile(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var objectHandle: UInt32?
        while Date() < deadline {
            let result = try await send(code: CanonOp.getEvent, parameters: [], outData: nil)
            for record in CanonEventRecord.parse(result.payload) {
                if (record.type == CanonEvent.requestObjectTransfer
                    || record.type == CanonEvent.objectAddedEx
                    || record.type == CanonEvent.objectAddedEx64),
                   record.payload.count >= 4 {
                    objectHandle = record.payload.readLE(UInt32.self, at: 0)
                }
            }
            if objectHandle != nil { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let objectHandle else {
            throw TransportError.timeout("no RequestObjectTransfer/ObjectAdded event within \(timeout)s of capture")
        }
        log("captured object handle 0x\(String(objectHandle, radix: 16))")

        let infoResult = try await send(code: StandardPTPOp.getObjectInfo, parameters: [objectHandle], outData: nil)
        // ObjectInfo dataset per the PTP spec: StorageID(4) + ObjectFormat(2)
        // + ProtectionStatus(2) + ObjectCompressedSize(4) — the size field is
        // at offset 8, not 52 (52 lands inside the variable-length Filename
        // string that follows the fixed header). Log-only either way; the
        // real download below uses GetObject's actual byte count.
        if infoResult.payload.count >= 12 {
            let size = infoResult.payload.readLE(UInt32.self, at: 8)
            log("object info: \(size) bytes reported")
        }

        let objectResult = try await send(code: StandardPTPOp.getObject, parameters: [objectHandle], outData: nil)
        guard let response = objectResult.response, response.code == PTPResponseCode.ok else {
            throw TransportError.downloadFailed(underlying: nil)
        }
        return objectResult.payload
    }

    /// Vendor-neutral capture retrieval (Nikon/generic): waits for a
    /// standard ObjectAdded on the dedicated event connection — the channel
    /// the PTP/IP spec assigns it to — then downloads the object. Canon
    /// keeps its own nextCapturedFile above (host-destined EOS captures
    /// never emit standard ObjectAdded at all).
    public func nextCapturedFileViaObjectAdded(timeout: TimeInterval) async throws -> Data {
        // Supersede any stale waiter (a previous capture that errored out
        // above this layer), then arm a fresh one. The timeout task only
        // expires ITS OWN generation, so a slow-but-successful wait can't be
        // killed by an earlier capture's leftover timer.
        objectAddedWaiter?.resume(returning: nil)
        objectAddedWaiter = nil
        objectAddedWaiterGeneration += 1
        let generation = objectAddedWaiterGeneration

        let handle: UInt32?
        if let pending = pendingObjectAdded, Date().timeIntervalSince(pending.at) < 2 {
            // Event beat us to it (see publishObjectAdded) — consume it.
            handle = pending.handle
            pendingObjectAdded = nil
        } else {
            pendingObjectAdded = nil
            handle = await withCheckedContinuation { continuation in
                objectAddedWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.expireObjectAddedWaiter(generation: generation)
                }
            }
        }
        guard let handle else {
            throw TransportError.timeout("no ObjectAdded event within \(timeout)s of capture")
        }
        log("ObjectAdded handle 0x\(String(handle, radix: 16))")

        let objectResult = try await send(code: StandardPTPOp.getObject, parameters: [handle], outData: nil)
        guard let response = objectResult.response, response.code == PTPResponseCode.ok else {
            throw TransportError.downloadFailed(underlying: nil)
        }
        return objectResult.payload
    }

    private func expireObjectAddedWaiter(generation: Int) {
        guard generation == objectAddedWaiterGeneration, let waiter = objectAddedWaiter else { return }
        objectAddedWaiter = nil
        waiter.resume(returning: nil)
    }

    // MARK: - Networking primitives

    private func openConnection() async throws -> NWConnection {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        // 10s outer race: `.cancelled` (socket torn down before `.ready` —
        // overlapping connect attempts, app backgrounded mid-handshake) and
        // `.preparing`/`.setup` were previously unhandled `default: break`
        // cases that left the continuation unresumed forever, wedging
        // connect() with no recovery short of killing the app. `.waiting`
        // still isn't treated as terminal — a transient DNS/route hiccup
        // can resolve into `.ready` — but now has this timeout as a backstop
        // instead of the aspirational "outer wrapper" that never existed.
        do {
            return try await withTimeout(seconds: 10) {
                // withTaskCancellationHandler is load-bearing, not decorative:
                // withTimeout cancels this operation when the deadline fires,
                // but a bare continuation waiting on stateUpdateHandler never
                // observes cancellation, so the whole timeout would hang
                // waiting for a task that never finishes. Cancelling the
                // connection forces stateUpdateHandler to emit `.cancelled`,
                // which resumes the continuation and lets the timeout return.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        var resumed = false
                        connection.stateUpdateHandler = { state in
                            guard !resumed else { return }
                            switch state {
                            case .ready:
                                resumed = true
                                continuation.resume(returning: connection)
                            case .failed(let error):
                                resumed = true
                                continuation.resume(throwing: PTPIPError.connectionFailed("\(error)"))
                            case .cancelled:
                                resumed = true
                                continuation.resume(throwing: PTPIPError.connectionFailed("connection cancelled before ready"))
                            case .waiting(let error):
                                Task { await self.log("connection waiting: \(error)") }
                            default:
                                break
                            }
                        }
                        connection.start(queue: .global(qos: .userInitiated))
                    }
                } onCancel: {
                    connection.cancel()
                }
            }
        } catch {
            // Belt-and-suspenders: on any throw (incl. the timeout path above)
            // make sure the socket is torn down rather than left live.
            connection.cancel()
            throw error
        }
    }

    private func write(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PTPIPError.connectionFailed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads exactly one PTP/IP packet: 8-byte header (length, type) then
    /// (length - 8) bytes of payload. TCP gives no message boundaries, so
    /// this reads in two fixed-size passes rather than trusting one call to
    /// return a whole packet.
    private func readPacket(on connection: NWConnection, context: String = "") async throws -> PTPIPPacket {
        let header = try await readExactly(8, on: connection)
        let length = Int(header.readLE(UInt32.self, at: 0))
        let rawType = header.readLE(UInt32.self, at: 4)
        guard let type = PTPIPPacketType(rawValue: rawType) else {
            let prefix = header.map { String(format: "%02X", $0) }.joined(separator: " ")
            log("!! [\(context)] unknown packet type \(rawType) (0x\(String(rawType, radix: 16))), length field \(length), header bytes [\(prefix)]")
            throw PTPIPError.malformedPacket("unknown packet type in header")
        }
        guard length >= 8 else { throw PTPIPError.malformedPacket("packet length \(length) < header size") }
        // Same sane bound as the data-phase declared length: a corrupted or
        // spoofed header field (cleartext, unauthenticated LAN protocol)
        // could otherwise force a multi-GB single-packet allocation attempt.
        guard length < 256_000_000 else {
            throw PTPIPError.malformedPacket("packet length \(length) exceeds sane bound")
        }
        let payload = length > 8 ? try await readExactly(length - 8, on: connection) : Data()
        return PTPIPPacket(type: type, payload: payload)
    }

    private func readExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        var collected = Data(capacity: count)
        while collected.count < count {
            let remaining = count - collected.count
            // Cancellation-aware: a silently dead Wi-Fi link never fires the
            // receive callback, so without this a capture that loses signal
            // mid-read would hang forever and the outer withTimeout could
            // never fire (it awaits this task). Cancelling the connection
            // forces the callback to complete with an error, unblocking it —
            // this is what makes the "Wi-Fi drop mid-capture" recovery real.
            let chunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: PTPIPError.connectionFailed("\(error)"))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(throwing: PTPIPError.connectionFailed("connection closed mid-read"))
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
            collected.append(chunk)
        }
        return collected
    }
}

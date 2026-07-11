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
    private let objectAddedStream: AsyncStream<UInt32>
    private let objectAddedContinuation: AsyncStream<UInt32>.Continuation
    private var eventReaderTask: Task<Void, Never>?

    public init(host: String, port: UInt16 = PTPIPDefaults.port, friendlyName: String = "Photobooth") {
        self.host = host
        self.port = port
        self.friendlyName = friendlyName
        (self.events, self.eventContinuation) = AsyncStream<TransportEvent>.makeStream()
        (self.objectAddedStream, self.objectAddedContinuation) = AsyncStream<UInt32>.makeStream()
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
        objectAddedContinuation.yield(handle)
    }

    public func disconnect() {
        eventReaderTask?.cancel()
        commandConnection?.cancel()
        eventConnection?.cancel()
        commandConnection = nil
        eventConnection = nil
        emit(.deviceRemoved)
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
                let reqPayload = PTPIPCodec.operationRequestPayload(
                    dataPhase: hasDataPhase ? 1 : 0, opcode: code, transactionID: txn, parameters: parameters)
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
            preconditionFailure("PTPIPTransport network section entered concurrently: '\(context)' vs '\(busyContext)'")
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
        let totalLength = Int(start.payload.readLE(UInt64.self, at: 4))
        if verbose { log("[\(context)] data phase declared length: \(totalLength) bytes") }

        var collected = Data()
        collected.reserveCapacity(totalLength)
        while collected.count < totalLength {
            let packet = try await readPacket(on: connection, context: context)
            switch packet.type {
            case .dataPacket, .endDataPacket:
                collected.append(packet.payload.dropFirst(4)) // strip leading transaction ID
                if packet.type == .endDataPacket && collected.count < totalLength {
                    log("!! [\(context)] End Data Packet arrived with only \(collected.count)/\(totalLength) bytes collected")
                }
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
        // ObjectInfo dataset: compressedSize is a u32 at a fixed offset (52)
        // per the PTP spec's ObjectInfo structure — used only for logging
        // here; GetObject below returns the real byte count regardless.
        if infoResult.payload.count >= 56 {
            let size = infoResult.payload.readLE(UInt32.self, at: 52)
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
        let handle: UInt32? = await withTaskGroup(of: UInt32?.self) { group in
            group.addTask { [objectAddedStream] in
                for await handle in objectAddedStream {
                    return handle
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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

    // MARK: - Networking primitives

    private func openConnection() async throws -> NWConnection {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
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
                case .waiting(let error):
                    // Keep waiting past transient errors, but surface a hard
                    // timeout via the outer withThrowingTaskGroup wrapper if
                    // this never resolves — logged for visibility either way.
                    Task { await self.log("connection waiting: \(error)") }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
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
        let payload = length > 8 ? try await readExactly(length - 8, on: connection) : Data()
        return PTPIPPacket(type: type, payload: payload)
    }

    private func readExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        var collected = Data(capacity: count)
        while collected.count < count {
            let remaining = count - collected.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
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
            collected.append(chunk)
        }
        return collected
    }
}

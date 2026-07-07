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
        CanonOp.getPartialObject, StandardPTPOp.getObjectInfo, StandardPTPOp.getObject
    ]

    private let host: String
    private let port: UInt16
    private let friendlyName: String

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

        let guid = (0..<16).map { _ in UInt8.random(in: 0...255) } // any 16 bytes; camera doesn't validate ours
        let initReq = PTPIPPacket(type: .initCommandRequest,
                                  payload: PTPIPCodec.initCommandRequestPayload(guid: guid, friendlyName: friendlyName))
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
        emit(.deviceFound(name: ack.cameraName.isEmpty ? "Canon (PTP/IP)" : ack.cameraName))
        emit(.sessionOpened)
        emit(.ready) // no ImageCaptureCore catalog-index gate over Wi-Fi
    }

    public func disconnect() {
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

    public func send(code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPTransactionResult {
        try await sendGate.run {
            let command = try await self.requireCommandConnection()
            let txn = await self.nextTransactionID()
            let hasDataPhase = Self.dataPhaseOpcodes.contains(code)

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
                inboundPayload = try await self.readDataPhase(on: command)
            }

            let responsePacket = try await self.readPacket(on: command)
            guard responsePacket.type == .operationResponse else {
                throw PTPIPError.unexpectedPacketType(responsePacket.type.rawValue)
            }
            guard let parsed = PTPIPCodec.parseOperationResponse(responsePacket.payload) else {
                throw PTPIPError.malformedPacket("Operation Response too short")
            }
            let response = PTPContainer(kind: .response, code: parsed.code,
                                        transactionID: parsed.transactionID, parameters: parsed.parameters)
            return PTPTransactionResult(payload: inboundPayload, response: response, rawInbound: inboundPayload)
        }
    }

    /// Reads Start Data Packet -> zero or more Data Packets -> End Data Packet,
    /// concatenating the payload bytes.
    private func readDataPhase(on connection: NWConnection) async throws -> Data {
        let start = try await readPacket(on: connection)
        guard start.type == .startDataPacket else {
            throw PTPIPError.unexpectedPacketType(start.type.rawValue)
        }
        var collected = Data()
        while true {
            let packet = try await readPacket(on: connection)
            switch packet.type {
            case .dataPacket:
                collected.append(packet.payload.dropFirst(4)) // strip leading transaction ID
            case .endDataPacket:
                collected.append(packet.payload.dropFirst(4))
                return collected
            default:
                throw PTPIPError.unexpectedPacketType(packet.type.rawValue)
            }
        }
    }

    // MARK: - Object download (capture retrieval over Wi-Fi)

    /// Waits for an ObjectAdded event on the (paused, per EOSCamera's
    /// contract during capture) event channel by polling GetEvent directly,
    /// then downloads the object via standard GetObjectInfo/GetObject.
    /// Best-effort — the exact ObjectAddedEx payload layout (handle as the
    /// first u32) is a reasonable, common assumption, not one confirmed on
    /// this specific body yet.
    public func nextCapturedFile(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var handle: UInt32?
        while Date() < deadline {
            let result = try await send(code: CanonOp.getEvent, parameters: [], outData: nil)
            for record in CanonEventRecord.parse(result.payload) {
                if record.type == CanonEvent.objectAddedEx || record.type == CanonEvent.objectAddedEx64,
                   record.payload.count >= 4 {
                    handle = record.payload.readLE(UInt32.self, at: 0)
                }
            }
            if handle != nil { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let objectHandle = handle else {
            throw TransportError.timeout("no ObjectAdded event within \(timeout)s of capture")
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
    private func readPacket(on connection: NWConnection) async throws -> PTPIPPacket {
        let header = try await readExactly(8, on: connection)
        let length = Int(header.readLE(UInt32.self, at: 0))
        guard let type = PTPIPPacketType(rawValue: header.readLE(UInt32.self, at: 4)) else {
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

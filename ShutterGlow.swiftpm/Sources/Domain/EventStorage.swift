import Foundation

/// Local-only storage layout: everything lives under the app's Documents
/// folder, nothing leaves the device except through an explicit share/print/
/// export action. Layout: Events/<eventId>/{config.json, assets/, photos/}.
public final class EventStorage {
    public static let shared = EventStorage()

    private let fileManager = FileManager.default
    private let currentEventKey = "com.anthonyvo.photobooth.currentEventId"

    private var eventsRoot: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Events", isDirectory: true)
    }

    private init() {}

    public func eventDirectory(_ eventId: String) -> URL {
        eventsRoot.appendingPathComponent(Self.sanitizeEventId(eventId), isDirectory: true)
    }

    /// eventId is free-text the attendant types into AdminView (only a "no
    /// spaces" hint, nothing enforced) and every path in this file is built
    /// by appending it as a single filesystem path component. Unsanitized,
    /// a value like "../../SomeOtherEvent" would let create/save/delete
    /// write or delete files outside the intended Events/<eventId>/ tree —
    /// still inside the app sandbox, but silently corrupting or destroying
    /// another event's data. Applied here (not just at entry in AdminView)
    /// so every path in this file is safe regardless of caller. Idempotent:
    /// sanitizing an already-clean id is a no-op, so re-deriving paths from
    /// a value that passed through this once (e.g. listEventIds() results)
    /// still resolves to the same directory.
    public static func sanitizeEventId(_ eventId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(eventId.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "event" : cleaned
    }

    public func assetsDirectory(_ eventId: String) -> URL {
        eventDirectory(eventId).appendingPathComponent("assets", isDirectory: true)
    }

    public func photosDirectory(_ eventId: String) -> URL {
        eventDirectory(eventId).appendingPathComponent("photos", isDirectory: true)
    }

    private func configURL(_ eventId: String) -> URL {
        eventDirectory(eventId).appendingPathComponent("config.json")
    }

    // MARK: - Create / load / save

    @discardableResult
    public func createEvent(_ config: EventConfig) throws -> EventConfig {
        try fileManager.createDirectory(at: eventDirectory(config.eventId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsDirectory(config.eventId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosDirectory(config.eventId), withIntermediateDirectories: true)
        try save(config)
        setCurrentEventId(config.eventId)
        return config
    }

    /// Creates the event's directories if needed and writes config — unlike
    /// createEvent(), never touches the current-event pointer. Used by
    /// RemoteSync to mirror synced events into local storage without
    /// hijacking whichever event the attendant currently has selected.
    public func upsertEvent(_ config: EventConfig) throws {
        try fileManager.createDirectory(at: eventDirectory(config.eventId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsDirectory(config.eventId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosDirectory(config.eventId), withIntermediateDirectories: true)
        try save(config)
    }

    public func save(_ config: EventConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: configURL(config.eventId), options: .atomic)
    }

    public func load(_ eventId: String) throws -> EventConfig {
        let data = try Data(contentsOf: configURL(eventId))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EventConfig.self, from: data)
    }

    /// Deletes an event's whole folder (config, assets, photos) and its
    /// counters. Clears the current-event pointer if it pointed at this
    /// event — callers should route back to the event picker afterward
    /// since there's no longer a valid "current" event.
    public func deleteEvent(_ eventId: String) throws {
        try fileManager.removeItem(at: eventDirectory(eventId))
        UserDefaults.standard.removeObject(forKey: printCountKey(eventId))
        UserDefaults.standard.removeObject(forKey: guestSessionCountKey(eventId))
        if currentEventId() == eventId {
            UserDefaults.standard.removeObject(forKey: currentEventKey)
        }
    }

    public func listEventIds() -> [String] {
        (try? fileManager.contentsOfDirectory(at: eventsRoot, includingPropertiesForKeys: nil))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }
            .sorted() ?? []
    }

    // MARK: - Current event pointer

    public func currentEventId() -> String? {
        UserDefaults.standard.string(forKey: currentEventKey)
    }

    public func setCurrentEventId(_ eventId: String) {
        UserDefaults.standard.set(eventId, forKey: currentEventKey)
    }

    /// The event to actually run with: current pointer if it still exists on
    /// disk, otherwise falls back to a fresh standard-branded default so the
    /// booth never launches into a broken state.
    public func loadCurrentOrDefault() -> EventConfig {
        if let id = currentEventId(), let config = try? load(id) {
            return config
        }
        let fallback = EventConfig.standardDefault()
        try? createEvent(fallback)
        return fallback
    }

    // MARK: - Assets

    @discardableResult
    public func importAsset(from sourceURL: URL, eventId: String, filename: String) throws -> String {
        let dest = assetsDirectory(eventId).appendingPathComponent(filename)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)
        return filename
    }

    /// For picker-sourced image data (PhotosPicker etc.) that arrives as raw
    /// bytes rather than a file URL.
    @discardableResult
    public func importLogoData(_ data: Data, eventId: String, filename: String = "logo.png") throws -> String {
        try fileManager.createDirectory(at: assetsDirectory(eventId), withIntermediateDirectories: true)
        let dest = assetsDirectory(eventId).appendingPathComponent(filename)
        try data.write(to: dest, options: .atomic)
        return filename
    }

    public func assetURL(eventId: String, filename: String) -> URL {
        assetsDirectory(eventId).appendingPathComponent(filename)
    }

    // MARK: - Photos

    /// Saves a captured photo under the event's photos/ folder, named by
    /// timestamp so ordering is free and collisions are practically impossible.
    @discardableResult
    public func savePhoto(_ data: Data, eventId: String, fileExtension: String = "jpg") throws -> URL {
        let name = "IMG_\(Int(Date().timeIntervalSince1970 * 1000)).\(fileExtension)"
        let dest = photosDirectory(eventId).appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    public func listPhotos(eventId: String) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: photosDirectory(eventId), includingPropertiesForKeys: [.creationDateKey]))?
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) } ?? []
    }

    // MARK: - Per-event counters

    /// Running totals for the attendant status panel — keyed per event so
    /// switching events (via the home screen) doesn't mix up one client's
    /// numbers with another's.
    public func recordPrint(eventId: String) {
        let key = printCountKey(eventId)
        UserDefaults.standard.set(printCount(eventId: eventId) + 1, forKey: key)
    }

    public func printCount(eventId: String) -> Int {
        UserDefaults.standard.integer(forKey: printCountKey(eventId))
    }

    public func recordGuestSession(eventId: String) {
        let key = guestSessionCountKey(eventId)
        UserDefaults.standard.set(guestSessionCount(eventId: eventId) + 1, forKey: key)
    }

    public func guestSessionCount(eventId: String) -> Int {
        UserDefaults.standard.integer(forKey: guestSessionCountKey(eventId))
    }

    // MARK: - Lead capture

    /// One opt-in contact collected via the data-capture form. Stored LOCALLY
    /// in the event folder (Events/<id>/leads.json) and exported by the
    /// attendant — never auto-uploaded, matching the local-first posture.
    public struct GuestLead: Codable, Sendable, Equatable {
        public var name: String
        public var email: String
        public var phone: String
        public var consented: Bool
        public var capturedAt: Date

        public init(name: String = "", email: String = "", phone: String = "", consented: Bool = false, capturedAt: Date = Date()) {
            self.name = name
            self.email = email
            self.phone = phone
            self.consented = consented
            self.capturedAt = capturedAt
        }
    }

    private func leadsURL(_ eventId: String) -> URL {
        eventDirectory(eventId).appendingPathComponent("leads.json")
    }

    public func appendLead(_ lead: GuestLead, eventId: String) {
        var leads = loadLeads(eventId: eventId)
        leads.append(lead)
        guard let data = try? JSONEncoder().encode(leads) else { return }
        // .completeFileProtection, not the default. This file is the one
        // place on the booth holding guest names, emails and phone numbers.
        // iOS's default class keeps data readable from first unlock until
        // shutdown, and a booth iPad is unlocked for the entire event, so a
        // device stolen mid-shift would give up the whole lead list. With
        // this, the file is unreadable whenever the screen is locked.
        try? data.write(to: leadsURL(eventId), options: [.atomic, .completeFileProtection])
    }

    public func loadLeads(eventId: String) -> [GuestLead] {
        guard let data = try? Data(contentsOf: leadsURL(eventId)) else { return [] }
        return (try? JSONDecoder().decode([GuestLead].self, from: data)) ?? []
    }

    /// Spreadsheet-ready export of the collected leads for this event.
    public func leadsCSV(eventId: String) -> String {
        func esc(_ s: String) -> String {
            // Guest-typed text lands in the operator's spreadsheet app —
            // a value starting with = + - @ (or a stray tab/CR) is treated
            // as a live formula by Excel/Sheets (CSV injection). Prefix a
            // single quote so it renders as text instead of executing.
            var v = s
            if let first = v.first, "=+-@\t\r".contains(first) {
                v = "'" + v
            }
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let iso = ISO8601DateFormatter()
        var rows = ["Name,Email,Phone,Consented,CapturedAt"]
        for lead in loadLeads(eventId: eventId) {
            rows.append([
                esc(lead.name), esc(lead.email), esc(lead.phone),
                lead.consented ? "yes" : "no", iso.string(from: lead.capturedAt)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    public func leadCount(eventId: String) -> Int {
        loadLeads(eventId: eventId).count
    }

    /// When the oldest lead on this event was captured, or nil if there are
    /// none. Surfaced in Admin so an attendant can see what has been sitting
    /// on the device rather than having to remember.
    public func oldestLeadDate(eventId: String) -> Date? {
        loadLeads(eventId: eventId).map(\.capturedAt).min()
    }

    /// Deletes this event's collected contacts and nothing else.
    ///
    /// Separate from `deleteEvent` on purpose. Until now the only way to
    /// remove guest contact details was to delete the whole event, which
    /// also destroyed the photos — so in practice nobody did it, and a booth
    /// iPad accumulated every guest's name, email and phone from every event
    /// it had ever run, indefinitely. Photos are the operator's work product;
    /// leads are other people's personal data, and the two deserve different
    /// lifetimes.
    ///
    /// Returns how many were removed so the caller can confirm the number
    /// rather than claiming a vague success.
    @discardableResult
    public func deleteLeads(eventId: String) -> Int {
        let count = leadCount(eventId: eventId)
        guard count > 0 else { return 0 }
        try? FileManager.default.removeItem(at: leadsURL(eventId))
        return count
    }

    /// Every event id on this device that still holds contacts, with counts.
    public func eventsHoldingLeads() -> [(eventId: String, count: Int)] {
        listEventIds()
            .map { ($0, leadCount(eventId: $0)) }
            .filter { $0.1 > 0 }
    }

    /// Clears contacts across every event on the device, leaving all photos
    /// and configuration intact. This is the handover case: an iPad being
    /// sold, returned to a rental pool, or passed to a different operator
    /// should not carry the previous one's guest lists with it.
    @discardableResult
    public func purgeAllLeads() -> Int {
        eventsHoldingLeads().reduce(0) { $0 + deleteLeads(eventId: $1.eventId) }
    }

    private func printCountKey(_ eventId: String) -> String {
        "com.anthonyvo.photobooth.printCount.\(eventId)"
    }

    private func guestSessionCountKey(_ eventId: String) -> String {
        "com.anthonyvo.photobooth.guestSessionCount.\(eventId)"
    }

    /// Free space on the device, for the attendant status panel — same
    /// volume the Documents folder (and so every event's photos) lives on.
    public func remainingCapacityGB() -> Double? {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Double(bytes) / 1_000_000_000
    }
}

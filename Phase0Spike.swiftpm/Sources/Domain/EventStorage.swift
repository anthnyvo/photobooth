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
        eventsRoot.appendingPathComponent(eventId, isDirectory: true)
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
    public func savePhoto(_ data: Data, eventId: String) throws -> URL {
        let name = "IMG_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
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

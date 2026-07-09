import Foundation

/// Pulls events + booth configs from the shared Supabase backend and mirrors
/// them into local EventStorage. Matches the local-first contract from the
/// web dashboard's README: sync once (at login, or an explicit "Sync now"),
/// then the booth runs entirely off the cached config.json — a venue with
/// zero signal never stops an event that's already been paired.
///
/// Deliberately maps only the fields the web dashboard's booth_configs
/// schema actually has (print layout, countdown, filters/animations,
/// square crop, overlay image). Branding colors, logo, share/print
/// channels, and print limits aren't in that schema yet, so a synced event
/// keeps whatever it already had locally for those — the on-device Admin
/// screen remains the way to set them until the dashboard grows matching
/// fields.
public enum RemoteSync {
    private static let projectURL = SupabaseAuth.projectURL
    private static let anonKey = SupabaseAuth.anonKey

    public enum SyncError: Error {
        case notSignedIn
        case network
    }

    @discardableResult
    public static func syncEvents() async throws -> Int {
        guard let session = await SupabaseAuth.shared.validSession() else {
            throw SyncError.notSignedIn
        }

        let events = try await fetch([RemoteEvent].self, path: "rest/v1/events?select=id,client_name", session: session)
        let configs = try await fetch([RemoteBoothConfig].self, path: "rest/v1/booth_configs?select=*", session: session)
        let configsByEvent = Dictionary(configs.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })

        for event in events {
            await merge(event, config: configsByEvent[event.id])
        }
        prune(keeping: Set(events.map(\.id)))
        return events.count
    }

    /// Deletes any locally-cached event that was itself pulled from the
    /// backend but is no longer in the operator's current event list —
    /// e.g. deleted on the dashboard. Purely local, admin-created events
    /// are never touched by sync.
    ///
    /// Sync-owned is `isRemote || UUID(uuidString: eventId) != nil`, not
    /// just the flag: a config cached by a build from before `isRemote`
    /// existed decodes that key as false (the lenient-decode default),
    /// which would make an already-deleted-on-the-dashboard event
    /// unprunable forever. Supabase event ids are always UUIDs and an
    /// attendant-typed local slug essentially never parses as one, so this
    /// fallback catches those pre-existing caches too.
    private static func prune(keeping remoteIds: Set<String>) {
        for eventId in EventStorage.shared.listEventIds() where !remoteIds.contains(eventId) {
            guard let local = try? EventStorage.shared.load(eventId),
                  local.isRemote || UUID(uuidString: eventId) != nil else { continue }
            try? EventStorage.shared.deleteEvent(eventId)
        }
    }

    private static func fetch<T: Decodable>(_ type: T.Type, path: String, session: AuthSession) async throws -> T {
        var request = URLRequest(url: URL(string: path, relativeTo: projectURL)!)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.network
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func merge(_ event: RemoteEvent, config: RemoteBoothConfig?) async {
        var local = (try? EventStorage.shared.load(event.id)) ?? EventConfig(
            eventId: event.id,
            displayName: event.clientName
        )
        local.displayName = event.clientName
        local.isRemote = true

        if let config {
            local.countdownSeconds = config.liveViewSettings.countdownSeconds
            local.filtersEnabled = config.liveViewSettings.filtersEnabled
            local.animationsEnabled = config.liveViewSettings.animationsEnabled
            local.squareCrop = config.liveViewSettings.squareCrop

            switch config.printLayout {
            case "strip_3":
                local.strip = EventConfig.StripOptions(enabled: true, shotCounts: [3], layouts: [.vertical])
            case "strip_4":
                local.strip = EventConfig.StripOptions(enabled: true, shotCounts: [4], layouts: [.vertical])
            case "grid_4":
                local.strip = EventConfig.StripOptions(enabled: true, shotCounts: [4], layouts: [.grid])
            default:
                local.strip = EventConfig.StripOptions(enabled: false)
            }

            if let overlayURLString = config.overlayTemplateURL,
               let overlayURL = URL(string: overlayURLString) {
                let downloaded = try? await URLSession.shared.data(from: overlayURL)
                if let imageData = downloaded?.0,
                   (try? EventStorage.shared.importLogoData(imageData, eventId: event.id, filename: "overlay.png")) != nil {
                    local.overlay = EventConfig.OverlayOptions(enabled: true, assetName: "overlay.png")
                }
            }
        }

        try? EventStorage.shared.upsertEvent(local)
    }

    private struct RemoteEvent: Decodable {
        let id: String
        let clientName: String

        enum CodingKeys: String, CodingKey {
            case id
            case clientName = "client_name"
        }
    }

    private struct RemoteBoothConfig: Decodable {
        let eventId: String
        let overlayTemplateURL: String?
        let printLayout: String
        let liveViewSettings: LiveViewSettings

        enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case overlayTemplateURL = "overlay_template_url"
            case printLayout = "print_layout"
            case liveViewSettings = "live_view_settings"
        }

        struct LiveViewSettings: Decodable {
            let countdownSeconds: Int
            let filtersEnabled: Bool
            let animationsEnabled: Bool
            let squareCrop: Bool

            enum CodingKeys: String, CodingKey {
                case countdownSeconds = "countdown_seconds"
                case filtersEnabled = "filters_enabled"
                case animationsEnabled = "animations_enabled"
                case squareCrop = "square_crop"
            }
        }
    }
}

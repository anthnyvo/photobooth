import Foundation

/// Pulls events + booth configs from the shared Supabase backend and mirrors
/// them into local EventStorage. Matches the local-first contract from the
/// web dashboard's README: sync once (at login, or an explicit "Sync now"),
/// then the booth runs entirely off the cached config.json — a venue with
/// zero signal never stops an event that's already been paired.
///
/// Deliberately maps only the fields the web dashboard's booth_configs
/// schema actually has (print layout/limits, countdown, filters/
/// animations, square crop, overlay/logo/backdrop/sticker images, brand
/// colors, AirDrop/QR/email share channels). Logo/backdrop/stickers use
/// the same "dashboard stores a hosted URL, iPad downloads it on sync"
/// mechanism as overlay — there's no Supabase Storage upload widget, so
/// the dashboard operator hosts the image elsewhere and pastes the URL.
public enum RemoteSync {
    private static let projectURL = SupabaseAuth.projectURL
    private static let anonKey = SupabaseAuth.anonKey

    public enum SyncError: Error {
        case notSignedIn
        case network
    }

    /// Deletes an event on the backend, for a remote (dashboard-synced)
    /// event's "Delete Event" button in AdminView. A purely local delete
    /// wasn't enough for these: the very next sync (which runs whenever the
    /// booth returns to the event picker) re-pulls the org's full event
    /// list from Supabase — since the server never learned about the
    /// delete, it just re-downloads the "missing" event and recreates it
    /// locally with a fresh createdAt, which is why it silently reappeared
    /// at the top of the list instead of staying deleted. Throws
    /// SyncError.network on a non-2xx response, including RLS rejecting an
    /// operator session (events_write requires owner/admin) — the caller
    /// should surface that rather than deleting locally and letting the
    /// event quietly come back a moment later.
    public static func deleteRemoteEvent(_ id: String) async throws {
        guard let session = await SupabaseAuth.shared.validSession() else {
            throw SyncError.notSignedIn
        }
        var request = URLRequest(url: URL(string: "rest/v1/events?id=eq.\(id)", relativeTo: projectURL)!)
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        // PostgREST returns 200/204 for a DELETE that matched zero rows —
        // RLS filters rows rather than rejecting the request, so an
        // operator session (events_write requires owner/admin) with no
        // permission to delete this event gets an HTTP-success response
        // with nothing actually deleted server-side. Status code alone
        // can't tell the difference; asking for the deleted rows back and
        // checking the body isn't empty is the only way to know the
        // delete actually happened.
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError.network
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncError.network
        }
        let deletedRows = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        guard let deletedRows, !deletedRows.isEmpty else {
            throw SyncError.network
        }
    }

    @discardableResult
    public static func syncEvents() async throws -> Int {
        guard let session = await SupabaseAuth.shared.validSession() else {
            throw SyncError.notSignedIn
        }

        let events = try await fetch([RemoteEvent].self, path: "rest/v1/events?select=id,client_name", session: session)
        // Lenient per-row: a single malformed config must not abort sync for
        // the whole org — that event just falls back to its local/default
        // config while every other event still syncs.
        let configs = try await fetchLenientArray(RemoteBoothConfig.self, path: "rest/v1/booth_configs?select=*", session: session)
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
    ///
    /// NEVER prunes an event that still has captured photos on disk. This
    /// app is local-first: photos live only on the iPad until explicitly
    /// exported. Auto-deleting them because the dashboard row disappeared —
    /// or, worse, because a DIFFERENT operator signed into the same iPad and
    /// their event list doesn't include this one — would be silent,
    /// unrecoverable data loss. A photo-bearing event lingers locally until
    /// an attendant deletes it deliberately (which does warn).
    private static func prune(keeping remoteIds: Set<String>) {
        for eventId in EventStorage.shared.listEventIds() where !remoteIds.contains(eventId) {
            guard let local = try? EventStorage.shared.load(eventId),
                  local.isRemote || UUID(uuidString: eventId) != nil else { continue }
            guard EventStorage.shared.listPhotos(eventId: eventId).isEmpty else { continue }
            try? EventStorage.shared.deleteEvent(eventId)
        }
    }

    /// Logs a guest session on the backend for the dashboard's Insights page
    /// — see supabase/migrations/0010_guest_sessions.sql (shutterglow-web
    /// repo). Best-effort only: must never block or fail the guest capture
    /// flow, since the whole point of the local-first design is that a
    /// venue with zero signal keeps running — callers fire this from a
    /// detached Task and ignore the result. No-ops for a purely local event
    /// (attendant-typed slug, not a UUID) since it was never synced from the
    /// dashboard and doesn't exist server-side to reference.
    public static func recordRemoteGuestSession(eventId: String) async {
        guard let session = await SupabaseAuth.shared.validSession(),
              UUID(uuidString: eventId) != nil else { return }
        var request = URLRequest(url: URL(string: "rest/v1/guest_sessions", relativeTo: projectURL)!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["event_id": eventId])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func fetchData(path: String, session: AuthSession) async throws -> Data {
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
        return data
    }

    private static func fetch<T: Decodable>(_ type: T.Type, path: String, session: AuthSession) async throws -> T {
        let data = try await fetchData(path: path, session: session)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes a JSON array element-by-element, dropping any row that fails to
    /// decode instead of aborting the whole batch. One booth_configs row with
    /// malformed/missing jsonb (hand-edited, or written by a mismatched
    /// dashboard build) must not brick sync for every OTHER event in the org.
    private static func fetchLenientArray<T: Decodable>(_ type: T.Type, path: String, session: AuthSession) async throws -> [T] {
        let data = try await fetchData(path: path, session: session)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let rowData = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(T.self, from: rowData)
        }
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
            local.ai = EventConfig.AIOptions(
                props: config.liveViewSettings.aiProps ?? false,
                smileShutter: config.liveViewSettings.smileShutter ?? false
            )
            local.timelapseEnabled = config.liveViewSettings.timelapseEnabled ?? false
            // Glam + data-capture: pure settings, safe to sync. Preserve the
            // existing local value when the key is absent (older dashboard
            // rows) rather than resetting.
            local.glam = EventConfig.GlamOptions(
                enabled: config.liveViewSettings.glamEnabled ?? local.glam.enabled
            )
            local.dataCapture = EventConfig.DataCaptureOptions(
                enabled: config.liveViewSettings.dataCaptureEnabled ?? local.dataCapture.enabled,
                collectName: config.liveViewSettings.dataCaptureName ?? local.dataCapture.collectName,
                collectEmail: config.liveViewSettings.dataCaptureEmail ?? local.dataCapture.collectEmail,
                collectPhone: config.liveViewSettings.dataCapturePhone ?? local.dataCapture.collectPhone,
                consentText: config.liveViewSettings.dataCaptureConsentText ?? local.dataCapture.consentText
            )
            // Print/share were previously local-only (set from this app's
            // own Admin screen with no dashboard equivalent, despite the
            // web docs implying otherwise) — the dashboard config form now
            // has matching controls, so a synced row carries real values
            // instead of always falling back to true/true/false here.
            local.print = EventConfig.PrintOptions(
                enabled: config.liveViewSettings.printEnabled ?? true,
                limitPerGuest: config.liveViewSettings.printLimitPerGuest
            )
            local.share = EventConfig.ShareOptions(
                airdrop: config.liveViewSettings.shareAirdrop ?? true,
                qrGallery: config.liveViewSettings.shareQrGallery ?? true,
                // SMS isn't exposed on either the app's own Admin screen or
                // the dashboard yet — preserve whatever local already has
                // rather than silently resetting it.
                sms: local.share.sms,
                email: config.liveViewSettings.shareEmail ?? false
            )

            // Newer dashboard rows carry the full offered sets in the
            // jsonb; rows saved before that only have the single
            // print_layout column, mapped to a one-option set.
            if let stripEnabled = config.liveViewSettings.stripEnabled {
                let counts = (config.liveViewSettings.stripShotCounts ?? [3]).filter { (2...6).contains($0) }
                let layouts = (config.liveViewSettings.stripLayouts ?? ["vertical"])
                    .compactMap(EventConfig.StripOptions.Layout.init(rawValue:))
                local.strip = EventConfig.StripOptions(
                    enabled: stripEnabled,
                    shotCounts: counts.isEmpty ? [3] : counts.sorted(),
                    layouts: layouts.isEmpty ? [.vertical] : layouts
                )
            } else {
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
            }

            if let overlayURLString = config.overlayTemplateURL,
               let overlayURL = URL(string: overlayURLString) {
                let downloaded = try? await URLSession.shared.data(from: overlayURL)
                if let imageData = downloaded?.0,
                   (try? EventStorage.shared.importLogoData(imageData, eventId: event.id, filename: "overlay.png")) != nil {
                    local.overlay = EventConfig.OverlayOptions(enabled: true, assetName: "overlay.png")
                }
                // If the download failed (network blip, dead URL), fall through
                // and keep whatever overlay state already exists locally rather
                // than disabling a working overlay over a transient error.
            } else {
                // Dashboard's overlay_template_url is empty/cleared — the
                // owner removed it, so a synced event should stop showing the
                // overlay. Previously this branch didn't exist at all: the
                // whole block only ever ran when a URL was present, so
                // clearing the field on the dashboard and saving had zero
                // effect on any device that already had the overlay enabled
                // from an earlier sync — the one config field the dashboard
                // could set but never unset.
                local.overlay = EventConfig.OverlayOptions(enabled: false, assetName: nil)
            }

            // Colors are plain strings, no download needed. Preserve local
            // when a key is absent (older dashboard rows) same as glam/data
            // capture above.
            local.colors = EventConfig.Colors(
                primaryHex: config.liveViewSettings.colorPrimaryHex ?? local.colors.primaryHex,
                backgroundHex: config.liveViewSettings.colorBackgroundHex ?? local.colors.backgroundHex
            )

            // Logo / backdrop / stickers are "dashboard sets, never wipes."
            // Unlike overlay (which the dashboard owns outright and can clear
            // by blanking the field), all three of these are ALSO settable on
            // the device's own Admin screen — an operator very likely has them
            // configured locally with no dashboard equivalent ever entered. So
            // an absent/blank dashboard field must preserve the on-device asset,
            // never delete it. A present URL overrides; a blank one is a no-op.
            // (If a dashboard operator needs to remove one of these, they clear
            // it on the device — same as before these fields existed at all.)
            if let logoURLString = config.liveViewSettings.logoURL,
               let logoURL = URL(string: logoURLString) {
                let downloaded = try? await URLSession.shared.data(from: logoURL)
                if let imageData = downloaded?.0,
                   (try? EventStorage.shared.importLogoData(imageData, eventId: event.id, filename: "logo.png")) != nil {
                    local.logoAssetName = "logo.png"
                }
                // Download failure falls through and keeps the existing local
                // logo rather than blanking it over a transient error.
            }

            if let backdropURLString = config.liveViewSettings.backdropURL,
               let backdropURL = URL(string: backdropURLString) {
                let downloaded = try? await URLSession.shared.data(from: backdropURL)
                if let imageData = downloaded?.0,
                   (try? EventStorage.shared.importLogoData(imageData, eventId: event.id, filename: "backdrop.png")) != nil {
                    local.backgroundReplace = EventConfig.BackgroundReplaceOptions(enabled: true, backdropAssetName: "backdrop.png")
                }
            }

            if let stickerURLStrings = config.liveViewSettings.stickerURLs, !stickerURLStrings.isEmpty {
                var assetNames: [String] = []
                for (index, urlString) in stickerURLStrings.enumerated() {
                    guard let url = URL(string: urlString) else { continue }
                    let downloaded = try? await URLSession.shared.data(from: url)
                    guard let imageData = downloaded?.0 else { continue }
                    let filename = "sticker_\(index).png"
                    if (try? EventStorage.shared.importLogoData(imageData, eventId: event.id, filename: filename)) != nil {
                        assetNames.append(filename)
                    }
                }
                // Only overwrite if at least one sticker actually downloaded —
                // a total network blip must not wipe a working sticker set.
                if !assetNames.isEmpty {
                    local.stickers = EventConfig.StickerOptions(enabled: true, assetNames: assetNames)
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
            /// Optional — rows saved before the dashboard grew AI toggles
            /// simply lack these keys in the jsonb.
            let aiProps: Bool?
            let smileShutter: Bool?
            /// Offered strip sets (multi-select on the dashboard). Optional
            /// for the same pre-existing-rows reason; absent falls back to
            /// the legacy print_layout column.
            let stripEnabled: Bool?
            let stripShotCounts: [Int]?
            let stripLayouts: [String]?
            let timelapseEnabled: Bool?
            /// Optional for the same pre-existing-rows reason as the AI
            /// toggles above — rows saved before the dashboard grew
            /// print/share controls simply lack these keys.
            let printEnabled: Bool?
            /// nil (missing key or explicit JSON null) = unlimited, same
            /// meaning as EventConfig.PrintOptions.limitPerGuest.
            let printLimitPerGuest: Int?
            let shareAirdrop: Bool?
            let shareQrGallery: Bool?
            let shareEmail: Bool?
            let glamEnabled: Bool?
            let dataCaptureEnabled: Bool?
            let dataCaptureName: Bool?
            let dataCaptureEmail: Bool?
            let dataCapturePhone: Bool?
            let dataCaptureConsentText: String?
            /// Brand colors, plus hosted URLs for logo/backdrop/stickers —
            /// see importLogoData usage in merge() above for how these turn
            /// into local assets.
            let colorPrimaryHex: String?
            let colorBackgroundHex: String?
            let logoURL: String?
            let backdropURL: String?
            let stickerURLs: [String]?

            enum CodingKeys: String, CodingKey {
                case countdownSeconds = "countdown_seconds"
                case filtersEnabled = "filters_enabled"
                case animationsEnabled = "animations_enabled"
                case squareCrop = "square_crop"
                case aiProps = "ai_props"
                case smileShutter = "smile_shutter"
                case stripEnabled = "strip_enabled"
                case stripShotCounts = "strip_shot_counts"
                case stripLayouts = "strip_layouts"
                case timelapseEnabled = "timelapse_enabled"
                case printEnabled = "print_enabled"
                case printLimitPerGuest = "print_limit_per_guest"
                case shareAirdrop = "share_airdrop"
                case shareQrGallery = "share_qr_gallery"
                case shareEmail = "share_email"
                case glamEnabled = "glam_enabled"
                case dataCaptureEnabled = "data_capture_enabled"
                case dataCaptureName = "data_capture_name"
                case dataCaptureEmail = "data_capture_email"
                case dataCapturePhone = "data_capture_phone"
                case dataCaptureConsentText = "data_capture_consent_text"
                case colorPrimaryHex = "color_primary_hex"
                case colorBackgroundHex = "color_background_hex"
                case logoURL = "logo_url"
                case backdropURL = "backdrop_url"
                case stickerURLs = "sticker_urls"
            }
        }
    }
}

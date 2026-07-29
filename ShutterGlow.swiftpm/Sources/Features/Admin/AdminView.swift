import SwiftUI
import PhotosUI

/// Config-builder: the attendant fills this in once, ahead of the event,
/// per the pre-event branding conversation with the client. Submitting
/// writes config.json + copies the logo into that event's asset folder —
/// no hand-written JSON, no file edits on event day.
///
/// Styled as floating glass cards over the chassis gradient — same design
/// language as the guest screens — instead of a stock settings Form, so
/// the attendant side doesn't feel like a different (older) app.
struct AdminView: View {
    enum Mode: Equatable {
        /// Opened from the event picker's "+ New Event" — starts blank.
        case create
        /// Opened from ConnectView's "Event Setup" — edits the active event.
        case edit
    }

    @ObservedObject var model: BoothViewModel
    var mode: Mode = .edit
    @Environment(\.dismiss) private var dismiss

    @State private var eventId: String = ""
    @State private var displayName: String = ""
    @State private var branding: EventConfig.BrandingMode = .standard
    @State private var primaryColor: Color = .blue
    @State private var backgroundColor: Color = .black
    @State private var countdownSeconds: Int = 5
    @State private var airdrop = true
    @State private var qrGallery = true
    @State private var email = false
    @State private var printEnabled = true
    @State private var limitPrints = false
    @State private var printLimitCount = 1
    @State private var overlayEnabled = false
    @State private var stripEnabled = false
    /// Which shot counts are offered at the attract screen — e.g. {3, 4}
    /// shows both a 3-Shot and a 4-Shot button, not one fixed count.
    @State private var stripShotCounts: Set<Int> = [3]
    /// Which layouts are offered at the attract screen — e.g. all three
    /// shows vertical/horizontal/grid buttons, not one fixed layout.
    @State private var stripLayouts: Set<EventConfig.StripOptions.Layout> = [.vertical]
    @State private var squareCrop = false
    @State private var filtersEnabled = true
    @State private var animationsEnabled = true
    @State private var aiProps = false
    @State private var aiSmileShutter = false
    @State private var timelapseEnabled = false
    @State private var selectedLogo: PhotosPickerItem?
    @State private var logoData: Data?
    @State private var selectedOverlay: PhotosPickerItem?
    @State private var overlayData: Data?
    @State private var glamEnabled = false
    @State private var bgReplaceEnabled = false
    @State private var selectedBackdrop: PhotosPickerItem?
    @State private var backdropData: Data?
    @State private var stickersEnabled = false
    @State private var selectedStickers: [PhotosPickerItem] = []
    @State private var stickerDatas: [Data] = []
    /// Sticker asset filenames already saved for this event (edit mode); kept
    /// when the attendant doesn't re-pick a new set.
    @State private var existingStickerNames: [String] = []
    @State private var dataCaptureEnabled = false
    @State private var dcName = true
    @State private var dcEmail = true
    @State private var dcPhone = false
    @State private var dcConsent = ""
    @State private var saveMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var showingExport = false
    @State private var showingLeadExport = false
    @State private var leadExportURL: URL?
    @State private var showingClearLeadsConfirm = false
    @State private var showingPurgeLeadsConfirm = false
    /// Bumped after a lead deletion purely to force the status card to
    /// recompute. Its counts are read straight off disk during body
    /// evaluation, so without this the tile still shows the old number.
    @State private var leadsRevision = 0
    @State private var showingDiagExport = false
    @State private var diagExportURL: URL?
    @State private var currentPINEntry = ""
    @State private var newPINEntry = ""
    @State private var pinMessage: String?

    var body: some View {
        ZStack {
            ChassisBackground()

            ScrollView {
                VStack(spacing: 16) {
                    header

                    if mode == .edit {
                        statusCard
                    }

                    SetupCard(title: "Event") {
                        GlassField(label: "Event ID (no spaces)", text: $eventId, autocapitalize: false)
                        GlassField(label: "Display name", text: $displayName)
                        HStack(spacing: 10) {
                            SegmentChip(title: "Client-branded", isOn: branding == .custom) { branding = .custom }
                            SegmentChip(title: "Standard look", isOn: branding == .standard) { branding = .standard }
                        }
                    }

                    if branding == .custom {
                        SetupCard(title: "Branding") {
                            ColorPicker("Primary color", selection: $primaryColor)
                                .foregroundStyle(Chassis.textPrimary)
                            ColorPicker("Background color", selection: $backgroundColor)
                                .foregroundStyle(Chassis.textPrimary)
                            PhotosPicker(selection: $selectedLogo, matching: .images) {
                                GlassActionLabel(icon: "photo", title: "Choose logo")
                            }
                            if let logoData, let uiImage = UIImage(data: logoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 80)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    SetupCard(title: "Capture") {
                        GlassStepper(label: "Countdown", value: $countdownSeconds, range: 3...10, suffix: "s")
                    }

                    SetupCard(title: "Photo Strip") {
                        GlassToggle(title: "Enable photo strip", isOn: $stripEnabled)
                        if stripEnabled {
                            GlassToggle(
                                title: "Guest timelapse",
                                subtitle: "Records the whole strip session — countdowns, pose scrambles and all — into a fast behind-the-scenes GIF guests can share.",
                                isOn: $timelapseEnabled
                            )
                            ChipGroupLabel(text: "Shot counts offered")
                            HStack(spacing: 10) {
                                ForEach([2, 3, 4, 5, 6], id: \.self) { count in
                                    SegmentChip(title: "\(count)", isOn: stripShotCounts.contains(count)) {
                                        if stripShotCounts.contains(count) {
                                            stripShotCounts.remove(count)
                                        } else {
                                            stripShotCounts.insert(count)
                                        }
                                    }
                                }
                            }
                            ChipGroupLabel(text: "Layouts offered")
                            HStack(spacing: 10) {
                                ForEach(EventConfig.StripOptions.Layout.allCases, id: \.self) { layout in
                                    SegmentChip(title: layout.displayName, isOn: stripLayouts.contains(layout)) {
                                        if stripLayouts.contains(layout) {
                                            stripLayouts.remove(layout)
                                        } else {
                                            stripLayouts.insert(layout)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SetupCard(title: "Output Format") {
                        GlassToggle(
                            title: "Square crop (1:1)",
                            subtitle: "Applies to single photos and strips alike, before the Polaroid frame.",
                            isOn: $squareCrop
                        )
                        GlassToggle(title: "Guest filters (Retro, B&W, …)", isOn: $filtersEnabled)
                        GlassToggle(title: "Boomerang & GIF", isOn: $animationsEnabled)
                    }

                    SetupCard(title: "AI Features") {
                        GlassToggle(
                            title: "Face props (shades, dog ears, …)",
                            subtitle: "Guests pick a prop at the start screen — it tracks every detected face and is burned into photos and GIFs.",
                            isOn: $aiProps
                        )
                        GlassToggle(
                            title: "Smile to shoot",
                            subtitle: "The countdown starts automatically when someone smiles on the pose screen. All detection runs on this iPad — nothing is uploaded.",
                            isOn: $aiSmileShutter
                        )
                        GlassToggle(
                            title: "Glam filter",
                            subtitle: "Adds a beauty-pass chip (skin smoothing + brighten) to the guest filter picker. Runs on-device.",
                            isOn: $glamEnabled
                        )
                    }

                    SetupCard(title: "Background Replace") {
                        GlassToggle(
                            title: "Replace background (green screen)",
                            subtitle: "Segments the guest on-device and drops them onto a backdrop image — no green screen needed, nothing uploaded.",
                            isOn: $bgReplaceEnabled
                        )
                        if bgReplaceEnabled {
                            PhotosPicker(selection: $selectedBackdrop, matching: .images) {
                                GlassActionLabel(icon: "photo.artframe", title: "Choose backdrop image")
                            }
                            if let backdropData, let uiImage = UIImage(data: backdropData) {
                                Image(uiImage: uiImage)
                                    .resizable().scaledToFit().frame(height: 80).frame(maxWidth: .infinity)
                            } else if backdropAlreadySet {
                                FootnoteText("A backdrop is already set for this event. Pick a new image to replace it.")
                            }
                            FootnoteText("Use a full-bleed image at roughly the photo's aspect ratio for the cleanest fill.")
                        }
                    }

                    SetupCard(title: "Stickers") {
                        GlassToggle(
                            title: "Guest-selectable stickers",
                            subtitle: "Offers a set of decorative overlays guests can pick at the start screen, burned onto their photo.",
                            isOn: $stickersEnabled
                        )
                        if stickersEnabled {
                            PhotosPicker(selection: $selectedStickers, maxSelectionCount: 6, matching: .images) {
                                GlassActionLabel(icon: "face.smiling", title: "Choose sticker images (up to 6)")
                            }
                            if !stickerDatas.isEmpty {
                                FootnoteText("\(stickerDatas.count) sticker\(stickerDatas.count == 1 ? "" : "s") selected.")
                            } else if !existingStickerNames.isEmpty {
                                FootnoteText("\(existingStickerNames.count) sticker\(existingStickerNames.count == 1 ? "" : "s") already set. Pick new images to replace the set.")
                            }
                            FootnoteText("Use transparent PNGs sized to the whole frame.")
                        }
                    }

                    SetupCard(title: "Data Capture") {
                        GlassToggle(
                            title: "Collect guest details",
                            subtitle: "Shows a short form before guests get their photos. Leads are stored on this iPad and exported by you — never auto-uploaded.",
                            isOn: $dataCaptureEnabled
                        )
                        if dataCaptureEnabled {
                            GlassToggle(title: "Ask for name", isOn: $dcName)
                            GlassToggle(title: "Ask for email", isOn: $dcEmail)
                            GlassToggle(title: "Ask for phone", isOn: $dcPhone)
                            GlassField(label: "Marketing consent line (optional)", text: $dcConsent)
                            FootnoteText("If set, a consent checkbox with this text shows on the form and is recorded per lead.")
                        }
                    }

                    SetupCard(title: "Overlay / Frame") {
                        GlassToggle(title: "Burn overlay into photo", isOn: $overlayEnabled)
                        if overlayEnabled {
                            PhotosPicker(selection: $selectedOverlay, matching: .images) {
                                GlassActionLabel(icon: "photo.on.rectangle", title: "Choose overlay image")
                            }
                            if let overlayData, let uiImage = UIImage(data: overlayData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 80)
                                    .frame(maxWidth: .infinity)
                            }
                            FootnoteText("Author the overlay to match the current layout's aspect ratio (single photo vs. strip).")
                        }
                    }

                    SetupCard(title: "Sharing") {
                        GlassToggle(title: "AirDrop", isOn: $airdrop)
                        GlassToggle(
                            title: "QR Code",
                            subtitle: qrGallery ? "Needs the camera joined to the venue's own Wi-Fi (not its own private network) so guest phones can reach this device." : nil,
                            isOn: $qrGallery
                        )
                        GlassToggle(title: "Email", isOn: $email)
                    }

                    SetupCard(title: "Printing") {
                        GlassToggle(title: "Enabled", isOn: $printEnabled)
                        if printEnabled {
                            GlassToggle(title: "Limit prints per guest", isOn: $limitPrints)
                            if limitPrints {
                                GlassStepper(label: "Limit", value: $printLimitCount, range: 1...10)
                            }
                        }
                    }

                    // Not scoped to an event — the attendant PIN is
                    // install-wide, so this shows in both create and edit
                    // mode. Every install shipped with the same fixed
                    // "1234" and no way to change it; this is that way.
                    SetupCard(title: "Security") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Attendant PIN")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Chassis.textPrimary)
                            // Two separate bars, not one shared row — side
                            // by side they read as a single field split in
                            // two, which made it easy to type the new PIN
                            // into the wrong half.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Current PIN")
                                    .font(.caption)
                                    .foregroundStyle(Chassis.textSecondary)
                                SecureField("Current", text: $currentPINEntry)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(Chassis.textPrimary)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chassis.control))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("New PIN (4 digits)")
                                    .font(.caption)
                                    .foregroundStyle(Chassis.textSecondary)
                                SecureField("New", text: $newPINEntry)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(Chassis.textPrimary)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 14)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Chassis.control))
                            }

                            Button("Update PIN", action: changePIN)
                                .buttonStyle(.plain)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Chassis.accent)

                            if let pinMessage {
                                Text(pinMessage)
                                    .font(.caption)
                                    .foregroundStyle(pinMessage.hasPrefix("Updated") ? Chassis.accent : .red)
                            }
                        }
                    }

                    if mode == .edit {
                        Button {
                            showingDeleteConfirm = true
                        } label: {
                            Text("Delete Event")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if let saveMessage {
                        Text(saveMessage)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(saveMessage.hasPrefix("Saved") ? Chassis.accent : .red)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .animation(.snappy(duration: 0.25), value: stripEnabled)
        .animation(.snappy(duration: 0.25), value: overlayEnabled)
        .animation(.snappy(duration: 0.25), value: printEnabled)
        .animation(.snappy(duration: 0.25), value: limitPrints)
        .animation(.snappy(duration: 0.25), value: branding)
        .onChange(of: selectedLogo) { _, item in
            Task { logoData = try? await item?.loadTransferable(type: Data.self) }
        }
        .onChange(of: selectedBackdrop) { _, item in
            Task { backdropData = try? await item?.loadTransferable(type: Data.self) }
        }
        .onChange(of: selectedStickers) { _, items in
            Task {
                var loaded: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaded.append(data)
                    }
                }
                stickerDatas = loaded
            }
        }
        .onChange(of: selectedOverlay) { _, item in
            Task { overlayData = try? await item?.loadTransferable(type: Data.self) }
        }
        .onAppear {
            if mode == .edit {
                loadCurrent()
            }
        }
        .confirmationDialog(
            "Delete \"\(displayName)\"? This removes its photos and settings permanently.",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Event", role: .destructive, action: deleteEvent)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            clearLeadsPrompt,
            isPresented: $showingClearLeadsConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Contacts", role: .destructive) {
                EventStorage.shared.deleteLeads(eventId: model.config.eventId)
                leadsRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            purgeLeadsPrompt,
            isPresented: $showingPurgeLeadsConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All Contacts", role: .destructive) {
                EventStorage.shared.purgeAllLeads()
                leadsRevision += 1
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingExport) {
            PhotoExportSheet(photoURLs: EventStorage.shared.listPhotos(eventId: model.config.eventId))
        }
        .sheet(isPresented: $showingDiagExport) {
            if let diagExportURL {
                PhotoExportSheet(photoURLs: [diagExportURL])
            }
        }
        .sheet(isPresented: $showingLeadExport) {
            if let leadExportURL {
                PhotoExportSheet(photoURLs: [leadExportURL])
            }
        }
    }

    /// Custom chrome instead of a navigation bar — glass close control,
    /// large title, prominent save pill, matching the guest screens.
    private var header: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Chassis.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(Chassis.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Text(mode == .create ? "New Event" : "Event Setup")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Chassis.textPrimary)

            Spacer()

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 24)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(eventId.isEmpty || displayName.isEmpty)
            .opacity(eventId.isEmpty || displayName.isEmpty ? 0.4 : 1)
        }
        .padding(.top, 8)
    }

    /// Live attendant status + running totals for the *active* event — kept
    /// separate from whatever eventId is being typed into the form above, so
    /// editing the ID field doesn't make these numbers flicker to zero.
    private var statusCard: some View {
        _ = leadsRevision // read so a deletion re-evaluates the counts below
        let activeId = model.config.eventId
        let photos = EventStorage.shared.listPhotos(eventId: activeId).count
        let prints = EventStorage.shared.printCount(eventId: activeId)
        let guests = EventStorage.shared.guestSessionCount(eventId: activeId)
        let leads = EventStorage.shared.leadCount(eventId: activeId)
        let storageGB = EventStorage.shared.remainingCapacityGB()
        let holding = EventStorage.shared.eventsHoldingLeads()
        let totalLeadsOnDevice = holding.reduce(0) { $0 + $1.count }
        let otherEventsWithLeads = holding.filter { $0.eventId != activeId }.count

        return SetupCard(title: "Status") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: "\(photos)", label: "Photos")
                StatTile(value: "\(prints)", label: "Prints")
                StatTile(value: "\(guests)", label: "Guests")
                StatTile(value: "\(leads)", label: "Leads")
                StatTile(value: cameraConnected ? "On" : "Off", label: "Camera", accent: cameraConnected)
                StatTile(value: model.cameraBatteryLevel.map { "\($0)" } ?? "—", label: "Battery")
                StatTile(value: storageGB.map { String(format: "%.0f GB", $0) } ?? "—", label: "Free")
            }
            Button {
                showingExport = true
            } label: {
                GlassActionLabel(icon: "square.and.arrow.up", title: "Export All Photos (\(photos))")
            }
            .buttonStyle(.plain)
            .disabled(photos == 0)
            .opacity(photos == 0 ? 0.4 : 1)

            Button {
                exportLeads()
            } label: {
                GlassActionLabel(icon: "person.text.rectangle", title: "Export Leads (\(leads))")
            }
            .buttonStyle(.plain)
            .disabled(leads == 0)
            .opacity(leads == 0 ? 0.4 : 1)

            // Deleting contacts is separate from deleting the event, which
            // would take the photos with it. Until this existed the only way
            // to remove guest details was to destroy the operator's work,
            // so nothing ever got removed and every guest from every event
            // stayed on the iPad indefinitely.
            Button {
                showingClearLeadsConfirm = true
            } label: {
                GlassActionLabel(icon: "person.crop.circle.badge.xmark", title: "Delete Contacts (\(leads))")
            }
            .buttonStyle(.plain)
            .disabled(leads == 0)
            .opacity(leads == 0 ? 0.4 : 1)

            if let oldest = EventStorage.shared.oldestLeadDate(eventId: activeId) {
                Text("Oldest contact on this event: \(Self.ageFormatter.localizedString(for: oldest, relativeTo: Date())).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Device-wide, not event-scoped: the handover case. An iPad
            // being sold, returned to a rental pool or handed to another
            // operator should not carry the previous one's guest lists.
            if otherEventsWithLeads > 0 {
                Button {
                    showingPurgeLeadsConfirm = true
                } label: {
                    GlassActionLabel(
                        icon: "trash",
                        title: "Delete Contacts on ALL Events (\(totalLeadsOnDevice))"
                    )
                }
                .buttonStyle(.plain)
            }

            // Diagnostics are per-install, not per-event, so this one isn't
            // gated on the current event having data the way the two above
            // are. After something goes wrong at a real event this is the
            // only record of what actually happened.
            Button {
                exportDiagnostics()
            } label: {
                GlassActionLabel(icon: "doc.text.magnifyingglass", title: "Export Diagnostics Log")
            }
            .buttonStyle(.plain)
        }
    }

    /// Writes the diagnostic log to a temp file and opens the share sheet.
    /// Silently no-ops when nothing has been logged, rather than sharing an
    /// empty file that looks like a broken export.
    private func exportDiagnostics() {
        guard let url = DiagnosticLog.shared.exportFile() else { return }
        diagExportURL = url
        showingDiagExport = true
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Both prompts name the count and say explicitly what survives. A
    /// destructive confirmation that only says "are you sure" gets dismissed
    /// by reflex, and the thing an attendant most needs to know here is that
    /// the photos are not going anywhere.
    private var clearLeadsPrompt: String {
        let n = EventStorage.shared.leadCount(eventId: model.config.eventId)
        return "Delete \(n) contact\(n == 1 ? "" : "s") from \"\(model.config.displayName)\"? "
            + "Photos and settings are kept. Export first if you haven't. This cannot be undone."
    }

    private var purgeLeadsPrompt: String {
        let holding = EventStorage.shared.eventsHoldingLeads()
        let total = holding.reduce(0) { $0 + $1.count }
        return "Delete all \(total) contact\(total == 1 ? "" : "s") across \(holding.count) event\(holding.count == 1 ? "" : "s") on this iPad? "
            + "Every photo is kept. Use this when handing the device to someone else. This cannot be undone."
    }

    /// Writes the event's collected leads to a temp CSV and opens the share
    /// sheet so the attendant can email/AirDrop the list off the device.
    private func exportLeads() {
        let csv = EventStorage.shared.leadsCSV(eventId: model.config.eventId)
        // Same sanitizer the storage layer uses — the raw eventId is
        // attendant-typed free text, and a path separator in it would make
        // this temp write fail (silently, per the guard below).
        let safeId = EventStorage.sanitizeEventId(model.config.eventId)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leads-\(safeId).csv")
        guard (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        leadExportURL = url
        showingLeadExport = true
    }

    private var cameraConnected: Bool {
        switch model.step {
        case .login, .home, .eventPicker, .connecting:
            return false
        default:
            return true
        }
    }

    private func loadCurrent() {
        let current = model.config
        eventId = current.eventId
        displayName = current.displayName
        branding = current.branding
        primaryColor = Color(hex: current.colors.primaryHex) ?? .blue
        backgroundColor = Color(hex: current.colors.backgroundHex) ?? .black
        countdownSeconds = current.countdownSeconds
        airdrop = current.share.airdrop
        qrGallery = current.share.qrGallery
        email = current.share.email
        printEnabled = current.print.enabled
        limitPrints = current.print.limitPerGuest != nil
        printLimitCount = current.print.limitPerGuest ?? 1
        overlayEnabled = current.overlay.enabled
        stripEnabled = current.strip.enabled
        stripShotCounts = Set(current.strip.shotCounts)
        stripLayouts = Set(current.strip.layouts)
        squareCrop = current.squareCrop
        filtersEnabled = current.filtersEnabled
        animationsEnabled = current.animationsEnabled
        aiProps = current.ai.props
        aiSmileShutter = current.ai.smileShutter
        timelapseEnabled = current.timelapseEnabled
        glamEnabled = current.glam.enabled
        bgReplaceEnabled = current.backgroundReplace.enabled
        stickersEnabled = current.stickers.enabled
        existingStickerNames = current.stickers.assetNames
        dataCaptureEnabled = current.dataCapture.enabled
        dcName = current.dataCapture.collectName
        dcEmail = current.dataCapture.collectEmail
        dcPhone = current.dataCapture.collectPhone
        dcConsent = current.dataCapture.consentText
    }

    /// True when the event already has a backdrop asset saved (edit mode) so
    /// the UI can say "already set" instead of showing nothing.
    private var backdropAlreadySet: Bool {
        model.config.backgroundReplace.backdropAssetName != nil
    }

    private func changePIN() {
        guard currentPINEntry == AdminPIN.current else {
            pinMessage = "Current PIN is wrong"
            return
        }
        guard newPINEntry.count == 4, newPINEntry.allSatisfy(\.isNumber) else {
            pinMessage = "New PIN must be 4 digits"
            return
        }
        AdminPIN.set(newPINEntry)
        currentPINEntry = ""
        newPINEntry = ""
        pinMessage = "Updated"
    }

    private func save() {
        // Normalized before it ever reaches EventStorage, so the id shown
        // in the UI (event picker rows, status panel) matches the actual
        // on-disk folder name EventStorage.eventDirectory() derives from
        // it — that function also sanitizes defensively, but doing it here
        // too avoids a raw-vs-sanitized display mismatch for a new event.
        eventId = EventStorage.sanitizeEventId(eventId)
        // A backdrop is present if one was just picked or already exists on
        // this event; only then is it worth pointing the config at the file.
        let hasBackdrop = backdropData != nil || model.config.backgroundReplace.backdropAssetName != nil
        // New sticker set if re-picked this session; otherwise keep the saved
        // filenames (edit mode, files already on disk).
        let stickerNames: [String] = !stickerDatas.isEmpty
            ? stickerDatas.indices.map { "sticker_\($0).png" }
            : existingStickerNames
        var config = EventConfig(
            eventId: eventId,
            displayName: displayName,
            branding: branding,
            colors: .init(primaryHex: primaryColor.hexString, backgroundHex: backgroundColor.hexString),
            countdownSeconds: countdownSeconds,
            share: .init(airdrop: airdrop, qrGallery: qrGallery, email: email),
            print: .init(enabled: printEnabled, limitPerGuest: limitPrints ? printLimitCount : nil),
            overlay: .init(enabled: overlayEnabled, assetName: overlayEnabled ? "overlay.png" : nil),
            strip: .init(
                enabled: stripEnabled,
                shotCounts: stripShotCounts.isEmpty ? [3] : stripShotCounts.sorted(),
                layouts: stripLayouts.isEmpty ? [.vertical] : stripLayouts.sorted()
            ),
            squareCrop: squareCrop,
            filtersEnabled: filtersEnabled,
            animationsEnabled: animationsEnabled,
            timelapseEnabled: timelapseEnabled,
            ai: .init(props: aiProps, smileShutter: aiSmileShutter),
            backgroundReplace: .init(
                enabled: bgReplaceEnabled,
                backdropAssetName: (bgReplaceEnabled && hasBackdrop) ? "backdrop.png" : nil
            ),
            glam: .init(enabled: glamEnabled),
            dataCapture: .init(
                enabled: dataCaptureEnabled,
                collectName: dcName,
                collectEmail: dcEmail,
                collectPhone: dcPhone,
                consentText: dcConsent.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            stickers: .init(enabled: stickersEnabled, assetNames: stickersEnabled ? stickerNames : [])
        )
        // The form doesn't carry every field. When EDITING, rebuilding from
        // scratch would silently reset the ones it omits: isRemote (→ false,
        // which routes deleteEvent down the local-only path and lets the
        // dashboard event resurrect on next sync), logoAssetName (→ nil,
        // detaching the client's logo mid-event), createdAt (→ now, reordering
        // the picker), and share.sms. Carry those over from the existing
        // config. Create mode keeps the fresh defaults, which is correct.
        if mode == .edit {
            config.isRemote = model.config.isRemote
            config.createdAt = model.config.createdAt
            config.share.sms = model.config.share.sms
            if logoData == nil {
                config.logoAssetName = model.config.logoAssetName
            }
        }
        do {
            try EventStorage.shared.createEvent(config)
            if let logoData {
                let filename = try EventStorage.shared.importLogoData(logoData, eventId: eventId)
                config.logoAssetName = filename
                try EventStorage.shared.save(config)
            }
            if overlayEnabled, let overlayData {
                _ = try EventStorage.shared.importLogoData(overlayData, eventId: eventId, filename: "overlay.png")
            }
            if bgReplaceEnabled, let backdropData {
                _ = try EventStorage.shared.importLogoData(backdropData, eventId: eventId, filename: "backdrop.png")
            }
            if stickersEnabled, !stickerDatas.isEmpty {
                for (index, data) in stickerDatas.enumerated() {
                    _ = try EventStorage.shared.importLogoData(data, eventId: eventId, filename: "sticker_\(index).png")
                }
            }
            model.reloadConfig()
            saveMessage = "Saved — will load on next connect"
        } catch {
            saveMessage = "Save failed: \(error)"
        }
    }

    /// Deletes the event, then backs out to the event picker — there's no
    /// valid "current" event left to fall back into.
    ///
    /// For a purely local event (never synced), deleting on disk is
    /// enough — there's no server copy to worry about. For a remote
    /// (dashboard-synced) event, deleting locally-only isn't durable: the
    /// booth re-syncs its event list every time it returns to the picker,
    /// and since the server never learned about the delete, that sync
    /// just re-downloads the "missing" event and recreates it locally
    /// with a fresh createdAt — which is why deleting used to silently
    /// undo itself and bump the event to the top of the list instead of
    /// removing it. The server delete now runs FIRST, so a failure (e.g.
    /// an operator session — deleting requires owner/admin) reports an
    /// error instead of removing the event locally only for it to
    /// reappear moments later.
    private func deleteEvent() {
        let idToDelete = model.config.eventId
        guard model.config.isRemote else {
            try? EventStorage.shared.deleteEvent(idToDelete)
            model.backToEventPicker()
            dismiss()
            return
        }
        Task {
            do {
                try await RemoteSync.deleteRemoteEvent(idToDelete)
                try? EventStorage.shared.deleteEvent(idToDelete)
                await MainActor.run {
                    model.backToEventPicker()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    saveMessage = "Couldn't delete — only the org owner or an admin can delete an event. Try from the dashboard, or ask them."
                }
            }
        }
    }
}

// MARK: - Glass form components

/// One floating glass card with an uppercase tracked section label —
/// replaces a Form Section.
private struct SetupCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChassisLabel(text: title, size: 11)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .chassisPanel(cornerRadius: 24)
    }
}

private struct GlassToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Chassis.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Chassis.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Chassis.accent)
        }
    }
}

private struct GlassField: View {
    let label: String
    @Binding var text: String
    var autocapitalize = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Chassis.textSecondary)
            TextField("", text: $text)
                .font(.system(size: 15))
                .foregroundStyle(Chassis.textPrimary)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Chassis.control.opacity(0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Chassis.hairline, lineWidth: 1)
                )
                #if os(iOS)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                #endif
        }
    }
}

/// Capsule chip that toggles membership — used for single-select segments
/// (branding) and multi-select groups (shot counts, layouts).
private struct SegmentChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : Chassis.textPrimary)
                .padding(.vertical, 9)
                .padding(.horizontal, 16)
                .background(
                    Capsule().fill(isOn ? AnyShapeStyle(Chassis.accent) : AnyShapeStyle(Chassis.control.opacity(0.8)))
                )
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Chassis.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isOn)
    }
}

private struct GlassStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix = ""

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Chassis.textPrimary)
            Spacer()
            HStack(spacing: 14) {
                StepButton(symbol: "minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }
                Text("\(value)\(suffix)")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Chassis.textPrimary)
                    .frame(minWidth: 38)
                StepButton(symbol: "plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
        }
    }

    private struct StepButton: View {
        let symbol: String
        let enabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Chassis.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Chassis.control.opacity(0.8)))
                    .overlay(Circle().strokeBorder(Chassis.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
        }
    }
}

/// Row content for glass action buttons (photo pickers, export) — icon +
/// title on a control-toned rounded rect.
private struct GlassActionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(Chassis.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Chassis.control.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Chassis.hairline, lineWidth: 1)
        )
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    var accent = false

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(accent ? Chassis.accent : Chassis.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Chassis.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Chassis.control.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Chassis.hairline, lineWidth: 1)
        )
    }
}

private struct ChipGroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Chassis.textSecondary)
    }
}

private struct FootnoteText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Chassis.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Color {
    /// Round-trips through UIColor to get sRGB components regardless of how
    /// the Color was constructed (ColorPicker, hex init, system color, etc).
    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

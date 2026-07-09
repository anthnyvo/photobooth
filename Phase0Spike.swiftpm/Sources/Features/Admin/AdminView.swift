import SwiftUI
import PhotosUI

/// Config-builder: the attendant fills this in once, ahead of the event,
/// per the pre-event branding conversation with the client. Submitting
/// writes config.json + copies the logo into that event's asset folder —
/// no hand-written JSON, no file edits on event day.
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
    @State private var stripLayout: EventConfig.StripOptions.Layout = .vertical
    @State private var squareCrop = false
    @State private var selectedLogo: PhotosPickerItem?
    @State private var logoData: Data?
    @State private var selectedOverlay: PhotosPickerItem?
    @State private var overlayData: Data?
    @State private var saveMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var showingExport = false

    var body: some View {
        NavigationStack {
            Form {
                if mode == .edit {
                    statusSection
                }

                Section("Event") {
                    TextField("Event ID (no spaces)", text: $eventId)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Display name", text: $displayName)
                    Picker("Branding", selection: $branding) {
                        Text("Custom (client-branded)").tag(EventConfig.BrandingMode.custom)
                        Text("Standard (default look)").tag(EventConfig.BrandingMode.standard)
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                if branding == .custom {
                    Section("Branding") {
                        ColorPicker("Primary color", selection: $primaryColor)
                        ColorPicker("Background color", selection: $backgroundColor)
                        PhotosPicker("Choose logo", selection: $selectedLogo, matching: .images)
                        if let logoData, let uiImage = UIImage(data: logoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 80)
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                Section("Capture") {
                    Stepper("Countdown: \(countdownSeconds)s", value: $countdownSeconds, in: 3...10)
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Photo Strip") {
                    Toggle("Enable photo strip", isOn: $stripEnabled)
                    if stripEnabled {
                        Text("Shot counts offered")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach([2, 3, 4, 5, 6], id: \.self) { count in
                            Toggle("\(count) shots", isOn: Binding(
                                get: { stripShotCounts.contains(count) },
                                set: { isOn in
                                    if isOn { stripShotCounts.insert(count) } else { stripShotCounts.remove(count) }
                                }
                            ))
                        }
                        Picker("Layout", selection: $stripLayout) {
                            Text("Vertical").tag(EventConfig.StripOptions.Layout.vertical)
                            Text("Horizontal").tag(EventConfig.StripOptions.Layout.horizontal)
                            Text("Grid").tag(EventConfig.StripOptions.Layout.grid)
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Output Format") {
                    Toggle("Square crop (1:1)", isOn: $squareCrop)
                    Text("Applies to single photos and strips alike, before the Polaroid frame.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Overlay / Frame") {
                    Toggle("Burn overlay into photo", isOn: $overlayEnabled)
                    if overlayEnabled {
                        PhotosPicker("Choose overlay image", selection: $selectedOverlay, matching: .images)
                        if let overlayData, let uiImage = UIImage(data: overlayData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 80)
                        }
                        Text("Author the overlay to match the current layout's aspect ratio (single photo vs. strip).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                Section("Sharing") {
                    Toggle("AirDrop", isOn: $airdrop)
                    Toggle("QR Code", isOn: $qrGallery)
                    Toggle("Email", isOn: $email)
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                if qrGallery {
                    Section {
                        Text("QR sharing needs the camera joined to the venue's own Wi-Fi (not its own private network) so guest phones can reach this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                Section("Printing") {
                    Toggle("Enabled", isOn: $printEnabled)
                    if printEnabled {
                        Toggle("Limit prints per guest", isOn: $limitPrints)
                        if limitPrints {
                            Stepper("Limit: \(printLimitCount)", value: $printLimitCount, in: 1...10)
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                if mode == .edit {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            showingDeleteConfirm = true
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }

                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(.green)
                        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }
            }
            .scrollContentBackground(.hidden)
            .background(ChassisBackground())
            .tint(Chassis.accent)
            .navigationTitle(mode == .create ? "New Event" : "Event Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(eventId.isEmpty || displayName.isEmpty)
                }
            }
            .onChange(of: selectedLogo) { _, item in
                Task { logoData = try? await item?.loadTransferable(type: Data.self) }
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
            .sheet(isPresented: $showingExport) {
                PhotoExportSheet(photoURLs: EventStorage.shared.listPhotos(eventId: model.config.eventId))
            }
        }
    }

    /// Live attendant status + running totals for the *active* event — kept
    /// separate from whatever eventId is being typed into the form above, so
    /// editing the ID field doesn't make these numbers flicker to zero.
    private var statusSection: some View {
        let activeId = model.config.eventId
        let photos = EventStorage.shared.listPhotos(eventId: activeId).count
        let prints = EventStorage.shared.printCount(eventId: activeId)
        let guests = EventStorage.shared.guestSessionCount(eventId: activeId)
        let storageGB = EventStorage.shared.remainingCapacityGB()

        return Section("Status") {
            LabeledContent("Camera", value: cameraConnected ? "Connected" : "Not connected")
            LabeledContent("Battery", value: model.cameraBatteryLevel.map { "\($0)" } ?? "—")
            LabeledContent("Photos taken", value: "\(photos)")
            LabeledContent("Prints", value: "\(prints)")
            LabeledContent("Guest sessions", value: "\(guests)")
            LabeledContent("Storage free", value: storageGB.map { String(format: "%.1f GB", $0) } ?? "—")
            Button("Export All Photos (\(photos))") {
                showingExport = true
            }
            .disabled(photos == 0)
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
    }

    private var cameraConnected: Bool {
        switch model.step {
        case .eventPicker, .connecting:
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
        stripLayout = current.strip.layout
        squareCrop = current.squareCrop
    }

    private func save() {
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
                layout: stripLayout
            ),
            squareCrop: squareCrop
        )
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
            model.reloadConfig()
            saveMessage = "Saved — will load on next connect"
        } catch {
            saveMessage = "Save failed: \(error)"
        }
    }

    /// Deletes the active event on disk, then backs out to the event
    /// picker — there's no valid "current" event left to fall back into.
    private func deleteEvent() {
        let idToDelete = model.config.eventId
        try? EventStorage.shared.deleteEvent(idToDelete)
        model.backToEventPicker()
        dismiss()
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

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
    @State private var saveMessage: String?
    @State private var showingDeleteConfirm = false
    @State private var showingExport = false

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
        let activeId = model.config.eventId
        let photos = EventStorage.shared.listPhotos(eventId: activeId).count
        let prints = EventStorage.shared.printCount(eventId: activeId)
        let guests = EventStorage.shared.guestSessionCount(eventId: activeId)
        let storageGB = EventStorage.shared.remainingCapacityGB()

        return SetupCard(title: "Status") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: "\(photos)", label: "Photos")
                StatTile(value: "\(prints)", label: "Prints")
                StatTile(value: "\(guests)", label: "Guests")
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
        }
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
                layouts: stripLayouts.isEmpty ? [.vertical] : stripLayouts.sorted()
            ),
            squareCrop: squareCrop,
            filtersEnabled: filtersEnabled,
            animationsEnabled: animationsEnabled,
            timelapseEnabled: timelapseEnabled,
            ai: .init(props: aiProps, smileShutter: aiSmileShutter)
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

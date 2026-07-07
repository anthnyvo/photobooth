import SwiftUI
import PhotosUI

/// Config-builder: the attendant fills this in once, ahead of the event,
/// per the pre-event branding conversation with the client. Submitting
/// writes config.json + copies the logo into that event's asset folder —
/// no hand-written JSON, no file edits on event day.
struct AdminView: View {
    @ObservedObject var model: BoothViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var eventId: String = ""
    @State private var displayName: String = ""
    @State private var branding: EventConfig.BrandingMode = .standard
    @State private var primaryColor: Color = .blue
    @State private var backgroundColor: Color = .black
    @State private var countdownSeconds: Int = 5
    @State private var airdrop = true
    @State private var printEnabled = true
    @State private var selectedLogo: PhotosPickerItem?
    @State private var logoData: Data?
    @State private var saveMessage: String?

    var body: some View {
        NavigationStack {
            Form {
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
                }

                Section("Capture") {
                    Stepper("Countdown: \(countdownSeconds)s", value: $countdownSeconds, in: 3...10)
                }

                Section("Sharing") {
                    Toggle("AirDrop", isOn: $airdrop)
                    Toggle("Print", isOn: $printEnabled)
                }

                if let saveMessage {
                    Text(saveMessage).foregroundStyle(.green)
                }
            }
            .navigationTitle("Event Setup")
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
            .onAppear(perform: loadCurrent)
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
        printEnabled = current.print.enabled
    }

    private func save() {
        var config = EventConfig(
            eventId: eventId,
            displayName: displayName,
            branding: branding,
            colors: .init(primaryHex: primaryColor.hexString, backgroundHex: backgroundColor.hexString),
            countdownSeconds: countdownSeconds,
            share: .init(airdrop: airdrop),
            print: .init(enabled: printEnabled)
        )
        do {
            try EventStorage.shared.createEvent(config)
            if let logoData {
                let filename = try EventStorage.shared.importLogoData(logoData, eventId: eventId)
                config.logoAssetName = filename
                try EventStorage.shared.save(config)
            }
            model.reloadConfig()
            saveMessage = "Saved — will load on next connect"
        } catch {
            saveMessage = "Save failed: \(error)"
        }
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

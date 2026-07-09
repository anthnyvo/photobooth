import SwiftUI

/// Hands the whole event's photo folder to the system share sheet at once
/// (AirDrop to a laptop, save to Files, etc.) — the only export path before
/// this was per-photo AirDrop/email/QR from the guest-facing share screen,
/// with no way to grab everything after the event wraps.
struct PhotoExportSheet: UIViewControllerRepresentable {
    let photoURLs: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: photoURLs, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

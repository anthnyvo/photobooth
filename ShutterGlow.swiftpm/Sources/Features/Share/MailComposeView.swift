import SwiftUI
import MessageUI

/// Email share channel — wraps the system mail compose sheet with the final
/// photo attached. Only ever presented when
/// MFMailComposeViewController.canSendMail() is true (checked by ShareView
/// before showing the Email button), since this silently can't work if the
/// device has no Mail account configured.
struct MailComposeView: UIViewControllerRepresentable {
    let photoURL: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject("Your photo")
        if let data = try? Data(contentsOf: photoURL) {
            let mimeType = photoURL.pathExtension.lowercased() == "gif" ? "image/gif" : "image/jpeg"
            controller.addAttachmentData(data, mimeType: mimeType, fileName: photoURL.lastPathComponent)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}

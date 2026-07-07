import SwiftUI
import UIKit

/// Thin wrapper around the standard AirPrint API — no vendor SDK, works with
/// whatever printer is on the network. Swapping printers later is a hardware
/// change only.
@MainActor
final class PrintJob: ObservableObject {
    @Published var statusMessage: String?

    func print(photoURL: URL) {
        guard let image = UIImage(contentsOfFile: photoURL.path) else {
            statusMessage = "Couldn't load photo to print"
            return
        }
        guard UIPrintInteractionController.isPrintingAvailable else {
            statusMessage = "No printer available"
            return
        }

        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .photo
        printInfo.jobName = "Photobooth print"

        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo
        controller.printingItem = image

        statusMessage = "Sending to printer…"
        controller.present(animated: true) { [weak self] _, completed, error in
            Task { @MainActor in
                if completed {
                    self?.statusMessage = "Sent to printer"
                } else if let error {
                    self?.statusMessage = "Print failed: \(error.localizedDescription)"
                } else {
                    self?.statusMessage = nil // user cancelled — not an error
                }
            }
        }
    }
}

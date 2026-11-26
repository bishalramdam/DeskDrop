import AppKit
import CoreImage
import Foundation

enum QRCodeGenerator {
    static func generate(from string: String, size: CGFloat = 180) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(size / extent.width, size / extent.height)
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: transformed)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

import SwiftUI
import CoreVideo
import AppKit
import CoreImage

#if os(macOS)
public struct CameraPreviewView: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer?

    public init(pixelBuffer: CVPixelBuffer?) {
        self.pixelBuffer = pixelBuffer
    }

    public func makeNSView(context: Context) -> NSView {
        let view = PreviewNSView()
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewView = nsView as? PreviewNSView else { return }
        if let pixelBuffer = pixelBuffer {
            previewView.displayPixelBuffer(pixelBuffer)
        }
    }
}

class PreviewNSView: NSView {
    private var imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(imageView)
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
            if let cgImage = cgImage {
                let nsImage = NSImage(cgImage: cgImage, size: .zero)
                self.imageView.image = nsImage
            }
        }
    }
}
#endif

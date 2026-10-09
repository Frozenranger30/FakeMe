import Foundation
import CoreMedia
import CoreVideo

public final class VirtualCameraPublisher {
    private let lock = NSLock()
    private var frameCallback: ((CVPixelBuffer, CMTime) -> Void)?

    public func publishFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        frameCallback?(pixelBuffer, timestamp)
    }

    public func setFrameCallback(_ callback: @escaping (CVPixelBuffer, CMTime) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        frameCallback = callback
    }

    public func clearFrameCallback() {
        lock.lock()
        defer { lock.unlock() }
        frameCallback = nil
    }
}

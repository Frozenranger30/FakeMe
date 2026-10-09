import Foundation
import CoreVideo
import CoreMedia
import os

/// Thread-safe Sendable box for holding mutable state across @Sendable test closures.
public final class LockedBox<T>: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value: T
    
    public init(_ value: T) {
        self.value = value
    }
    
    @discardableResult
    public func withValue<R>(_ block: (inout T) -> R) -> R {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return block(&value)
    }
    
    public var current: T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}

/// Utilities for creating synthetic pixel buffers and inspecting memory in unit tests.
public enum TestFrameFactory {
    
    /// Creates a 32BGRA pixel buffer filled with a solid color.
    public static func makeSolidBuffer(
        width: Int = 64,
        height: Int = 64,
        b: UInt8,
        g: UInt8,
        r: UInt8,
        a: UInt8 = 255
    ) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            fatalError("Failed to allocate CVPixelBuffer in TestFrameFactory")
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        for y in 0..<height {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                row[x * 4 + 0] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = a
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    
    /// Reads the BGRA pixel values at the specified coordinate.
    public static func readPixel(
        from buffer: CVPixelBuffer,
        x: Int = 0,
        y: Int = 0
    ) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = ptr.advanced(by: y * bytesPerRow)
        return (row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3])
    }
}

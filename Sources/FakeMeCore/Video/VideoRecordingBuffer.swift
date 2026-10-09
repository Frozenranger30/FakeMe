import Foundation
import CoreVideo
import os

/// High-performance in-memory frame buffer backed by a `CVPixelBufferPool`.
///
/// Provides zero-latency frame storage and retrieval for recorded video clips.
/// Incoming frames are deep-copied into pool-managed buffers to prevent starvation
/// of the hardware camera capture queue.
public final class VideoRecordingBuffer: @unchecked Sendable {
    
    // MARK: - Properties
    
    private var lock = os_unfair_lock()
    private var frames: [CVPixelBuffer] = []
    private var pixelBufferPool: CVPixelBufferPool?
    
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolPixelFormat: OSType = 0
    
    /// Maximum number of frames this buffer will hold.
    public private(set) var maxCapacity: Int
    
    // MARK: - Initialization
    
    /// Initializes the recording buffer with a maximum frame capacity.
    /// - Parameter maxCapacity: Maximum frame count (default: 300 frames, approx. 10s @ 30fps).
    public init(maxCapacity: Int = 300) {
        self.maxCapacity = maxCapacity
    }
    
    /// Convenience initializer supporting optional explicit width/height hinting.
    public convenience init(maxCapacity: Int = 300, width: Int? = nil, height: Int? = nil) {
        self.init(maxCapacity: maxCapacity)
        if let w = width, let h = height {
            self.rebuildPool(width: w, height: h, format: kCVPixelFormatType_32BGRA)
        }
    }
    
    deinit {
        clear()
        pixelBufferPool = nil
    }
    
    // MARK: - Buffer Inspection
    
    /// Current number of recorded frames in the buffer.
    public var count: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.count
    }
    
    /// Indicates whether the buffer contains no frames.
    public var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.isEmpty
    }
    
    /// Indicates whether the buffer has reached its maximum capacity.
    public var isFull: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.count >= maxCapacity
    }
    
    /// Calculated duration of recorded frames at the specified frame rate.
    public func duration(atFPS fps: Double = 30.0) -> TimeInterval {
        guard fps > 0 else { return 0.0 }
        return Double(count) / fps
    }
    
    /// Configures the maximum capacity of the buffer.
    /// If the new capacity is lower than current frame count, excess frames are truncated.
    public func setMaxCapacity(_ newCapacity: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        self.maxCapacity = max(1, newCapacity)
        if frames.count > maxCapacity {
            frames.removeSubrange(maxCapacity..<frames.count)
        }
    }
    
    // MARK: - Frame Mutation
    
    /// Appends a source frame to the recording buffer by cloning it into a pool-managed buffer.
    ///
    /// If the buffer has reached `maxCapacity`, the frame is discarded.
    /// Returns `true` if the frame was successfully cloned and appended, `false` otherwise.
    @discardableResult
    public func append(_ sourceBuffer: CVPixelBuffer) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        guard frames.count < maxCapacity else { return false }
        
        let width = CVPixelBufferGetWidth(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        let format = CVPixelBufferGetPixelFormatType(sourceBuffer)
        
        // Ensure pool matches current incoming dimensions and format
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height || poolPixelFormat != format {
            rebuildPool(width: width, height: height, format: format)
        }
        
        var destinationBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
        }
        
        if destinationBuffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                format,
                nil,
                &destinationBuffer
            )
        }
        
        guard let dest = destinationBuffer else {
            return false
        }
        
        Self.copyPixelBuffer(from: sourceBuffer, to: dest)
        frames.append(dest)
        return true
    }
    
    /// Retrieves a recorded frame at the specified index.
    /// - Parameter index: Zero-based frame index.
    /// - Returns: The `CVPixelBuffer` at the index, or `nil` if out of bounds.
    public func frame(at index: Int) -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }
    
    /// The first recorded frame (index 0).
    public var firstFrame: CVPixelBuffer? {
        frame(at: 0)
    }
    
    /// The last recorded frame.
    public var lastFrame: CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frames.last
    }
    
    /// Clears all stored frames, releasing buffer references back to the pool.
    public func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        frames.removeAll(keepingCapacity: true)
    }
    
    // MARK: - Private Helpers
    
    private func rebuildPool(width: Int, height: Int, format: OSType) {
        pixelBufferPool = nil
        
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 30
        ]
        
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )
        
        if status == kCVReturnSuccess {
            self.pixelBufferPool = newPool
            self.poolWidth = width
            self.poolHeight = height
            self.poolPixelFormat = format
        }
    }
    
    /// Copies pixel memory from source to destination handling planar, strided, and bounded buffers.
    /// Clamps copied regions to the intersection of source and destination dimensions to prevent
    /// out-of-bounds heap memory access, and zero-fills unwritten destination bytes.
    public static func copyPixelBuffer(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(src) == CVPixelBufferGetPixelFormatType(dst),
              CVPixelBufferIsPlanar(src) == CVPixelBufferIsPlanar(dst) else {
            // Cannot perform raw byte-level copy across incompatible pixel formats or planarity models.
            return
        }
        
        let srcLockStatus = CVPixelBufferLockBaseAddress(src, .readOnly)
        guard srcLockStatus == kCVReturnSuccess else { return }
        
        let dstLockStatus = CVPixelBufferLockBaseAddress(dst, [])
        guard dstLockStatus == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            return
        }
        
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        
        if CVPixelBufferIsPlanar(src) {
            let srcPlaneCount = CVPixelBufferGetPlaneCount(src)
            let dstPlaneCount = CVPixelBufferGetPlaneCount(dst)
            let planeCount = min(srcPlaneCount, dstPlaneCount)
            
            for plane in 0..<planeCount {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
                
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                let srcHeight = CVPixelBufferGetHeightOfPlane(src, plane)
                let dstHeight = CVPixelBufferGetHeightOfPlane(dst, plane)
                
                let copyHeight = min(srcHeight, dstHeight)
                let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
                
                if srcBytesPerRow == dstBytesPerRow && copyBytes == dstBytesPerRow {
                    memcpy(dstBase, srcBase, copyHeight * dstBytesPerRow)
                } else {
                    for row in 0..<copyHeight {
                        let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                        let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                        memcpy(dstRow, srcRow, copyBytes)
                        if dstBytesPerRow > copyBytes {
                            memset(dstRow.advanced(by: copyBytes), 0, dstBytesPerRow - copyBytes)
                        }
                    }
                }
                
                if dstHeight > copyHeight {
                    let remainingStart = dstBase.advanced(by: copyHeight * dstBytesPerRow)
                    memset(remainingStart, 0, (dstHeight - copyHeight) * dstBytesPerRow)
                }
            }
            
            // Zero-fill any additional destination planes not present in source
            if dstPlaneCount > planeCount {
                for plane in planeCount..<dstPlaneCount {
                    guard let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
                    let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                    let dstHeight = CVPixelBufferGetHeightOfPlane(dst, plane)
                    memset(dstBase, 0, dstHeight * dstBytesPerRow)
                }
            }
        } else {
            guard let srcBase = CVPixelBufferGetBaseAddress(src),
                  let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }
            
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(src)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
            let srcHeight = CVPixelBufferGetHeight(src)
            let dstHeight = CVPixelBufferGetHeight(dst)
            
            let copyHeight = min(srcHeight, dstHeight)
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
            
            if srcBytesPerRow == dstBytesPerRow && copyBytes == dstBytesPerRow {
                memcpy(dstBase, srcBase, copyHeight * dstBytesPerRow)
            } else {
                for row in 0..<copyHeight {
                    let dstRow = dstBase.advanced(by: row * dstBytesPerRow)
                    let srcRow = srcBase.advanced(by: row * srcBytesPerRow)
                    memcpy(dstRow, srcRow, copyBytes)
                    if dstBytesPerRow > copyBytes {
                        memset(dstRow.advanced(by: copyBytes), 0, dstBytesPerRow - copyBytes)
                    }
                }
            }
            
            if dstHeight > copyHeight {
                let remainingStart = dstBase.advanced(by: copyHeight * dstBytesPerRow)
                memset(remainingStart, 0, (dstHeight - copyHeight) * dstBytesPerRow)
            }
        }
    }
}

import Foundation
import CoreImage
import CoreVideo
import os

/// Transition interpolation curve applied during crossfade blending.
public enum TransitionCurve: Sendable {
    /// Strictly linear byte-level interpolation: alpha = t.
    case linear
    /// Smooth Hermite interpolation: alpha = 3t^2 - 2t^3 with zero endpoints derivative.
    case smoothstep
    
    /// Maps a normalized progress value [0.0, 1.0] through the curve.
    public func mapProgress(_ progress: Float) -> Float {
        let t = max(0.0, min(1.0, progress))
        switch self {
        case .linear:
            return t
        case .smoothstep:
            return t * t * (3.0 - 2.0 * t)
        }
    }
}

/// Metal GPU-accelerated video crossfade engine using `CIDissolveTransition`.
public final class CrossfadeEngine: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let ciContext: CIContext
    private let filter: CIFilter
    private var lock = os_unfair_lock()
    
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    
    // MARK: - Initialization
    
    /// Initializes the CrossfadeEngine.
    ///
    /// Configures `CIContext` with `workingColorSpace: NSNull()` to bypass gamma transforms
    /// and achieve strictly linear byte-level color interpolation.
    public init(width: Int = 1280, height: Int = 720) {
        self.ciContext = CIContext(options: [
            CIContextOption.workingColorSpace: NSNull(),
            CIContextOption.useSoftwareRenderer: false
        ])
        
        guard let dissolveFilter = CIFilter(name: "CIDissolveTransition") else {
            fatalError("Core Image filter 'CIDissolveTransition' is unavailable.")
        }
        self.filter = dissolveFilter
        self.poolWidth = width
        self.poolHeight = height
        self.pixelBufferPool = Self.createPixelBufferPool(width: width, height: height)
    }
    
    private static func createPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 5
        ]
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess else { return nil }
        return pool
    }
    
    private func ensurePoolMatches(width: Int, height: Int) {
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            poolWidth = width
            poolHeight = height
            pixelBufferPool = Self.createPixelBufferPool(width: width, height: height)
        }
    }
    
    // MARK: - Blending API
    
    /// Blends between two `CVPixelBuffer` sources and renders the result into `destination`.
    /// Handles mismatched input dimensions by normalizing geometries via Core Image affine scaling.
    ///
    /// - Parameters:
    ///   - source: Origin frame (visible at progress = 0.0).
    ///   - target: Destination frame (visible at progress = 1.0).
    ///   - progress: Normalized transition time in range [0.0, 1.0]. Values outside are clamped.
    ///   - destination: Target `CVPixelBuffer` where the blended output is rendered.
    ///   - curve: The transition curve to apply (default: `.linear`).
    /// - Returns: `true` on successful render, `false` on failure.
    @discardableResult
    public func renderCrossfade(
        from source: CVPixelBuffer,
        to target: CVPixelBuffer,
        progress: Float,
        into destination: CVPixelBuffer,
        curve: TransitionCurve = .linear
    ) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let dstWidth = CVPixelBufferGetWidth(destination)
        let dstHeight = CVPixelBufferGetHeight(destination)
        let srcWidth = CVPixelBufferGetWidth(source)
        let srcHeight = CVPixelBufferGetHeight(source)
        let tgtWidth = CVPixelBufferGetWidth(target)
        let tgtHeight = CVPixelBufferGetHeight(target)
        
        guard dstWidth > 0, dstHeight > 0,
              srcWidth > 0, srcHeight > 0,
              tgtWidth > 0, tgtHeight > 0 else {
            return false
        }
        
        let dstFormat = CVPixelBufferGetPixelFormatType(destination)
        let srcFormat = CVPixelBufferGetPixelFormatType(source)
        let tgtFormat = CVPixelBufferGetPixelFormatType(target)
        
        let mappedProgress = curve.mapProgress(progress)
        
        // Fast paths for boundary conditions when dimensions and formats match destination
        if mappedProgress <= 0.0 {
            if srcWidth == dstWidth && srcHeight == dstHeight && srcFormat == dstFormat {
                VideoRecordingBuffer.copyPixelBuffer(from: source, to: destination)
                return true
            }
        }
        if mappedProgress >= 1.0 {
            if tgtWidth == dstWidth && tgtHeight == dstHeight && tgtFormat == dstFormat {
                VideoRecordingBuffer.copyPixelBuffer(from: target, to: destination)
                return true
            }
        }
        
        // Prepare source CIImage with geometry normalization if dimensions differ
        var sourceCI = CIImage(cvPixelBuffer: source)
        if srcWidth != dstWidth || srcHeight != dstHeight {
            let scaleX = CGFloat(dstWidth) / CGFloat(srcWidth)
            let scaleY = CGFloat(dstHeight) / CGFloat(srcHeight)
            sourceCI = sourceCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        
        // Prepare target CIImage with geometry normalization if dimensions differ
        var targetCI = CIImage(cvPixelBuffer: target)
        if tgtWidth != dstWidth || tgtHeight != dstHeight {
            let scaleX = CGFloat(dstWidth) / CGFloat(tgtWidth)
            let scaleY = CGFloat(dstHeight) / CGFloat(tgtHeight)
            targetCI = targetCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        
        // Boundary rendering via Core Image when dimensions differed from destination
        if mappedProgress <= 0.0 {
            ciContext.render(sourceCI, to: destination)
            return true
        }
        if mappedProgress >= 1.0 {
            ciContext.render(targetCI, to: destination)
            return true
        }
        
        // Release retained pixel buffer references from filter upon exit
        defer {
            filter.setValue(nil, forKey: kCIInputImageKey)
            filter.setValue(nil, forKey: kCIInputTargetImageKey)
        }
        
        filter.setValue(sourceCI, forKey: kCIInputImageKey)
        filter.setValue(targetCI, forKey: kCIInputTargetImageKey)
        filter.setValue(mappedProgress, forKey: kCIInputTimeKey)
        
        guard let outputCI = filter.outputImage else {
            return false
        }
        
        ciContext.render(outputCI, to: destination)
        return true
    }
    
    /// Convenience blending function returning a newly allocated or pooled output `CVPixelBuffer`.
    ///
    /// - Parameters:
    ///   - source: Origin frame (visible at progress = 0.0).
    ///   - target: Destination frame (visible at progress = 1.0).
    ///   - progress: Normalized transition time in range [0.0, 1.0].
    ///   - curve: The transition curve to apply (default: `.linear`).
    /// - Returns: A blended `CVPixelBuffer`, or `nil` on failure.
    public func crossfade(
        from source: CVPixelBuffer,
        to target: CVPixelBuffer,
        progress: Float,
        curve: TransitionCurve = .linear
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        
        guard width > 0, height > 0,
              CVPixelBufferGetWidth(target) > 0,
              CVPixelBufferGetHeight(target) > 0 else {
            return nil
        }
        
        os_unfair_lock_lock(&lock)
        ensurePoolMatches(width: width, height: height)
        var destinationBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
        }
        os_unfair_lock_unlock(&lock)
        
        if destinationBuffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &destinationBuffer
            )
        }
        
        guard let destination = destinationBuffer else { return nil }
        
        guard renderCrossfade(from: source, to: target, progress: progress, into: destination, curve: curve) else {
            return nil
        }
        return destination
    }
}

import Foundation
import CoreVideo
import CoreMedia

// Enable cross-concurrency transfer of CoreVideo buffers under Swift 6
extension CVBuffer: @retroactive @unchecked Sendable {}

/// Strongly-typed, concurrency-safe wrapper around a video frame buffer and presentation metadata.
public struct VideoFrame: Sendable {
    /// The underlying CoreVideo pixel buffer (e.g. 32BGRA or 420v).
    public let pixelBuffer: CVPixelBuffer
    
    /// Presentation timestamp of the frame.
    public let timestamp: CMTime
    
    /// Monotonically increasing sequential frame index.
    public let frameIndex: UInt64
    
    public init(pixelBuffer: CVPixelBuffer, timestamp: CMTime, frameIndex: UInt64 = 0) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.frameIndex = frameIndex
    }
    
    /// Width of the frame in pixels.
    public var width: Int {
        CVPixelBufferGetWidth(pixelBuffer)
    }
    
    /// Height of the frame in pixels.
    public var height: Int {
        CVPixelBufferGetHeight(pixelBuffer)
    }
    
    /// FourCC pixel format code of the buffer.
    public var pixelFormat: OSType {
        CVPixelBufferGetPixelFormatType(pixelBuffer)
    }
}

/// Abstract contract for any video source feeding frames into the FakeMe video pipeline.
public protocol VideoFrameProvider: AnyObject, Sendable {
    /// Indicates whether the provider is currently capturing or generating frames.
    var isRunning: Bool { get }
    
    /// Target frame rate in frames per second (e.g. 30.0).
    var frameRate: Double { get }
    
    /// Resolution dimensions of generated frames (e.g. 1280x720).
    var dimensions: CMVideoDimensions { get }
    
    /// Starts capturing or generating frames.
    func start() async throws
    
    /// Stops capturing or generating frames.
    func stop() async
    
    /// Closure invoked when a new frame is produced.
    /// Thread safety: The provider invokes this closure on its dedicated serial queue.
    var onFrame: (@Sendable (VideoFrame) -> Void)? { get set }
    
    /// Asynchronous stream yielding frames as they become available.
    var frameStream: AsyncStream<VideoFrame> { get }
}

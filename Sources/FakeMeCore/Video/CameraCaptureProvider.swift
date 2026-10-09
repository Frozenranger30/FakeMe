import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import OSLog
import os

private let logger = Logger(subsystem: "com.fakeme.core", category: "CameraCaptureProvider")

/// Errors that can occur during camera capture initialization or execution.
public enum CameraCaptureError: Error, LocalizedError, Sendable {
    case permissionDenied
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput
    case sessionConfigurationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera access was denied by the user."
        case .noCameraAvailable:
            return "No suitable video capture device was found."
        case .cannotAddInput:
            return "Could not add AVCaptureDeviceInput to AVCaptureSession."
        case .cannotAddOutput:
            return "Could not add AVCaptureVideoDataOutput to AVCaptureSession."
        case .sessionConfigurationFailed(let reason):
            return "Failed to configure AVCaptureSession: \(reason)"
        }
    }
}

/// Physical camera capture provider using AVFoundation AVCaptureSession.
public final class CameraCaptureProvider: NSObject, VideoFrameProvider, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    
    public let frameRate: Double
    public let dimensions: CMVideoDimensions
    
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.fakeme.camera.capture", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.fakeme.camera.session", qos: .userInitiated)
    private var lock = os_unfair_lock()
    
    private var _isRunning: Bool = false
    private var frameCounter: UInt64 = 0
    private var streamContinuation: AsyncStream<VideoFrame>.Continuation?
    
    private var _onFrame: (@Sendable (VideoFrame) -> Void)?
    public var onFrame: (@Sendable (VideoFrame) -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onFrame
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onFrame = newValue
        }
    }
    
    public var isRunning: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _isRunning
    }
    
    public var frameStream: AsyncStream<VideoFrame> {
        AsyncStream { continuation in
            os_unfair_lock_lock(&lock)
            self.streamContinuation = continuation
            os_unfair_lock_unlock(&lock)
            
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                os_unfair_lock_lock(&self.lock)
                self.streamContinuation = nil
                os_unfair_lock_unlock(&self.lock)
            }
        }
    }
    
    public init(
        preferredDeviceID: String? = nil,
        frameRate: Double = 30.0,
        dimensions: CMVideoDimensions = CMVideoDimensions(width: 1280, height: 720)
    ) {
        self.frameRate = frameRate
        self.dimensions = dimensions
        super.init()
    }
    
    /// Configures the AVCaptureSession with input camera device and video output.
    static func isVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        let text = (device.localizedName + " " + device.modelID + " " + device.manufacturer).lowercased()
        return ["virtual", "obs", "fakeme", "camtwist", "snap camera", "mmhmm", "ndi"]
            .contains { text.contains($0) }
    }

    public func configureSession(deviceID: String? = nil) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        session.sessionPreset = .hd1280x720
        
        // Remove existing inputs/outputs
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        
        // Discover camera device
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        // Never capture from a virtual camera (e.g. "OBS Virtual Camera") — it carries
        // FakeMe's own output and would create a feedback loop.
        let realCameras = discovery.devices.filter { !Self.isVirtualCamera($0) }
        let preferred = realCameras.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? realCameras.first

        let device: AVCaptureDevice?
        if let targetID = deviceID {
            device = realCameras.first(where: { $0.uniqueID == targetID }) ?? preferred
        } else {
            device = preferred
        }
        
        guard let camera = device else {
            logger.error("No camera device found on system")
            throw CameraCaptureError.noCameraAvailable
        }
        
        // Add input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw CameraCaptureError.cannotAddInput
            }
            session.addInput(input)
        } catch {
            throw CameraCaptureError.cannotAddInput
        }
        
        // Add output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        
        logger.info("Configured AVCaptureSession successfully with device: \(camera.localizedName)")
    }
    
    public func start() async throws {
        // Check authorization
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .denied || authStatus == .restricted {
            throw CameraCaptureError.permissionDenied
        }
        
        if authStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw CameraCaptureError.permissionDenied
            }
        }
        
        try configureSession()
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.session.startRunning()
                os_unfair_lock_lock(&self.lock)
                self._isRunning = self.session.isRunning
                self.frameCounter = 0
                os_unfair_lock_unlock(&self.lock)
                logger.info("AVCaptureSession started running: \(self._isRunning)")
                continuation.resume()
            }
        }
    }
    
    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                os_unfair_lock_lock(&self.lock)
                self._isRunning = false
                self.streamContinuation?.finish()
                self.streamContinuation = nil
                os_unfair_lock_unlock(&self.lock)
                logger.info("AVCaptureSession stopped running")
                continuation.resume()
            }
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        os_unfair_lock_lock(&lock)
        frameCounter &+= 1
        let currentFrameIndex = frameCounter
        let callback = _onFrame
        let continuation = streamContinuation
        os_unfair_lock_unlock(&lock)
        
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            frameIndex: currentFrameIndex
        )
        
        callback?(frame)
        continuation?.yield(frame)
    }
}

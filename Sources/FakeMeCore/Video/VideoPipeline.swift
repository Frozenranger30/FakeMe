import Foundation
import CoreVideo
import CoreMedia
import os

/// The operational mode of the VideoPipeline compositor.
public enum VideoPipelineMode: Equatable, Sendable {
    case live
    case recording(elapsedFrames: Int, totalFrames: Int)
    case transitioningToPlayback(step: Int, totalSteps: Int, progress: Double)
    case playingBack(currentFrame: Int, totalFrames: Int)
    case postPlaybackHold(elapsedFrames: Int, totalFrames: Int, remainingSeconds: Double)
    case transitioningToLive(step: Int, totalSteps: Int, progress: Double)
}

/// Thread-safe Master Frame Pump and Compositor for the FakeMe application.
///
/// Driven synchronously by incoming frames from a `VideoFrameProvider`.
/// Dispatches composited frames to local UI preview and system virtual camera extension.
public final class VideoPipeline: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var deliveryLock = os_unfair_lock()
    
    // MARK: - Dependencies
    private var frameProvider: (any VideoFrameProvider)?
    private let recordingBuffer: VideoRecordingBuffer
    private let crossfadeEngine: CrossfadeEngine
    
    // MARK: - Backing Storage (Thread-Safe Synchronization via `lock`)
    private var _targetFPS: Double = 30.0
    private var _defaultRecordingDuration: TimeInterval = 5.0
    private var _defaultTransitionDuration: TimeInterval = 0.5
    private var _defaultPostPlaybackHoldDuration: TimeInterval = 3.0
    private var _currentMode: VideoPipelineMode = .live
    
    private var _onFrameRendered: (@Sendable (CVPixelBuffer) -> Void)?
    private var _onVirtualCameraFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    private var _onModeChanged: (@Sendable (VideoPipelineMode) -> Void)?
    private var _onRecordingComplete: (@Sendable () -> Void)?
    private var _onTransitionComplete: (@Sendable () -> Void)?
    private var _onPlaybackComplete: (@Sendable () -> Void)?
    
    // MARK: - Runtime Frame State (Protected by `lock`)
    private var lastRenderedFrame: CVPixelBuffer?
    private var holdFrame: CVPixelBuffer?
    private var playbackIndex: Int = 0
    private var playbackSubframe: Int = 0   // counts render frames per stored frame
    private var transitionStep: Int = 0
    private var transitionTotalSteps: Int = 0
    private var holdStep: Int = 0
    private var holdTotalSteps: Int = 0
    private var recordStep: Int = 0
    private var recordTotalSteps: Int = 0
    private var recordFrameSkip: Int = 1    // store every Nth frame to save memory
    private var recordFrameCounter: Int = 0
    private var lastPublishedPTS: CMTime = .invalid
    
    // MARK: - Synchronized Public Configuration Properties
    
    public var targetFPS: Double {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _targetFPS
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _targetFPS = max(1.0, newValue)
        }
    }
    
    public var defaultRecordingDuration: TimeInterval {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _defaultRecordingDuration
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _defaultRecordingDuration = max(0.1, newValue)
        }
    }
    
    public var defaultTransitionDuration: TimeInterval {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _defaultTransitionDuration
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _defaultTransitionDuration = max(0.0, newValue)
        }
    }
    
    public var defaultPostPlaybackHoldDuration: TimeInterval {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _defaultPostPlaybackHoldDuration
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _defaultPostPlaybackHoldDuration = max(0.0, newValue)
        }
    }
    
    public var hasRecordedFrames: Bool { !recordingBuffer.isEmpty }

    public var currentMode: VideoPipelineMode {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _currentMode
        }
    }
    
    // MARK: - Synchronized Public Callbacks
    
    public var onFrameRendered: (@Sendable (CVPixelBuffer) -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onFrameRendered
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onFrameRendered = newValue
        }
    }
    
    public var onVirtualCameraFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onVirtualCameraFrame
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onVirtualCameraFrame = newValue
        }
    }
    
    public var onModeChanged: (@Sendable (VideoPipelineMode) -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onModeChanged
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onModeChanged = newValue
        }
    }
    
    public var onRecordingComplete: (@Sendable () -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onRecordingComplete
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onRecordingComplete = newValue
        }
    }
    
    public var onTransitionComplete: (@Sendable () -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onTransitionComplete
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onTransitionComplete = newValue
        }
    }
    
    public var onPlaybackComplete: (@Sendable () -> Void)? {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _onPlaybackComplete
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _onPlaybackComplete = newValue
        }
    }
    
    // MARK: - Initializer
    public init(
        frameProvider: (any VideoFrameProvider)? = nil,
        recordingBuffer: VideoRecordingBuffer = VideoRecordingBuffer(),
        crossfadeEngine: CrossfadeEngine = CrossfadeEngine(),
        targetFPS: Double = 30.0
    ) {
        self.recordingBuffer = recordingBuffer
        self.crossfadeEngine = crossfadeEngine
        self._targetFPS = max(1.0, targetFPS)
        if let provider = frameProvider {
            attachProvider(provider)
        }
    }
    
    // MARK: - Provider Lifecycle
    
    /// Attaches and subscribes to a video frame provider.
    public func attachProvider(_ provider: any VideoFrameProvider) {
        os_unfair_lock_lock(&lock)
        let oldProvider = self.frameProvider
        self.frameProvider = provider
        os_unfair_lock_unlock(&lock)
        
        oldProvider?.onFrame = nil
        provider.onFrame = { [weak self] frame in
            self?.processIncomingFrame(frame.pixelBuffer, timestamp: frame.timestamp)
        }
    }
    
    private func getProvider() -> (any VideoFrameProvider)? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return frameProvider
    }
    
    /// Starts the underlying frame provider.
    public func start() async throws {
        guard let provider = getProvider() else { return }
        try await provider.start()
    }
    
    /// Stops the underlying frame provider.
    public func stop() async {
        guard let provider = getProvider() else { return }
        await provider.stop()
    }
    
    // MARK: - External Control Interface
    
    /// Initiates video recording for the specified duration.
    public func startRecording(duration: TimeInterval? = nil) {
        os_unfair_lock_lock(&lock)
        let dur = duration ?? _defaultRecordingDuration
        // For long recordings, store fewer frames to avoid memory pressure:
        // ≤15s → every frame (30fps stored), ≤30s → every 2nd frame (15fps), >30s → every 3rd (10fps)
        let skip: Int
        if dur <= 15 { skip = 1 }
        else if dur <= 30 { skip = 2 }
        else { skip = 3 }
        recordFrameSkip = skip
        recordFrameCounter = 0
        let storedFPS = _targetFPS / Double(skip)
        let totalFrames = max(1, Int(round(dur * storedFPS)))
        recordingBuffer.clear()
        recordingBuffer.setMaxCapacity(totalFrames)
        recordStep = 0
        recordTotalSteps = max(1, Int(round(dur * _targetFPS)))  // wall-clock frames
        _currentMode = .recording(elapsedFrames: 0, totalFrames: recordTotalSteps)
        let mode = _currentMode
        let cbMode = _onModeChanged
        os_unfair_lock_unlock(&lock)

        DispatchQueue.main.async { cbMode?(mode) }
    }
    
    /// Stops an active recording early and preserves recorded frames.
    public func stopRecording() {
        os_unfair_lock_lock(&lock)
        guard case .recording = _currentMode else {
            os_unfair_lock_unlock(&lock)
            return
        }
        _currentMode = .live
        let mode = _currentMode
        let cbMode = _onModeChanged
        let cbRec = _onRecordingComplete
        os_unfair_lock_unlock(&lock)
        
        DispatchQueue.main.async {
            cbMode?(mode)
            cbRec?()
        }
    }
    
    /// Initiates playback of the recorded buffer with an initial crossfade transition.
    public func startPlayback(transitionDuration: TimeInterval? = nil) {
        os_unfair_lock_lock(&lock)
        guard !recordingBuffer.isEmpty else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let transDur = transitionDuration ?? _defaultTransitionDuration
        let totalSteps = max(1, Int(round(transDur * _targetFPS)))
        transitionStep = 0
        transitionTotalSteps = totalSteps
        playbackSubframe = 0
        _currentMode = .transitioningToPlayback(step: 0, totalSteps: totalSteps, progress: 0.0)
        let mode = _currentMode
        let cbMode = _onModeChanged
        os_unfair_lock_unlock(&lock)
        
        DispatchQueue.main.async { cbMode?(mode) }
    }
    
    /// Cancels playback or hold and initiates a smooth crossfade return to the live camera feed.
    public func cancelToLive(transitionDuration: TimeInterval? = nil) {
        os_unfair_lock_lock(&lock)
        let transDur = transitionDuration ?? _defaultTransitionDuration
        let totalSteps = max(1, Int(round(transDur * _targetFPS)))
        
        switch _currentMode {
        case .live:
            os_unfair_lock_unlock(&lock)
            return
            
        case .recording:
            _currentMode = .live
            let mode = _currentMode
            let cbMode = _onModeChanged
            let cbRec = _onRecordingComplete
            os_unfair_lock_unlock(&lock)
            DispatchQueue.main.async {
                cbMode?(mode)
                cbRec?()
            }
            return
            
        case .playingBack(let current, _):
            holdFrame = recordingBuffer.frame(at: current) ?? lastRenderedFrame
            
        case .postPlaybackHold:
            // Maintain existing holdFrame
            break
            
        case .transitioningToPlayback:
            holdFrame = lastRenderedFrame
            
        case .transitioningToLive:
            os_unfair_lock_unlock(&lock)
            return
        }
        
        transitionStep = 0
        transitionTotalSteps = totalSteps
        _currentMode = .transitioningToLive(step: 0, totalSteps: totalSteps, progress: 0.0)
        let mode = _currentMode
        let cbMode = _onModeChanged
        os_unfair_lock_unlock(&lock)
        
        DispatchQueue.main.async { cbMode?(mode) }
    }
    
    /// Resets the pipeline state to idle live and clears buffers.
    public func reset() {
        os_unfair_lock_lock(&lock)
        _currentMode = .live
        recordingBuffer.clear()
        holdFrame = nil
        lastRenderedFrame = nil
        recordStep = 0
        transitionStep = 0
        playbackIndex = 0
        holdStep = 0
        lastPublishedPTS = .invalid
        let mode = _currentMode
        let cbMode = _onModeChanged
        os_unfair_lock_unlock(&lock)
        
        DispatchQueue.main.async { cbMode?(mode) }
    }
    
    // MARK: - Synchronous Frame Pump (Headless Testing & Direct Ingestion)
    
    /// Synchronously pumps a frame through the compositor.
    /// Used by headless unit tests for deterministic, instantaneous execution.
    public func pumpFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        processIncomingFrame(pixelBuffer, timestamp: timestamp)
    }
    
    // MARK: - Frame Processing Engine
    
    private func processIncomingFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        os_unfair_lock_lock(&lock)
        
        var outputFrame: CVPixelBuffer = pixelBuffer
        var nextMode: VideoPipelineMode?
        var notifyRecordingComplete = false
        var notifyTransitionComplete = false
        var notifyPlaybackComplete = false
        
        switch _currentMode {
        case .live:
            outputFrame = pixelBuffer
            
        case .recording(let current, let total):
            // Only store every Nth frame to save memory on long recordings
            if recordFrameCounter % recordFrameSkip == 0 {
                _ = recordingBuffer.append(pixelBuffer)
            }
            recordFrameCounter += 1
            outputFrame = pixelBuffer
            recordStep = current + 1
            if recordStep >= total {
                nextMode = .live
                notifyRecordingComplete = true
            } else {
                nextMode = .recording(elapsedFrames: recordStep, totalFrames: total)
            }
            
        case .transitioningToPlayback(let step, let totalSteps, _):
            let targetFrame = recordingBuffer.frame(at: 0) ?? pixelBuffer
            let progress = Float(step) / Float(max(1, totalSteps - 1))
            outputFrame = crossfadeEngine.crossfade(from: pixelBuffer, to: targetFrame, progress: progress) ?? pixelBuffer
            let nextStep = step + 1
            if nextStep >= totalSteps {
                playbackIndex = 0
                nextMode = .playingBack(currentFrame: 0, totalFrames: recordingBuffer.count)
                notifyTransitionComplete = true
            } else {
                let nextProgress = Double(nextStep) / Double(max(1, totalSteps - 1))
                nextMode = .transitioningToPlayback(step: nextStep, totalSteps: totalSteps, progress: nextProgress)
            }
            
        case .playingBack(let current, let total):
            if let recordedFrame = recordingBuffer.frame(at: current) {
                outputFrame = recordedFrame
                holdFrame = recordedFrame
                // Each stored frame plays for `recordFrameSkip` render frames
                playbackSubframe += 1
                let advance = playbackSubframe >= recordFrameSkip
                if advance { playbackSubframe = 0 }
                let nextFrameIndex = advance ? current + 1 : current
                if nextFrameIndex >= total {
                    holdStep = 0
                    holdTotalSteps = max(1, Int(round(_defaultPostPlaybackHoldDuration * _targetFPS)))
                    nextMode = .postPlaybackHold(
                        elapsedFrames: 0,
                        totalFrames: holdTotalSteps,
                        remainingSeconds: _defaultPostPlaybackHoldDuration
                    )
                    notifyPlaybackComplete = true
                } else {
                    nextMode = .playingBack(currentFrame: nextFrameIndex, totalFrames: total)
                }
            } else {
                outputFrame = pixelBuffer
                nextMode = .live
            }
            
        case .postPlaybackHold(let elapsed, let total, _):
            outputFrame = holdFrame ?? pixelBuffer
            let nextElapsed = elapsed + 1
            if nextElapsed >= total {
                transitionStep = 0
                transitionTotalSteps = max(1, Int(round(_defaultTransitionDuration * _targetFPS)))
                nextMode = .transitioningToLive(step: 0, totalSteps: transitionTotalSteps, progress: 0.0)
            } else {
                let remaining = max(0.0, Double(total - nextElapsed) / _targetFPS)
                nextMode = .postPlaybackHold(
                    elapsedFrames: nextElapsed,
                    totalFrames: total,
                    remainingSeconds: remaining
                )
            }
            
        case .transitioningToLive(let step, let totalSteps, _):
            let sourceFrame = holdFrame ?? pixelBuffer
            let progress = Float(step) / Float(max(1, totalSteps - 1))
            outputFrame = crossfadeEngine.crossfade(from: sourceFrame, to: pixelBuffer, progress: progress) ?? pixelBuffer
            let nextStep = step + 1
            if nextStep >= totalSteps {
                nextMode = .live
                holdFrame = nil
                notifyTransitionComplete = true
            } else {
                let nextProgress = Double(nextStep) / Double(max(1, totalSteps - 1))
                nextMode = .transitioningToLive(step: nextStep, totalSteps: totalSteps, progress: nextProgress)
            }
        }
        
        if let mode = nextMode {
            _currentMode = mode
        }
        lastRenderedFrame = outputFrame
        
        // Enforce strictly monotonic Presentation Timestamp (PTS)
        let outputPTS: CMTime
        if lastPublishedPTS.isValid && !lastPublishedPTS.isIndefinite {
            if timestamp.isValid && !timestamp.isIndefinite && timestamp > lastPublishedPTS {
                outputPTS = timestamp
            } else {
                let ts1 = timestamp.timescale > 0 ? timestamp.timescale : 30_000
                let ts2 = lastPublishedPTS.timescale > 0 ? lastPublishedPTS.timescale : 30_000
                let timescale = max(max(ts1, ts2), 30_000)
                let minDelta = CMTime(value: 1, timescale: timescale)
                outputPTS = lastPublishedPTS + minDelta
            }
        } else {
            if timestamp.isValid && !timestamp.isIndefinite {
                outputPTS = timestamp
            } else {
                outputPTS = CMTime(value: 0, timescale: 30_000)
            }
        }
        lastPublishedPTS = outputPTS
        
        // Take atomic snapshots of callbacks to safely invoke outside the mutex lock
        let virtualCamCb = _onVirtualCameraFrame
        let previewCb = _onFrameRendered
        let modeCb = _onModeChanged
        let recCompleteCb = _onRecordingComplete
        let transCompleteCb = _onTransitionComplete
        let playCompleteCb = _onPlaybackComplete
        let activeMode = _currentMode
        
        // Lock coupling: acquire deliveryLock before releasing lock to preserve strict emission order
        os_unfair_lock_lock(&deliveryLock)
        os_unfair_lock_unlock(&lock)
        
        // 1. CoreMediaIO Virtual Camera stream: direct synchronous invocation on capture queue
        virtualCamCb?(outputFrame, outputPTS)
        os_unfair_lock_unlock(&deliveryLock)
        
        // 2. UI Preview: dispatch asynchronously to main queue
        if let preview = previewCb {
            DispatchQueue.main.async {
                preview(outputFrame)
            }
        }
        
        // 3. State & lifecycle callbacks: dispatch to main queue
        if nextMode != nil, let modeChanged = modeCb {
            DispatchQueue.main.async {
                modeChanged(activeMode)
            }
        }
        if notifyRecordingComplete, let recDone = recCompleteCb {
            DispatchQueue.main.async {
                recDone()
            }
        }
        if notifyTransitionComplete, let transDone = transCompleteCb {
            DispatchQueue.main.async {
                transDone()
            }
        }
        if notifyPlaybackComplete, let playDone = playCompleteCb {
            DispatchQueue.main.async {
                playDone()
            }
        }
    }
}

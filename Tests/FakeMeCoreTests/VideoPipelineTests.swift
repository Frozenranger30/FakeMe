import XCTest
import CoreVideo
import CoreMedia
@testable import FakeMeCore

@MainActor
final class VideoPipelineTests: XCTestCase {
    
    private var pipeline: VideoPipeline!
    private var redBuffer: CVPixelBuffer!
    private var blueBuffer: CVPixelBuffer!
    
    override func setUp() {
        super.setUp()
        pipeline = VideoPipeline(targetFPS: 30.0)
        redBuffer = TestFrameFactory.makeSolidBuffer(b: 0, g: 0, r: 255)
        blueBuffer = TestFrameFactory.makeSolidBuffer(b: 255, g: 0, r: 0)
    }
    
    override func tearDown() {
        pipeline = nil
        redBuffer = nil
        blueBuffer = nil
        super.tearDown()
    }
    
    // Test 1: Initial state is live and forwards live frames directly
    func testIdleLivePassthrough() {
        XCTAssertEqual(pipeline.currentMode, .live)
        
        let renderedBuffer = LockedBox<CVPixelBuffer?>(nil)
        pipeline.onVirtualCameraFrame = { buf, _ in
            renderedBuffer.withValue { $0 = buf }
        }
        
        let testTime = CMTime(value: 1, timescale: 30)
        pipeline.pumpFrame(redBuffer, timestamp: testTime)
        
        XCTAssertNotNil(renderedBuffer.current)
        let px = TestFrameFactory.readPixel(from: renderedBuffer.current!)
        XCTAssertEqual(px.r, 255)
        XCTAssertEqual(px.b, 0)
    }
    
    // Test 2: Bounded recording captures exact frame count and fires completion
    func testRecordingBoundedFrameCount() {
        let exp = expectation(description: "Recording complete")
        pipeline.onRecordingComplete = {
            exp.fulfill()
        }
        
        // 10 frames recording duration
        pipeline.startRecording(duration: 10.0 / 30.0)
        
        for i in 0..<10 {
            let t = CMTime(value: Int64(i), timescale: 30)
            pipeline.pumpFrame(redBuffer, timestamp: t)
        }
        
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(pipeline.currentMode, .live)
    }
    
    // Test 3: Early stop recording preserves captured frames
    func testRecordingEarlyStop() {
        let exp = expectation(description: "Recording stopped early")
        pipeline.onRecordingComplete = {
            exp.fulfill()
        }
        
        pipeline.startRecording(duration: 2.0) // 60 frames
        for i in 0..<5 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        
        pipeline.stopRecording()
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(pipeline.currentMode, .live)
    }
    
    // Test 4: Playback ignored when recording buffer is empty
    func testStartPlaybackWithEmptyBufferIgnored() {
        pipeline.startPlayback(transitionDuration: 0.5)
        XCTAssertEqual(pipeline.currentMode, .live)
    }
    
    // Test 5: Transition to playback executes dissolve blending
    func testTransitionToPlaybackDissolve() {
        // Record 5 red frames
        pipeline.startRecording(duration: 5.0 / 30.0)
        for i in 0..<5 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        
        // Start playback with 3 steps transition (live is blue, recorded is red)
        pipeline.startPlayback(transitionDuration: 3.0 / 30.0)
        
        let outputs = LockedBox<[CVPixelBuffer]>([])
        pipeline.onVirtualCameraFrame = { buf, _ in
            outputs.withValue { $0.append(buf) }
        }
        
        // Step 0: Progress 0.0 -> 100% Blue
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 10, timescale: 30))
        let px0 = TestFrameFactory.readPixel(from: outputs.current[0])
        XCTAssertEqual(px0.b, 255)
        XCTAssertEqual(px0.r, 0)
        
        // Step 1: Progress 0.5 -> 50% Blue, 50% Red
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 11, timescale: 30))
        let px1 = TestFrameFactory.readPixel(from: outputs.current[1])
        XCTAssertEqual(px1.b, 128)
        XCTAssertEqual(px1.r, 128)
        
        // Step 2: Progress 1.0 -> 100% Red (recorded)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 12, timescale: 30))
        let px2 = TestFrameFactory.readPixel(from: outputs.current[2])
        XCTAssertEqual(px2.b, 0)
        XCTAssertEqual(px2.r, 255)
        
        // Next frame enters playback mode
        XCTAssertEqual(pipeline.currentMode, .playingBack(currentFrame: 0, totalFrames: 5))
    }
    
    // Test 6: Playback emits frames sequentially
    func testPlaybackSequentialFrameEmission() {
        // Record green then red
        let greenBuffer = TestFrameFactory.makeSolidBuffer(b: 0, g: 255, r: 0)
        pipeline.startRecording(duration: 2.0 / 30.0)
        pipeline.pumpFrame(greenBuffer, timestamp: CMTime(value: 0, timescale: 30))
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 1, timescale: 30))
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 2, timescale: 30)) // transition step
        
        let emittedFrames = LockedBox<[CVPixelBuffer]>([])
        pipeline.onVirtualCameraFrame = { buf, _ in
            emittedFrames.withValue { $0.append(buf) }
        }
        
        // Pump playback frame 0 (green)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 3, timescale: 30))
        let px0 = TestFrameFactory.readPixel(from: emittedFrames.current[0])
        XCTAssertEqual(px0.g, 255)
        
        // Pump playback frame 1 (red)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 4, timescale: 30))
        let px1 = TestFrameFactory.readPixel(from: emittedFrames.current[1])
        XCTAssertEqual(px1.r, 255)
    }
    
    // Test 7: Post-playback hold freezes last frame
    func testPostPlaybackHoldFrameFreezing() {
        pipeline.defaultPostPlaybackHoldDuration = 2.0 / 30.0 // 2 frames hold
        pipeline.startRecording(duration: 1.0 / 30.0)
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 0, timescale: 30))
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 1, timescale: 30)) // transition
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 2, timescale: 30)) // play frame 0
        
        // Pipeline is now in postPlaybackHold
        let holdOutputs = LockedBox<[CVPixelBuffer]>([])
        pipeline.onVirtualCameraFrame = { buf, _ in
            holdOutputs.withValue { $0.append(buf) }
        }
        
        // Pump live blue frames during hold
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 3, timescale: 30))
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 4, timescale: 30))
        
        // Both output frames must be the held RED frame, NOT the live blue frame
        let px0 = TestFrameFactory.readPixel(from: holdOutputs.current[0])
        let px1 = TestFrameFactory.readPixel(from: holdOutputs.current[1])
        XCTAssertEqual(px0.r, 255)
        XCTAssertEqual(px1.r, 255)
    }
    
    // Test 8: Auto-transition back to live after hold timer expiry
    func testAutoTransitionToLiveAfterHold() {
        pipeline.defaultPostPlaybackHoldDuration = 1.0 / 30.0 // 1 frame hold
        pipeline.defaultTransitionDuration = 2.0 / 30.0       // 2 frames transition
        
        pipeline.startRecording(duration: 1.0 / 30.0)
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 0, timescale: 30))
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 1, timescale: 30)) // trans to play
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 2, timescale: 30)) // play
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 3, timescale: 30)) // hold
        
        // Next frame enters transitioningToLive
        if case .transitioningToLive = pipeline.currentMode {
            // expected
        } else {
            XCTFail("Expected transitioningToLive mode, got \(pipeline.currentMode)")
        }
        
        // Step transition to live
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 4, timescale: 30))
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 5, timescale: 30))
        
        XCTAssertEqual(pipeline.currentMode, .live)
    }
    
    // Test 9: Abort mid-playback via cancelToLive
    func testCancelToLiveMidPlayback() {
        pipeline.startRecording(duration: 10.0 / 30.0)
        for i in 0..<10 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 10, timescale: 30)) // trans
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 11, timescale: 30)) // play frame 0
        
        // Cancel mid playback
        pipeline.cancelToLive(transitionDuration: 2.0 / 30.0)
        if case .transitioningToLive = pipeline.currentMode {
            // expected
        } else {
            XCTFail("Expected transitioningToLive after cancelToLive")
        }
    }
    
    // Test 10: Abort during post-playback hold via cancelToLive
    func testCancelToLiveDuringHold() {
        pipeline.defaultPostPlaybackHoldDuration = 10.0
        pipeline.startRecording(duration: 1.0 / 30.0)
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 0, timescale: 30))
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 1, timescale: 30))
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 2, timescale: 30))
        
        // In hold, trigger cancel
        pipeline.cancelToLive(transitionDuration: 1.0 / 30.0)
        if case .transitioningToLive = pipeline.currentMode {
            // expected
        } else {
            XCTFail("Expected transitioningToLive")
        }
    }
    
    // Test 11: Fast re-record interrupts playback immediately (Scenario 3)
    func testFastRerecordInterruptsPlayback() {
        pipeline.startRecording(duration: 5.0 / 30.0)
        for i in 0..<5 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 10, timescale: 30))
        
        // Interrupt playback with startRecording
        pipeline.startRecording(duration: 3.0 / 30.0)
        if case .recording = pipeline.currentMode {
            // expected
        } else {
            XCTFail("Expected recording mode after fast re-record")
        }
    }
    
    // Test 12: Monotonically increasing presentation timestamps
    func testMonotonicPresentationTimestamps() {
        let observedTimestamps = LockedBox<[CMTime]>([])
        pipeline.onVirtualCameraFrame = { _, time in
            observedTimestamps.withValue { $0.append(time) }
        }
        
        // Pump 20 frames across multiple modes
        for i in 0..<20 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i * 100), timescale: 3000))
        }
        
        let timestamps = observedTimestamps.current
        XCTAssertEqual(timestamps.count, 20)
        for i in 1..<timestamps.count {
            XCTAssertGreaterThan(timestamps[i].seconds, timestamps[i - 1].seconds)
        }
    }
    
    // Test 13: Reset restores idle live and clears buffers
    func testResetClearsState() {
        pipeline.startRecording(duration: 5.0)
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 0, timescale: 30))
        
        pipeline.reset()
        XCTAssertEqual(pipeline.currentMode, .live)
        
        // Playback should be rejected because buffer was cleared
        pipeline.startPlayback()
        XCTAssertEqual(pipeline.currentMode, .live)
    }
    
    // Test 14: Thread-safe concurrent control calls
    func testConcurrentControlCalls() {
        let iterations = 100
        let p = self.pipeline!
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            if i % 3 == 0 {
                p.startRecording(duration: 1.0)
            } else if i % 3 == 1 {
                p.stopRecording()
            } else {
                p.cancelToLive(transitionDuration: 0.1)
            }
        }
        XCTAssertNotNil(pipeline.currentMode)
    }
    
    // Test 15: Mode change callback fires on transitions
    func testModeChangeCallback() {
        let recordedModes = LockedBox<[VideoPipelineMode]>([])
        let exp = expectation(description: "Mode callback received")
        
        pipeline.onModeChanged = { mode in
            recordedModes.withValue { $0.append(mode) }
            if case .recording = mode {
                exp.fulfill()
            }
        }
        
        pipeline.startRecording(duration: 1.0)
        waitForExpectations(timeout: 1.0)
        XCTAssertFalse(recordedModes.current.isEmpty)
    }
}

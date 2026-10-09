import XCTest
import CoreVideo
import CoreMedia
@testable import FakeMeCore

final class AdversarialStressTests: XCTestCase {
    
    private var redBuffer: CVPixelBuffer!
    private var blueBuffer: CVPixelBuffer!
    private var greenBuffer: CVPixelBuffer!
    
    override func setUp() {
        super.setUp()
        redBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 0, r: 255)
        blueBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 255, g: 0, r: 0)
        greenBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 255, r: 0)
    }
    
    override func tearDown() {
        redBuffer = nil
        blueBuffer = nil
        greenBuffer = nil
        super.tearDown()
    }
    
    // MARK: - Challenge Dimension 1: Rapid Concurrent State Transitions
    
    /// Stress test VideoPipeline under high-frequency interleaved concurrent control calls
    /// and concurrent frame pumping.
    func testRapidConcurrentStateTransitionsStress() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        let frameCount = 300
        let isDone = LockedBox<Bool>(false)
        let modeHistory = LockedBox<[VideoPipelineMode]>([])
        let outputFrameCount = LockedBox<Int>(0)
        
        pipeline.onVirtualCameraFrame = { _, _ in
            outputFrameCount.withValue { $0 += 1 }
        }
        
        pipeline.onModeChanged = { mode in
            modeHistory.withValue { $0.append(mode) }
        }
        
        // Background thread: Pumping frames continuously
        let pumpQueue = DispatchQueue(label: "com.fakeme.stress.pump", qos: .userInteractive)
        let pumpGroup = DispatchGroup()
        pumpGroup.enter()
        
        let red = self.redBuffer!
        let blue = self.blueBuffer!
        pumpQueue.async {
            var idx: Int64 = 0
            while !isDone.current {
                let time = CMTime(value: idx * 1000, timescale: 30_000)
                let buf = (idx % 2 == 0) ? red : blue
                pipeline.pumpFrame(buf, timestamp: time)
                idx += 1
                if idx >= Int64(frameCount) {
                    break
                }
            }
            pumpGroup.leave()
        }
        
        // 4 Concurrent worker threads bombarding control methods
        DispatchQueue.concurrentPerform(iterations: 80) { i in
            switch i % 5 {
            case 0:
                pipeline.startRecording(duration: 0.05)
            case 1:
                pipeline.stopRecording()
            case 2:
                pipeline.startPlayback(transitionDuration: 0.05)
            case 3:
                pipeline.cancelToLive(transitionDuration: 0.05)
            case 4:
                pipeline.reset()
            default:
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        
        isDone.withValue { $0 = true }
        _ = pumpGroup.wait(timeout: .now() + 5.0)
        
        // Pipeline must not deadlock, must have processed frames, and must be in a valid mode
        XCTAssertGreaterThan(outputFrameCount.current, 0, "Frames must continue pumping during stress")
        XCTAssertNotNil(pipeline.currentMode, "Pipeline must remain in a valid state")
    }
    
    /// Tests rapid re-record interruption cycles (Scenario 3 stress)
    func testFastRerecordInterruptionCycleStress() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        
        for cycle in 0..<50 {
            // 1. Record 2 frames
            pipeline.startRecording(duration: 1.0)
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(cycle * 10 + 0), timescale: 30))
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(cycle * 10 + 1), timescale: 30))
            
            // 2. Playback
            pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
            pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: Int64(cycle * 10 + 2), timescale: 30))
            
            // 3. Immediately interrupt with new recording
            pipeline.startRecording(duration: 1.0)
            if case .recording = pipeline.currentMode {
                // Success
            } else {
                XCTFail("Cycle \(cycle): Pipeline failed to interrupt playback with new recording")
            }
        }
    }
    
    /// Tests zero and negative durations for transitions
    func testBoundaryZeroAndNegativeDurationTransitions() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        
        // Zero duration recording
        pipeline.startRecording(duration: 0.0)
        if case .recording(_, let total) = pipeline.currentMode {
            XCTAssertGreaterThanOrEqual(total, 1, "Total frames must clamp to at least 1")
        } else {
            XCTFail("Expected recording mode")
        }
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 0, timescale: 30))
        XCTAssertEqual(pipeline.currentMode, .live, "1-frame recording should complete after 1 pump")
        
        // Zero duration playback transition
        pipeline.startRecording(duration: 2.0 / 30.0)
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 1, timescale: 30))
        pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: 2, timescale: 30))
        
        pipeline.startPlayback(transitionDuration: 0.0)
        // Pump 1 frame
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 3, timescale: 30))
        // Should immediately reach playingBack
        if case .playingBack = pipeline.currentMode {
            // Valid
        } else {
            XCTFail("Expected playingBack mode after zero-duration transition pump, got \(pipeline.currentMode)")
        }
        
        // Zero duration cancelToLive
        pipeline.cancelToLive(transitionDuration: 0.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 4, timescale: 30))
        XCTAssertEqual(pipeline.currentMode, .live, "Zero duration cancel should return to live after 1 step")
    }
    
    // MARK: - Challenge Dimension 2: Buffer Overflow, Frame Eviction, and Memory Stability
    
    /// Stress test VideoRecordingBuffer with massive ingestion exceeding capacity (100x maxCapacity)
    func testRecordingBufferMassiveOverflow() {
        let maxCap = 20
        let buffer = VideoRecordingBuffer(maxCapacity: maxCap, width: 64, height: 64)
        let totalToIngest = 2000
        
        var acceptedCount = 0
        var rejectedCount = 0
        
        for _ in 0..<totalToIngest {
            if buffer.append(redBuffer) {
                acceptedCount += 1
            } else {
                rejectedCount += 1
            }
        }
        
        XCTAssertEqual(acceptedCount, maxCap, "Buffer must only accept up to maxCapacity frames")
        XCTAssertEqual(rejectedCount, totalToIngest - maxCap, "Buffer must reject all frames exceeding capacity")
        XCTAssertEqual(buffer.count, maxCap)
        XCTAssertTrue(buffer.isFull)
        
        // Verify stored frames are intact and readable
        for i in 0..<maxCap {
            guard let f = buffer.frame(at: i) else {
                XCTFail("Frame \(i) missing from buffer")
                return
            }
            let px = TestFrameFactory.readPixel(from: f)
            XCTAssertEqual(px.r, 255)
            XCTAssertEqual(px.b, 0)
        }
    }
    
    /// Test dynamic capacity down-sizing during active concurrent access
    func testBufferDynamicDownsizingUnderLoad() {
        let buffer = VideoRecordingBuffer(maxCapacity: 100, width: 64, height: 64)
        for _ in 0..<100 {
            buffer.append(redBuffer)
        }
        XCTAssertEqual(buffer.count, 100)
        
        // Concurrently read while downsizing capacity
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            if i == 25 {
                buffer.setMaxCapacity(10)
            } else {
                _ = buffer.frame(at: i % 10)
            }
        }
        
        XCTAssertEqual(buffer.count, 10, "Buffer count must truncate to 10")
        XCTAssertTrue(buffer.isFull)
        XCTAssertNotNil(buffer.lastFrame)
    }
    
    /// Test initialization with non-positive capacities
    func testBufferZeroAndNegativeInitialCapacity() {
        let zeroBuffer = VideoRecordingBuffer(maxCapacity: 0)
        XCTAssertEqual(zeroBuffer.maxCapacity, 0)
        let appendedZero = zeroBuffer.append(redBuffer)
        XCTAssertFalse(appendedZero, "Cannot append to zero capacity buffer")
        XCTAssertEqual(zeroBuffer.count, 0)
        
        let negBuffer = VideoRecordingBuffer(maxCapacity: -10)
        XCTAssertEqual(negBuffer.maxCapacity, -10)
        let appendedNeg = negBuffer.append(redBuffer)
        XCTAssertFalse(appendedNeg, "Cannot append to negative capacity buffer")
    }
    
    /// Test recording duration exceeding default buffer capacity (15s = 450 frames vs maxCapacity 300)
    func testExtendedRecordingDurationCapacityMismatch() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        // Request 15 seconds recording (450 frames @ 30fps)
        pipeline.startRecording(duration: 15.0)
        for i in 0..<450 {
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        XCTAssertEqual(pipeline.currentMode, .live)
        
        // Start playback with 1 frame transition
        pipeline.startPlayback(transitionDuration: 1.0 / 30.0)
        pipeline.pumpFrame(blueBuffer, timestamp: CMTime(value: 500, timescale: 30))
        
        // Check mode: mode reports totalFrames
        if case .playingBack(_, let total) = pipeline.currentMode {
            print("Recorded frames available for playback: \(total) (expected 450)")
            XCTAssertEqual(total, 450, "Expected 450 recorded frames for 15s recording, but VideoRecordingBuffer capped at default 300!")
        } else {
            XCTFail("Expected playingBack mode, got \(pipeline.currentMode)")
        }
    }
    
    /// Adversarial test: Dimension mismatch in CrossfadeEngine
    func testCrossfadeEngineDimensionMismatchRobustness() {
        let smallBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 0, r: 255)
        let largeBuffer = TestFrameFactory.makeSolidBuffer(width: 128, height: 128, b: 255, g: 0, r: 0)
        let engine = CrossfadeEngine(width: 64, height: 64)
        
        // Progress 0.0: Small to Large -> Result should match small buffer dimensions
        let out0 = engine.crossfade(from: smallBuffer, to: largeBuffer, progress: 0.0)
        XCTAssertNotNil(out0)
        XCTAssertEqual(CVPixelBufferGetWidth(out0!), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(out0!), 64)
        
        // Progress 0.5: Midpoint blend
        let outHalf = engine.crossfade(from: smallBuffer, to: largeBuffer, progress: 0.5)
        XCTAssertNotNil(outHalf)
        
        // Progress 1.0: Boundary condition rendering target into destination
        // Destination has dimensions of source (64x64), but target is 128x128.
        // Check if copyPixelBuffer handles this without memory corruption!
        let out1 = engine.crossfade(from: smallBuffer, to: largeBuffer, progress: 1.0)
        XCTAssertNotNil(out1)
    }
    
    // MARK: - Challenge Dimension 3: Monotonicity of Timestamps and Clock Jitter
    
    /// Verify output timestamps under asynchronous frame pumping and clock jitter
    func testTimestampMonotonicityUnderClockJitter() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        let outputTimestamps = LockedBox<[CMTime]>([])
        
        pipeline.onVirtualCameraFrame = { _, time in
            outputTimestamps.withValue { $0.append(time) }
        }
        
        // Stream of incoming timestamps with intentional clock jitter and non-monotonicity:
        // 0ms, 33ms, 30ms (backwards jitter!), 33ms (duplicate!), 66ms, 100ms
        let jitteryTimes: [Double] = [0.000, 0.033, 0.030, 0.033, 0.066, 0.100]
        
        for t in jitteryTimes {
            let cmTime = CMTime(seconds: t, preferredTimescale: 30_000)
            pipeline.pumpFrame(redBuffer, timestamp: cmTime)
        }
        
        let received = outputTimestamps.current
        XCTAssertEqual(received.count, jitteryTimes.count)
        
        var nonMonotonicCount = 0
        for i in 1..<received.count {
            if received[i].seconds <= received[i - 1].seconds {
                nonMonotonicCount += 1
            }
        }
        
        // Record empirical observation: Does VideoPipeline sanitize timestamps or pass them raw?
        // Downstream CoreMediaIO virtual camera expects strictly monotonic PTS (dt > 0).
        // If nonMonotonicCount > 0, VideoPipeline is passthrough and does not filter PTS inversion.
        print("Adversarial finding: Clock jitter produced \(nonMonotonicCount) non-monotonic output timestamps out of \(received.count - 1) transitions.")
    }
    
    /// Stress test concurrent frame pumping timestamp ordering
    func testConcurrentPumpingTimestampOrdering() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        let emittedTimestamps = LockedBox<[CMTime]>([])
        
        pipeline.onVirtualCameraFrame = { _, time in
            emittedTimestamps.withValue { $0.append(time) }
        }
        
        let iterations = 100
        let red = self.redBuffer!
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let t = CMTime(value: Int64(i * 100), timescale: 3000)
            pipeline.pumpFrame(red, timestamp: t)
        }
        
        let count = emittedTimestamps.current.count
        XCTAssertEqual(count, iterations, "All pumped frames must be delivered")
    }
    
    // MARK: - Challenge Dimension 4: Concurrency & State Machine Thread Safety
    
    /// Concurrent reads of currentMode during active mode mutations
    func testConcurrentCurrentModeInspection() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        let isDone = LockedBox<Bool>(false)
        
        // Reader thread: rapid inspection of currentMode
        let readQueue = DispatchQueue(label: "com.fakeme.stress.reader", qos: .userInteractive, attributes: .concurrent)
        let group = DispatchGroup()
        
        for _ in 0..<4 {
            group.enter()
            readQueue.async {
                while !isDone.current {
                    _ = pipeline.currentMode
                }
                group.leave()
            }
        }
        
        // Writer thread: rapidly toggling states and pumping frames
        for i in 0..<100 {
            if i % 3 == 0 {
                pipeline.startRecording(duration: 0.1)
            } else if i % 3 == 1 {
                pipeline.cancelToLive(transitionDuration: 0.1)
            } else {
                pipeline.reset()
            }
            pipeline.pumpFrame(redBuffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }
        
        isDone.withValue { $0 = true }
        _ = group.wait(timeout: .now() + 5.0)
    }
    
    /// Concurrent mutation of callbacks while pumping frames
    func testCallbackMutationConcurrency() {
        let pipeline = VideoPipeline(targetFPS: 30.0)
        let red = self.redBuffer!
        
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            if i % 2 == 0 {
                pipeline.onVirtualCameraFrame = { _, _ in }
                pipeline.onFrameRendered = { _ in }
            } else {
                pipeline.pumpFrame(red, timestamp: CMTime(value: Int64(i), timescale: 30))
            }
        }
    }
    
    /// SyntheticFrameProvider rapid start/stop lifecycle stress
    func testSyntheticFrameProviderRapidLifecycleStress() async {
        let provider = SyntheticFrameProvider(frameRate: 30.0, width: 64, height: 64)
        
        for _ in 0..<10 {
            do {
                try await provider.start()
                XCTAssertTrue(provider.isRunning)
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await provider.stop()
                XCTAssertFalse(provider.isRunning)
            } catch {
                XCTFail("Unexpected error in synthetic frame provider lifecycle: \(error)")
            }
        }
    }
}

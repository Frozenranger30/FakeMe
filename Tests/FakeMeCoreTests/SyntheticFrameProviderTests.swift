import XCTest
import CoreVideo
import CoreMedia
@testable import FakeMeCore

final class SyntheticFrameProviderTests: XCTestCase {
    
    private var provider: SyntheticFrameProvider!
    
    override func setUp() {
        super.setUp()
        provider = SyntheticFrameProvider(frameRate: 30.0, width: 1280, height: 720)
    }
    
    override func tearDown() async throws {
        await provider.stop()
        provider = nil
    }
    
    // Test 1: Real-time 30Hz generation cadence
    func testFrameRateCadence() async throws {
        let frameCount = LockedBox(0)
        provider.onFrame = { _ in
            frameCount.withValue { $0 += 1 }
        }
        
        try await provider.start()
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        await provider.stop()
        
        // In 0.5s @ 30fps, expect ~15 frames (allow ±5 for timer scheduling)
        XCTAssertGreaterThanOrEqual(frameCount.current, 10)
        XCTAssertLessThanOrEqual(frameCount.current, 20)
    }
    
    // Test 2: Synchronous frame generation output geometry and format
    func testSynchronousFrameOutputProperties() {
        let frame = provider.generateNextFrame()
        XCTAssertEqual(frame.width, 1280)
        XCTAssertEqual(frame.height, 720)
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA)
    }
    
    // Test 3: Start and Stop lifecycle idempotency
    func testLifecycleIdempotency() async throws {
        XCTAssertFalse(provider.isRunning)
        try await provider.start()
        XCTAssertTrue(provider.isRunning)
        try await provider.start() // Second start is no-op
        XCTAssertTrue(provider.isRunning)
        
        await provider.stop()
        XCTAssertFalse(provider.isRunning)
        await provider.stop() // Second stop is no-op
        XCTAssertFalse(provider.isRunning)
    }
    
    // Test 4: Monotonically increasing sequential frame indices
    func testFrameIndexProgression() {
        let f0 = provider.generateNextFrame()
        let f1 = provider.generateNextFrame()
        let f2 = provider.generateNextFrame()
        
        XCTAssertEqual(f1.frameIndex, f0.frameIndex + 1)
        XCTAssertEqual(f2.frameIndex, f1.frameIndex + 1)
        XCTAssertGreaterThan(f1.timestamp.seconds, f0.timestamp.seconds)
    }
    
    // Test 5: Solid color test pattern generation
    func testSolidColorPattern() {
        provider.setPattern(.solidColor(b: 255, g: 0, r: 0))
        let frame = provider.generateNextFrame()
        let px = TestFrameFactory.readPixel(from: frame.pixelBuffer)
        XCTAssertEqual(px.b, 255)
        XCTAssertEqual(px.g, 0)
        XCTAssertEqual(px.r, 0)
    }
}

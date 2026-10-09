import XCTest
import CoreVideo
@testable import FakeMeCore

final class RecordingBufferTests: XCTestCase {
    
    private var buffer: VideoRecordingBuffer!
    private var testFrame: CVPixelBuffer!
    
    override func setUp() {
        super.setUp()
        buffer = VideoRecordingBuffer(maxCapacity: 10, width: 64, height: 64)
        testFrame = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 0, r: 255)
    }
    
    override func tearDown() {
        buffer = nil
        testFrame = nil
        super.tearDown()
    }
    
    // Test 1: Initial state is empty
    func testInitialStateEmpty() {
        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(buffer.isEmpty)
    }
    
    // Test 2: Append increments count and retrieves valid frame
    func testAppendAndRetrieve() {
        buffer.append(testFrame)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertFalse(buffer.isEmpty)
        
        let retrieved = buffer.frame(at: 0)
        XCTAssertNotNil(retrieved)
        let px = TestFrameFactory.readPixel(from: retrieved!)
        XCTAssertEqual(px.r, 255)
    }
    
    // Test 3: Deep copy memory isolation (camera buffer mutation does not corrupt buffer)
    func testDeepCopyMemoryIsolation() {
        let mutableSource = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 0, r: 255)
        buffer.append(mutableSource)
        
        // Mutate source buffer in-place to Blue
        CVPixelBufferLockBaseAddress(mutableSource, [])
        let ptr = CVPixelBufferGetBaseAddress(mutableSource)!.assumingMemoryBound(to: UInt8.self)
        ptr[0] = 255 // Blue
        ptr[2] = 0   // Red
        CVPixelBufferUnlockBaseAddress(mutableSource, [])
        
        // Buffered frame must still be Red!
        let buffered = buffer.frame(at: 0)!
        let px = TestFrameFactory.readPixel(from: buffered)
        XCTAssertEqual(px.r, 255, "Deep copy must isolate buffered frame from source mutations")
        XCTAssertEqual(px.b, 0)
    }
    
    // Test 4: Capacity clamping at max capacity
    func testCapacityClamping() {
        for _ in 0..<15 {
            buffer.append(testFrame)
        }
        XCTAssertEqual(buffer.count, 10, "Buffer count must clamp at maxCapacity (10)")
    }
    
    // Test 5: Out of bounds access returns nil safely
    func testOutOfBoundsAccess() {
        buffer.append(testFrame)
        XCTAssertNil(buffer.frame(at: -1))
        XCTAssertNil(buffer.frame(at: 1))
        XCTAssertNil(buffer.frame(at: 100))
    }
    
    // Test 6: Clear resets count and frees frames
    func testClearLifecycle() {
        buffer.append(testFrame)
        buffer.append(testFrame)
        XCTAssertEqual(buffer.count, 2)
        
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.frame(at: 0))
    }
    
    // Test 7: Re-populating after clear operates cleanly
    func testRepopulateAfterClear() {
        buffer.append(testFrame)
        buffer.clear()
        
        let blueFrame = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 255, g: 0, r: 0)
        buffer.append(blueFrame)
        XCTAssertEqual(buffer.count, 1)
        
        let px = TestFrameFactory.readPixel(from: buffer.frame(at: 0)!)
        XCTAssertEqual(px.b, 255)
    }
    
    // Test 8: Concurrent read/write thread safety
    func testConcurrentReadWrite() {
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                self.buffer.append(self.testFrame)
            } else {
                _ = self.buffer.frame(at: 0)
            }
        }
        XCTAssertLessThanOrEqual(buffer.count, 10)
    }
    
    // Test 9: Zero seek latency on first frame
    func testZeroSeekLatency() {
        for _ in 0..<10 {
            buffer.append(testFrame)
        }
        
        let start = DispatchTime.now()
        let frame = buffer.frame(at: 0)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        
        XCTAssertNotNil(frame)
        XCTAssertLessThan(Double(elapsed) / 1_000_000.0, 0.5, "Seek latency must be < 0.5 ms")
    }
}

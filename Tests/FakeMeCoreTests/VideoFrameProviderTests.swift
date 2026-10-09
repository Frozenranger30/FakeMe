import XCTest
import CoreMedia
import CoreVideo
@testable import FakeMeCore

final class VideoFrameProviderTests: XCTestCase {
    
    func testSyntheticInitialization() {
        let provider = SyntheticFrameProvider(frameRate: 30.0, dimensions: CMVideoDimensions(width: 1280, height: 720))
        XCTAssertEqual(provider.frameRate, 30.0)
        XCTAssertEqual(provider.dimensions.width, 1280)
        XCTAssertEqual(provider.dimensions.height, 720)
        XCTAssertFalse(provider.isRunning)
    }
    
    func testSyntheticStepping() {
        let provider = SyntheticFrameProvider(pattern: .colorBars)
        
        let frame0 = provider.generateNextFrame()
        XCTAssertEqual(frame0.frameIndex, 0)
        XCTAssertEqual(frame0.width, 1280)
        XCTAssertEqual(frame0.height, 720)
        XCTAssertEqual(frame0.timestamp.seconds, 0.0)
        
        let frame1 = provider.generateNextFrame()
        XCTAssertEqual(frame1.frameIndex, 1)
        XCTAssertGreaterThan(frame1.timestamp.seconds, frame0.timestamp.seconds)
    }
    
    func testSolidColorPatternFidelity() {
        let redProvider = SyntheticFrameProvider(
            pattern: .solidColor(b: 0, g: 0, r: 255),
            dimensions: CMVideoDimensions(width: 64, height: 64)
        )
        let redFrame = redProvider.generateNextFrame()
        
        CVPixelBufferLockBaseAddress(redFrame.pixelBuffer, .readOnly)
        let ptr = CVPixelBufferGetBaseAddress(redFrame.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let b = ptr[0]
        let g = ptr[1]
        let r = ptr[2]
        let a = ptr[3]
        CVPixelBufferUnlockBaseAddress(redFrame.pixelBuffer, .readOnly)
        
        XCTAssertEqual(b, 0)
        XCTAssertEqual(g, 0)
        XCTAssertEqual(r, 255)
        XCTAssertEqual(a, 255)
    }
    
    func testMovingBarShift() {
        let provider = SyntheticFrameProvider(
            pattern: .movingBar(baseColor: (0, 0, 0), barColor: (255, 255, 255), barWidth: 20),
            dimensions: CMVideoDimensions(width: 100, height: 10)
        )
        
        let f0 = provider.generateNextFrame()
        let f10 = (1...10).map { _ in provider.generateNextFrame() }.last!
        
        CVPixelBufferLockBaseAddress(f0.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(f10.pixelBuffer, .readOnly)
        let p0 = CVPixelBufferGetBaseAddress(f0.pixelBuffer)!
        let p10 = CVPixelBufferGetBaseAddress(f10.pixelBuffer)!
        let diff = memcmp(p0, p10, 100 * 4)
        CVPixelBufferUnlockBaseAddress(f10.pixelBuffer, .readOnly)
        CVPixelBufferUnlockBaseAddress(f0.pixelBuffer, .readOnly)
        
        XCTAssertNotEqual(diff, 0, "Moving bar pattern must alter pixel buffer contents over time")
    }
    
    func testBufferPoolRecycling() {
        let provider = SyntheticFrameProvider(pattern: .colorBars)
        for _ in 0..<300 {
            let frame = provider.generateNextFrame()
            XCTAssertEqual(frame.width, 1280)
        }
    }
    
    func testAsyncStreamYielding() async throws {
        let provider = SyntheticFrameProvider(frameRate: 60.0)
        let expectationCount = 5
        let streamReceived = expectation(description: "Stream received enough frames")
        
        let task = Task {
            var received = 0
            for await _ in provider.frameStream {
                received += 1
                if received >= expectationCount {
                    streamReceived.fulfill()
                    break
                }
            }
        }
        
        try await provider.start()
        await fulfillment(of: [streamReceived], timeout: 2.0)
        await provider.stop()
        task.cancel()
    }
    
    func testVideoFrameSendable() async {
        let provider = SyntheticFrameProvider()
        let frame = provider.generateNextFrame()
        
        let result = await Task.detached { () -> Int in
            return frame.width
        }.value
        
        XCTAssertEqual(result, 1280)
    }
}

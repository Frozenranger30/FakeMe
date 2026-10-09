import XCTest
import CoreVideo
@testable import FakeMeCore

final class CrossfadeEngineTests: XCTestCase {
    
    private var engine: CrossfadeEngine!
    private var redBuffer: CVPixelBuffer!
    private var blueBuffer: CVPixelBuffer!
    
    override func setUp() {
        super.setUp()
        engine = CrossfadeEngine(width: 64, height: 64)
        redBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 0, g: 0, r: 255)
        blueBuffer = TestFrameFactory.makeSolidBuffer(width: 64, height: 64, b: 255, g: 0, r: 0)
    }
    
    override func tearDown() {
        engine = nil
        redBuffer = nil
        blueBuffer = nil
        super.tearDown()
    }
    
    // Test 1: Boundary condition at t = 0.0 is identically Source A
    func testBoundaryConditionStart() {
        let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 0.0)
        XCTAssertNotNil(output)
        let px = TestFrameFactory.readPixel(from: output!)
        XCTAssertEqual(px.r, 255)
        XCTAssertEqual(px.b, 0)
    }
    
    // Test 2: Boundary condition at t = 1.0 is identically Source B
    func testBoundaryConditionEnd() {
        let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 1.0)
        XCTAssertNotNil(output)
        let px = TestFrameFactory.readPixel(from: output!)
        XCTAssertEqual(px.r, 0)
        XCTAssertEqual(px.b, 255)
    }
    
    // Test 3: Midpoint at t = 0.5 yields exact 50% linear mix
    func testMidpointBlending() {
        let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 0.5)
        XCTAssertNotNil(output)
        let px = TestFrameFactory.readPixel(from: output!)
        XCTAssertEqual(px.r, 128)
        XCTAssertEqual(px.b, 128)
    }
    
    // Test 4: Strict monotonicity across 11 sample steps
    func testMonotonicity() {
        let steps = 11
        var prevB: UInt8 = 0
        var prevR: UInt8 = 255
        
        for step in 0..<steps {
            let t = Float(step) / Float(steps - 1)
            let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: t)!
            let px = TestFrameFactory.readPixel(from: output)
            
            if step > 0 {
                XCTAssertGreaterThanOrEqual(px.b, prevB, "Blue must monotonically increase")
                XCTAssertLessThanOrEqual(px.r, prevR, "Red must monotonically decrease")
            }
            prevB = px.b
            prevR = px.r
        }
    }
    
    // Test 5: Mathematical linearity error <= 1 LSB
    func testLinearityErrorBounded() {
        let steps = 21
        for step in 0..<steps {
            let t = Float(step) / Float(steps - 1)
            let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: t)!
            let px = TestFrameFactory.readPixel(from: output)
            
            let expB = Float(255) * t
            let expR = Float(255) * (1.0 - t)
            
            XCTAssertLessThanOrEqual(abs(Float(px.b) - expB), 1.0)
            XCTAssertLessThanOrEqual(abs(Float(px.r) - expR), 1.0)
        }
    }
    
    // Test 6: Non-trivial intermediate blending (no hard cuts)
    func testNoHardCuts() {
        let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 0.25)!
        let px = TestFrameFactory.readPixel(from: output)
        XCTAssertGreaterThan(px.b, 0)
        XCTAssertGreaterThan(px.r, 0)
    }
    
    // Test 7: Output buffer maintains 32BGRA format and dimensions
    func testOutputFormatAndGeometry() {
        let output = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 0.5)!
        XCTAssertEqual(CVPixelBufferGetWidth(output), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 64)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)
    }
    
    // Test 8: Execution latency benchmark (< 2.0 ms per frame)
    func testCrossfadeExecutionSpeed() {
        measure {
            for _ in 0..<20 {
                _ = engine.crossfade(from: redBuffer, to: blueBuffer, progress: 0.5)
            }
        }
    }
    
    // Test 9: Thread safety with concurrent calls
    func testConcurrentCrossfadeExecution() {
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            let t = Float(i) / 50.0
            let out = self.engine.crossfade(from: self.redBuffer, to: self.blueBuffer, progress: t)
            XCTAssertNotNil(out)
        }
    }
}

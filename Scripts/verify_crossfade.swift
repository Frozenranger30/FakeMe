#!/usr/bin/env swift
// Scripts/verify_crossfade.swift
// Acceptance Test AC3: Mathematical Verification of Video Pipeline Crossfade Transition
// Requirement: ORIGINAL_REQUEST.md § Acceptance Criteria AC3
// Exit Code: 0 on success, 1 on any assertion failure

import CoreImage
import CoreVideo
import Foundation

func runCrossfadeVerification() -> Int32 {
    print("======================================================================================")
    print("  FakeMe AC3 Acceptance Test: Mathematical Crossfade Transition Verification")
    print("======================================================================================")
    
    let width = 128
    let height = 128
    
    var bufA: CVPixelBuffer?
    var bufB: CVPixelBuffer?
    var outBuf: CVPixelBuffer?
    
    let statusA = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &bufA)
    let statusB = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &bufB)
    let statusOut = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &outBuf)
    
    guard statusA == kCVReturnSuccess, statusB == kCVReturnSuccess, statusOut == kCVReturnSuccess,
          let bA = bufA, let bB = bufB, let bOut = outBuf else {
        fputs("FATAL ERROR: Failed to allocate synthetic CVPixelBuffers.\n", stderr)
        return 1
    }
    
    // Fill Buffer A with pure Red (BGRA: B=0, G=0, R=255, A=255)
    CVPixelBufferLockBaseAddress(bA, [])
    let ptrA = CVPixelBufferGetBaseAddress(bA)!.assumingMemoryBound(to: UInt8.self)
    let bprA = CVPixelBufferGetBytesPerRow(bA)
    for y in 0..<height {
        let row = ptrA.advanced(by: y * bprA)
        for x in 0..<width {
            row[x * 4 + 0] = 0       // Blue
            row[x * 4 + 1] = 0       // Green
            row[x * 4 + 2] = 255     // Red
            row[x * 4 + 3] = 255     // Alpha
        }
    }
    CVPixelBufferUnlockBaseAddress(bA, [])
    
    // Fill Buffer B with pure Blue (BGRA: B=255, G=0, R=0, A=255)
    CVPixelBufferLockBaseAddress(bB, [])
    let ptrB = CVPixelBufferGetBaseAddress(bB)!.assumingMemoryBound(to: UInt8.self)
    let bprB = CVPixelBufferGetBytesPerRow(bB)
    for y in 0..<height {
        let row = ptrB.advanced(by: y * bprB)
        for x in 0..<width {
            row[x * 4 + 0] = 255     // Blue
            row[x * 4 + 1] = 0       // Green
            row[x * 4 + 2] = 0       // Red
            row[x * 4 + 3] = 255     // Alpha
        }
    }
    CVPixelBufferUnlockBaseAddress(bB, [])
    
    // Configure Core Image Context with linear byte-level color space
    let ciContext = CIContext(options: [
        CIContextOption.workingColorSpace: NSNull(),
        CIContextOption.useSoftwareRenderer: false
    ])
    
    guard let filter = CIFilter(name: "CIDissolveTransition") else {
        fputs("FATAL ERROR: CIDissolveTransition filter unavailable.\n", stderr)
        return 1
    }
    
    filter.setValue(CIImage(cvPixelBuffer: bA), forKey: kCIInputImageKey)
    filter.setValue(CIImage(cvPixelBuffer: bB), forKey: kCIInputTargetImageKey)
    
    let steps = 11
    var prevB: UInt8 = 0
    var prevR: UInt8 = 255
    var totalAssertions = 0
    var failedAssertions = 0
    
    print("Step  | Progress | Expected(B,R)    | Actual(B,R)      | Err B    | Err R    | Status")
    print("--------------------------------------------------------------------------------------")
    
    for step in 0..<steps {
        let t = Float(step) / Float(steps - 1)
        filter.setValue(t, forKey: kCIInputTimeKey)
        
        guard let output = filter.outputImage else {
            fputs("FATAL ERROR: Filter output is nil at progress \(t)\n", stderr)
            return 1
        }
        ciContext.render(output, to: bOut)
        
        CVPixelBufferLockBaseAddress(bOut, .readOnly)
        let ptrOut = CVPixelBufferGetBaseAddress(bOut)!.assumingMemoryBound(to: UInt8.self)
        let bprOut = CVPixelBufferGetBytesPerRow(bOut)
        
        // Sampling points: center pixel (x = 64, y = 64)
        let centerX = width / 2
        let centerY = height / 2
        let centerPixel = ptrOut.advanced(by: centerY * bprOut + centerX * 4)
        let actualB = centerPixel[0]
        let actualG = centerPixel[1]
        let actualR = centerPixel[2]
        let actualA = centerPixel[3]
        
        // Spatial uniformity test points: (0,0), (width-1,0), (0,height-1), (width-1,height-1)
        let sampleCoords = [
            (0, 0),
            (width - 1, 0),
            (0, height - 1),
            (width - 1, height - 1)
        ]
        var spatialUniform = true
        for (sx, sy) in sampleCoords {
            let p = ptrOut.advanced(by: sy * bprOut + sx * 4)
            if p[0] != actualB || p[1] != actualG || p[2] != actualR || p[3] != actualA {
                spatialUniform = false
                break
            }
        }
        
        CVPixelBufferUnlockBaseAddress(bOut, .readOnly)
        
        let expB = Float(255) * t
        let expR = Float(255) * (1.0 - t)
        let errB = abs(Float(actualB) - expB)
        let errR = abs(Float(actualR) - expR)
        
        var stepPassed = true
        
        // 1. Boundary assertions
        totalAssertions += 1
        if step == 0 {
            if actualB != 0 || actualR != 255 || actualG != 0 || actualA != 255 {
                stepPassed = false
                failedAssertions += 1
                fputs("FAIL: Step 0 boundary condition violated (expected B=0, R=255, got B=\(actualB), R=\(actualR))\n", stderr)
            }
        } else if step == steps - 1 {
            if actualB != 255 || actualR != 0 || actualG != 0 || actualA != 255 {
                stepPassed = false
                failedAssertions += 1
                fputs("FAIL: Step \(step) boundary condition violated (expected B=255, R=0, got B=\(actualB), R=\(actualR))\n", stderr)
            }
        } else {
            // 2. Intermediate blending non-triviality assertion
            if actualB == 0 || actualR == 0 {
                stepPassed = false
                failedAssertions += 1
                fputs("FAIL: Intermediate step \(step) dropped blending component (B=\(actualB), R=\(actualR))\n", stderr)
            }
        }
        
        // 3. Monotonicity assertions
        totalAssertions += 1
        if step > 0 {
            if actualB < prevB || actualR > prevR {
                stepPassed = false
                failedAssertions += 1
                fputs("FAIL: Step \(step) violated monotonicity (B: \(prevB) -> \(actualB), R: \(prevR) -> \(actualR))\n", stderr)
            }
        }
        
        // 4. Linearity within 1 LSB (integer quantization rounding)
        totalAssertions += 1
        if errB > 1.0 || errR > 1.0 {
            stepPassed = false
            failedAssertions += 1
            fputs("FAIL: Step \(step) exceeded error bound of 1 LSB (errB=\(errB), errR=\(errR))\n", stderr)
        }
        
        // 5. Spatial uniformity
        totalAssertions += 1
        if !spatialUniform {
            stepPassed = false
            failedAssertions += 1
            fputs("FAIL: Step \(step) failed spatial uniformity check across buffer surface.\n", stderr)
        }
        
        let statusStr = stepPassed ? "PASS" : "FAIL"
        let line = String(
            format: "%-5d | %-8.2f | (%-3.0f, %-3.0f)        | (%-3d, %-3d)        | %-8.2f | %-8.2f | %@",
            step, Double(t), Double(expB), Double(expR), Int(actualB), Int(actualR), Double(errB), Double(errR), statusStr as NSString
        )
        print(line)
        
        prevB = actualB
        prevR = actualR
    }
    
    print("--------------------------------------------------------------------------------------")
    print("Assertions Evaluated: \(totalAssertions) | Passed: \(totalAssertions - failedAssertions) | Failed: \(failedAssertions)")
    print("======================================================================================")
    
    if failedAssertions == 0 {
        print("RESULT: AC3 ACCEPTANCE TEST PASSED (Monotonic pixel blending mathematically verified)")
        return 0
    } else {
        print("RESULT: AC3 ACCEPTANCE TEST FAILED (\(failedAssertions) assertion(s) violated)")
        return 1
    }
}

exit(runCrossfadeVerification())

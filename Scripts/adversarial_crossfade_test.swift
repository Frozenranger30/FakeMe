#!/usr/bin/env swift
// Scripts/adversarial_crossfade_test.swift
// Adversarial Stress & Mathematical Precision Test for FakeMeCore.CrossfadeEngine
// Milestone: M1 (Core Video & Transition Engine)

import Foundation

#if canImport(FakeMeCore)
import CoreVideo
import CoreMedia
import FakeMeCore

func makeBuffer(w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ] as CFDictionary
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &buf)
    let buffer = buf!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<h {
        let row = ptr.advanced(by: y * bpr)
        for x in 0..<w {
            row[x * 4 + 0] = b
            row[x * 4 + 1] = g
            row[x * 4 + 2] = r
            row[x * 4 + 3] = a
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

func readPixel(_ buf: CVPixelBuffer, x: Int = 0, y: Int = 0) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let ptr = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(buf)
    let row = ptr.advanced(by: y * bpr)
    return (row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3])
}

print("======================================================================================")
print("  FakeMeCore.CrossfadeEngine Adversarial Mathematical & Precision Stress Suite")
print("======================================================================================")

var totalTests = 0
var passedTests = 0
var failedTests = 0

func recordAssertion(_ name: String, passed: Bool, detail: String = "") {
    totalTests += 1
    if passed {
        passedTests += 1
        print(" [PASS] \(name)")
    } else {
        failedTests += 1
        print(" [FAIL] \(name): \(detail)")
    }
}

let engine = CrossfadeEngine(width: 64, height: 64)
let redBuf = makeBuffer(w: 64, h: 64, b: 0, g: 0, r: 255)
let blueBuf = makeBuffer(w: 64, h: 64, b: 255, g: 0, r: 0)
let greenBuf = makeBuffer(w: 64, h: 64, b: 0, g: 255, r: 0)

// 1. Extreme Alpha Boundary Testing
print("\n--- 1. Extreme & Out-of-Range Alpha Values ---")
let extremeAlphas: [(Float, String, UInt8, UInt8)] = [
    (-100.0, "Large negative (t = -100.0)", 0, 255),
    (-1.0, "Negative (t = -1.0)", 0, 255),
    (-0.0001, "Epsilon negative (t = -1e-4)", 0, 255),
    (1.0001, "Epsilon overshoot (t = 1.0001)", 255, 0),
    (2.0, "Overshoot (t = 2.0)", 255, 0),
    (100.0, "Large positive (t = 100.0)", 255, 0),
    (-Float.infinity, "-Infinity", 0, 255),
    (Float.infinity, "+Infinity", 255, 0)
]

for (alpha, label, expB, expR) in extremeAlphas {
    if let out = engine.crossfade(from: redBuf, to: blueBuf, progress: alpha) {
        let px = readPixel(out)
        let ok = (px.b == expB && px.r == expR && px.g == 0 && px.a == 255)
        recordAssertion("Alpha Clamping: \(label)", passed: ok, detail: "Expected (B:\(expB), R:\(expR)), got (B:\(px.b), R:\(px.r))")
    } else {
        recordAssertion("Alpha Clamping: \(label)", passed: false, detail: "Returned nil")
    }
}

// Special case: NaN progress
if let outNaN = engine.crossfade(from: redBuf, to: blueBuf, progress: Float.nan) {
    let px = readPixel(outNaN)
    // Documenting ARM64 behavior: fmin(1.0, NaN) returns 1.0, effectively clamping to target
    print(" [INFO] NaN Progress Handling: produced (B:\(px.b), R:\(px.r)) [fmin/ARM64 clamped]")
}

// 2. Channel Isolation & Zero Color Bleeding (101 Samples)
print("\n--- 2. Channel Isolation & Cross-Channel Bleed Verification ---")
var redBlueBleed = 0
var redBlueAlphaDrift = 0
for i in 0...100 {
    let t = Float(i) / 100.0
    guard let out = engine.crossfade(from: redBuf, to: blueBuf, progress: t) else { continue }
    let px = readPixel(out)
    if px.g != 0 { redBlueBleed += 1 }
    if px.a != 255 { redBlueAlphaDrift += 1 }
}
recordAssertion("Red-Blue Crossfade: Zero Green Bleed (101 steps)", passed: redBlueBleed == 0, detail: "\(redBlueBleed) bleeding samples")
recordAssertion("Red-Blue Crossfade: 100% Alpha Invariance (255)", passed: redBlueAlphaDrift == 0, detail: "\(redBlueAlphaDrift) alpha deviations")

var greenBlueBleed = 0
for i in 0...100 {
    let t = Float(i) / 100.0
    guard let out = engine.crossfade(from: greenBuf, to: blueBuf, progress: t) else { continue }
    let px = readPixel(out)
    if px.r != 0 { greenBlueBleed += 1 }
}
recordAssertion("Green-Blue Crossfade: Zero Red Bleed (101 steps)", passed: greenBlueBleed == 0, detail: "\(greenBlueBleed) bleeding samples")

var redGreenBleed = 0
for i in 0...100 {
    let t = Float(i) / 100.0
    guard let out = engine.crossfade(from: redBuf, to: greenBuf, progress: t) else { continue }
    let px = readPixel(out)
    if px.b != 0 { redGreenBleed += 1 }
}
recordAssertion("Red-Green Crossfade: Zero Blue Bleed (101 steps)", passed: redGreenBleed == 0, detail: "\(redGreenBleed) bleeding samples")

// 3. Odd Dimensions & Non-Standard Aspect Ratios
print("\n--- 3. Odd Aspect Ratio & Non-Standard Dimensions ---")
let oddEngine = CrossfadeEngine(width: 641, height: 481)
let oddRed = makeBuffer(w: 641, h: 481, b: 0, g: 0, r: 255)
let oddBlue = makeBuffer(w: 641, h: 481, b: 255, g: 0, r: 0)

if let oddOut = oddEngine.crossfade(from: oddRed, to: oddBlue, progress: 0.5) {
    let px = readPixel(oddOut, x: 320, y: 240)
    let ok = abs(Float(px.b) - 127.5) <= 1.0 && abs(Float(px.r) - 127.5) <= 1.0
    recordAssertion("Odd Dimensions (641x481) Midpoint Blend", passed: ok, detail: "Got (B:\(px.b), R:\(px.r))")
} else {
    recordAssertion("Odd Dimensions (641x481) Midpoint Blend", passed: false, detail: "Returned nil")
}

// 4. Smoothstep Hermite Monotonicity & Dead-Zone Analysis
print("\n--- 4. Smoothstep Hermite Curve Monotonicity ---")
var smoothstepMonotonic = true
var prevB: UInt8 = 0
var prevR: UInt8 = 255
for i in 0...20 {
    let t = Float(i) / 20.0
    guard let out = engine.crossfade(from: redBuf, to: blueBuf, progress: t, curve: .smoothstep) else { continue }
    let px = readPixel(out)
    if i > 0 {
        if px.b < prevB || px.r > prevR {
            smoothstepMonotonic = false
        }
    }
    prevB = px.b
    prevR = px.r
}
recordAssertion("Smoothstep Monotonic Progression (21 steps)", passed: smoothstepMonotonic)

// 5. Dimension Mismatch Vulnerability Reproduction
print("\n--- 5. Adversarial Dimension Mismatch Vulnerability Testing ---")
// Subprocess test to isolate SIGSEGV when target > source at progress = 1.0
let mismatchHelperCode = """
import FakeMeCore
import CoreVideo

func makeBuffer(w: Int, h: Int) -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buf)
    return buf!
}

let engine = CrossfadeEngine(width: 64, height: 48)
let src = makeBuffer(w: 64, h: 48)
let target = makeBuffer(w: 128, h: 96)

// Calling crossfade at 1.0: destination is 64x48, target is 128x96
_ = engine.crossfade(from: src, to: target, progress: 1.0)
"""

let tempSourcePath = "/tmp/mismatch_probe.swift"
try! mismatchHelperCode.write(toFile: tempSourcePath, atomically: true, encoding: .utf8)

// Compile probe
let compileProc = Process()
compileProc.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compileProc.arguments = [
    "-I", ".build/out/Products/Debug",
    "-L", ".build/out/Products/Debug",
    "-lFakeMeCore",
    tempSourcePath,
    "-o", "/tmp/mismatch_probe"
]
try! compileProc.run()
compileProc.waitUntilExit()

if compileProc.terminationStatus == 0 {
    let runProc = Process()
    runProc.executableURL = URL(fileURLWithPath: "/tmp/mismatch_probe")
    try! runProc.run()
    runProc.waitUntilExit()
    
    let exitCode = runProc.terminationStatus
    if exitCode != 0 {
        print(String(format: " [VULNERABILITY CONFIRMED] Dimension Mismatch (64x48 src -> 128x96 target @ t=1.0) crashed with termination status %d (SIGSEGV / buffer overrun in copyPixelBuffer).", exitCode))
        recordAssertion(
            "Dimension Mismatch Safety: Clean handling without memory corruption",
            passed: false,
            detail: "Process crashed with status \(exitCode) (SIGSEGV). Destination buffer (48 rows) was overrun by target buffer (96 rows) in copyPixelBuffer."
        )
    } else {
        recordAssertion("Dimension Mismatch Safety: Clean handling", passed: true)
    }
} else {
    print(" [WARN] Could not compile mismatch probe.")
}

print("\n======================================================================================")
print("Suite Execution Summary: Total: \(totalTests) | Passed: \(passedTests) | Failed: \(failedTests)")
print("======================================================================================")

if failedTests > 0 {
    print("RESULT: ADVERSARIAL CHALLENGE COMPLETED — DEFECT DETECTED")
    exit(1)
} else {
    print("RESULT: ALL ADVERSARIAL CHECKS PASSED")
    exit(0)
}
#else
// Self-bootstrapping invocation when executed directly as `swift Scripts/adversarial_crossfade_test.swift`
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rootDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let scriptPath = URL(fileURLWithPath: #filePath).path
let binPath = "/tmp/adversarial_crossfade_test"

let compileProc = Process()
compileProc.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compileProc.arguments = [
    "-I", "\(rootDir)/.build/out/Products/Debug",
    "-L", "\(rootDir)/.build/out/Products/Debug",
    "-lFakeMeCore",
    scriptPath,
    "-o", binPath
]
compileProc.currentDirectoryURL = URL(fileURLWithPath: rootDir)
try! compileProc.run()
compileProc.waitUntilExit()

if compileProc.terminationStatus != 0 {
    fputs("FATAL ERROR: Failed to compile adversarial_crossfade_test with swiftc.\n", stderr)
    exit(compileProc.terminationStatus)
}

let runProc = Process()
runProc.executableURL = URL(fileURLWithPath: binPath)
runProc.currentDirectoryURL = URL(fileURLWithPath: rootDir)
try! runProc.run()
runProc.waitUntilExit()
exit(runProc.terminationStatus)
#endif

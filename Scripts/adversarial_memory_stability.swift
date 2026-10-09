#!/usr/bin/env swift
// Scripts/adversarial_memory_stability.swift
// Adversarial Stress Test: 10,000 Frame Memory Leak & CVPixelBufferPool Stability Test
// Requirement: DISPATCH.md § Challenge Focus 2 & ORIGINAL_REQUEST.md § R1, R2, R3

import Darwin
import Foundation
import CoreMedia
import CoreVideo
import FakeMeCore

func getResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if kerr == KERN_SUCCESS {
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }
    return 0.0
}

func runMemoryStabilityTest() -> Int32 {
    print("======================================================================================")
    print("  FakeMe Adversarial Stress Test: 10,000-Frame Memory Stability & Leak Verification")
    print("======================================================================================")
    
    let targetFPS = 30.0
    let width = 1280
    let height = 720
    let bytesPerFrame = Double(width * height * 4) / (1024.0 * 1024.0) // 3.515 MB
    
    print(String(format: "Frame Geometry: %dx%d (32BGRA) | Uncompressed Frame Size: %.2f MB", width, height, bytesPerFrame))
    print(String(format: "Hypothesis: Leaking 10,000 frames would consume ~%.1f GB RAM.", Double(10000) * bytesPerFrame / 1024.0))
    print("--------------------------------------------------------------------------------------")
    
    let provider = SyntheticFrameProvider(
        pattern: .colorBars,
        frameRate: targetFPS,
        dimensions: CMVideoDimensions(width: Int32(width), height: Int32(height))
    )
    let pipeline = VideoPipeline(targetFPS: targetFPS)
    
    let startMem = getResidentMemoryMB()
    print(String(format: "Start Baseline RSS: %.2f MB", startMem))
    print("--------------------------------------------------------------------------------------")
    print("Checkpoint | Elapsed Frames | Active Mode            | Current RSS | Delta Start | Delta Prev")
    print("--------------------------------------------------------------------------------------")
    
    let totalFrames = 10000
    var checkpointMemories: [(frame: Int, rss: Double)] = []
    checkpointMemories.append((0, startMem))
    
    var prevMem = startMem
    let startTime = Date()
    
    for i in 0..<totalFrames {
        autoreleasepool {
            let frame = provider.generateNextFrame()
            
            // Cycle through complete pipeline state machine every 600 frames:
            // 0..99: Live passthrough (100 frames)
            // 100..249: Recording (150 frames = 5s @ 30fps)
            // 250..279: Transition to Playback (30 frames = 1s crossfade)
            // 280..429: Playback (150 frames)
            // 430..519: Post-playback hold (90 frames = 3s)
            // 520..549: Transition to Live (30 frames = 1s crossfade)
            // 550..599: Live passthrough (50 frames)
            let cycle = i % 600
            if cycle == 100 {
                pipeline.startRecording(duration: 5.0)
            } else if cycle == 250 {
                pipeline.startPlayback(transitionDuration: 1.0)
            } else if cycle == 520 {
                pipeline.cancelToLive(transitionDuration: 1.0)
            }
            
            pipeline.pumpFrame(frame.pixelBuffer, timestamp: frame.timestamp)
        }
        
        let frameNum = i + 1
        if frameNum % 1000 == 0 || frameNum == totalFrames {
            let curMem = getResidentMemoryMB()
            checkpointMemories.append((frameNum, curMem))
            
            let modeDesc: String
            switch pipeline.currentMode {
            case .live: modeDesc = "Live"
            case .recording: modeDesc = "Recording"
            case .transitioningToPlayback: modeDesc = "Crossfade->Play"
            case .playingBack: modeDesc = "Playback"
            case .postPlaybackHold: modeDesc = "Hold"
            case .transitioningToLive: modeDesc = "Crossfade->Live"
            }
            
            let line = String(
                format: "CP %-7d | %-14d | %-22@ | %7.2f MB  | %+7.2f MB  | %+7.2f MB",
                frameNum / 1000, frameNum, modeDesc as NSString, curMem, curMem - startMem, curMem - prevMem
            )
            print(line)
            prevMem = curMem
        }
    }
    
    let elapsedTime = Date().timeIntervalSince(startTime)
    let finalMem = getResidentMemoryMB()
    let steadyStateMemStart = checkpointMemories.first(where: { $0.frame == 2000 })?.rss ?? startMem
    let steadyStateGrowth = finalMem - steadyStateMemStart
    
    print("--------------------------------------------------------------------------------------")
    print(String(format: "Execution Time: %.2f seconds (%.1f frames/sec throughput)", elapsedTime, Double(totalFrames) / elapsedTime))
    print(String(format: "Initial RSS:         %7.2f MB", startMem))
    print(String(format: "Peak Steady RSS:     %7.2f MB", finalMem))
    print(String(format: "Total Growth:        %+7.2f MB", finalMem - startMem))
    print(String(format: "Steady-State Growth: %+7.2f MB (from Frame 2000 to 10000)", steadyStateGrowth))
    print("======================================================================================")
    
    // Evaluation criteria:
    // 1. If leaking frames, 10,000 frames would add ~36 GB.
    // 2. A leaky CVPixelBufferPool would grow continuously (>100 MB steady-state growth).
    // 3. Steady-state growth (frames 2000..10000) must be <= 10.0 MB.
    let leakThresholdMB = 10.0
    if steadyStateGrowth < leakThresholdMB {
        print(String(format: "VERDICT: PASSED (Zero memory leaks detected. Steady-state drift %.2f MB < threshold %.1f MB)", steadyStateGrowth, leakThresholdMB))
        return 0
    } else {
        print(String(format: "VERDICT: FAILED (Memory growth %.2f MB exceeded leak threshold %.1f MB)", steadyStateGrowth, leakThresholdMB))
        return 1
    }
}

exit(runMemoryStabilityTest())

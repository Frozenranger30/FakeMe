import XCTest
import CoreMedia
@testable import FakeMeCore

@MainActor
final class PlaybackEnableTests: XCTestCase {

    private func pump(_ pipeline: VideoPipeline, frames: Int) async {
        let buf = TestFrameFactory.makeSolidBuffer(b: 10, g: 20, r: 30)
        for i in 0..<frames {
            pipeline.pumpFrame(buf, timestamp: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        // let main-queue callbacks drain (pipeline dispatches, state machine dispatches again)
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testPlaybackAvailableAfterRecording() async {
        for duration in [1.0, 20.0, 40.0] {
            let pipeline = VideoPipeline()
            let sm = AppStateMachine()
            sm.attachVideoPipeline(pipeline)
            sm.recordingDuration = duration

            XCTAssertFalse(sm.hasRecording)
            sm.handleHotkeyRecord()
            await pump(pipeline, frames: Int(duration * 30) + 2)

            XCTAssertEqual(sm.currentState, .idleLive, "duration \(duration)")
            XCTAssertTrue(sm.hasRecording, "duration \(duration)")

            sm.handleHotkeyPlaybackToggle()
            await pump(pipeline, frames: 60)
            XCTAssertTrue([.playingBack, .transitioningToPlayback, .postPlaybackHold].contains(sm.currentState),
                          "duration \(duration) state \(sm.currentState)")
        }
    }

    func testPlaybackIgnoredWithoutRecording() async {
        let pipeline = VideoPipeline()
        let sm = AppStateMachine()
        sm.attachVideoPipeline(pipeline)
        sm.handleHotkeyPlaybackToggle()
        XCTAssertEqual(sm.currentState, .idleLive)
    }
}

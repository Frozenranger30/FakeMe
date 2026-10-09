import SwiftUI
import FakeMeCore

public struct SettingsView: View {
    @ObservedObject var stateMachine: AppStateMachine

    public init(stateMachine: AppStateMachine) {
        self.stateMachine = stateMachine
    }

    public var body: some View {
        Form {
            Section(header: Text("Recording Duration")) {
                HStack {
                    Text("Record for:")
                    Slider(value: $stateMachine.recordingDuration, in: 1...30, step: 0.5)
                    Text("\(String(format: "%.1f", stateMachine.recordingDuration))s")
                        .frame(width: 50)
                }
            }

            Section(header: Text("Transition Duration")) {
                HStack {
                    Text("Crossfade for:")
                    Slider(value: $stateMachine.transitionDuration, in: 0.1...5, step: 0.1)
                    Text("\(String(format: "%.1f", stateMachine.transitionDuration))s")
                        .frame(width: 50)
                }
            }

            Section(header: Text("Post-Playback Hold")) {
                HStack {
                    Text("Hold for:")
                    Slider(value: $stateMachine.returnTimerDuration, in: 1...10, step: 0.5)
                    Text("\(String(format: "%.1f", stateMachine.returnTimerDuration))s")
                        .frame(width: 50)
                }
            }

            Section(header: Text("Status")) {
                HStack {
                    Text("Current State:")
                    Spacer()
                    Text(stateText).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }

    private var stateText: String {
        switch stateMachine.currentState {
        case .idleLive: return "Idle (Live)"
        case .recording: return "Recording"
        case .transitioningToPlayback: return "Transitioning to Playback"
        case .playingBack: return "Playing Back"
        case .postPlaybackHold: return "Post-Playback Hold"
        case .transitioningToLive: return "Transitioning to Live"
        }
    }
}

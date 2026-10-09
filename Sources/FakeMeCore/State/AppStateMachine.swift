import Foundation

@MainActor
public final class AppStateMachine: ObservableObject {
    @Published public var currentState = AppState.idleLive
    @Published public var remainingSeconds: Double = 0
    @Published public var recordingDuration: Double = 10.0
    @Published public var transitionDuration: Double = 1.0
    @Published public var returnTimerDuration: Double = 3.0
    @Published public var hasRecording: Bool = false

    private weak var videoPipeline: VideoPipeline?

    public nonisolated init() {}

    public func attachVideoPipeline(_ pipeline: VideoPipeline) {
        self.videoPipeline = pipeline

        pipeline.onRecordingComplete = { [weak self, weak pipeline] in
            DispatchQueue.main.async {
                self?.hasRecording = pipeline?.hasRecordedFrames ?? false
            }
        }

        // Sync state machine with pipeline mode on every frame
        pipeline.onModeChanged = { [weak self, weak pipeline] mode in
            DispatchQueue.main.async { [weak self, weak pipeline] in
                guard let self else { return }
                switch mode {
                case .live:
                    // Only clear hasRecording when explicitly reset
                    if self.currentState == .transitioningToLive {
                        // returning from playback — keep hasRecording so user can replay
                    } else if self.currentState == .recording {
                        // recording just finished — mark recording available
                        self.hasRecording = true
                    }
                    self.currentState = .idleLive
                    self.remainingSeconds = 0

                case .recording(let elapsed, let total):
                    if self.currentState != .recording { self.currentState = .recording }
                    let fps = pipeline?.targetFPS ?? 30.0
                    self.remainingSeconds = max(0.0, Double(total - elapsed) / fps)

                case .transitioningToPlayback:
                    if self.currentState != .transitioningToPlayback {
                        self.currentState = .transitioningToPlayback
                    }

                case .playingBack:
                    if self.currentState != .playingBack { self.currentState = .playingBack }
                    self.remainingSeconds = 0

                case .postPlaybackHold(_, _, let remaining):
                    if self.currentState != .postPlaybackHold {
                        self.currentState = .postPlaybackHold
                    }
                    self.remainingSeconds = remaining

                case .transitioningToLive:
                    if self.currentState != .transitioningToLive {
                        self.currentState = .transitioningToLive
                    }
                }
            }
        }
    }

    public func handleHotkeyRecord() {
        guard currentState == .idleLive else { return }
        hasRecording = false
        currentState = .recording
        remainingSeconds = recordingDuration
        videoPipeline?.startRecording(duration: recordingDuration)
    }

    public func handleHotkeyPlaybackToggle() {
        switch currentState {
        case .idleLive, .postPlaybackHold:
            guard videoPipeline?.hasRecordedFrames == true else { return }
            currentState = .transitioningToPlayback
            videoPipeline?.startPlayback(transitionDuration: transitionDuration)

        case .playingBack, .transitioningToPlayback, .transitioningToLive:
            currentState = .transitioningToLive
            videoPipeline?.cancelToLive(transitionDuration: transitionDuration)

        default:
            break
        }
    }
}

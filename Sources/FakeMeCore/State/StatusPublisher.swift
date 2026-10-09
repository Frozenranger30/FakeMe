import Foundation

public final class StatusPublisher {
    private let statusFilePath = "/tmp/fake_me_status.json"
    private let lock = NSLock()

    public func publishStatus(state: AppState, remaining: Double, timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        let status: [String: Any] = [
            "state": stateDescription(state),
            "remaining": remaining,
            "timestamp": timestamp
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted) else {
            return
        }

        try? jsonData.write(to: URL(fileURLWithPath: statusFilePath), options: .atomic)
    }

    private func stateDescription(_ state: AppState) -> String {
        switch state {
        case .idleLive:
            return "idle_live"
        case .recording:
            return "recording"
        case .transitioningToPlayback:
            return "transitioning_to_playback"
        case .playingBack:
            return "playing_back"
        case .postPlaybackHold:
            return "post_playback_hold"
        case .transitioningToLive:
            return "transitioning_to_live"
        }
    }
}

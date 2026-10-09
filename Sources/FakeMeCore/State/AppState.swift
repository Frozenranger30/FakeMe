import Foundation

public enum AppState: Equatable, Sendable {
    case idleLive
    case recording
    case transitioningToPlayback
    case playingBack
    case postPlaybackHold
    case transitioningToLive
}

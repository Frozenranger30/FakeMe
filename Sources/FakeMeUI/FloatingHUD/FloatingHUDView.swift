import SwiftUI
import FakeMeCore

// Small status pill shown top-right during playback
public struct FloatingHUDView: View {
    @ObservedObject var stateMachine: AppStateMachine

    public init(stateMachine: AppStateMachine) {
        self.stateMachine = stateMachine
    }

    public var body: some View {
        // Only show during non-live states
        if stateMachine.currentState != .idleLive {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(blinking ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever(), value: blinking)

                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                if stateMachine.remainingSeconds > 0 {
                    Text(String(format: "%.0fs", stateMachine.remainingSeconds))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.85))
            .cornerRadius(20)
        }
    }

    @State private var blinking = false

    private var statusText: String {
        switch stateMachine.currentState {
        case .idleLive:          return "Live"
        case .recording:         return "● Aufnahme"
        case .transitioningToPlayback, .transitioningToLive: return "Überblendung…"
        case .playingBack:       return "Loop läuft"
        case .postPlaybackHold:  return "Loop beendet"
        }
    }

    private var statusColor: Color {
        switch stateMachine.currentState {
        case .idleLive:          return .blue
        case .recording:         return .red
        case .transitioningToPlayback, .transitioningToLive: return .yellow
        case .playingBack:       return .green
        case .postPlaybackHold:  return .orange
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Mom-friendly Control Panel
// ─────────────────────────────────────────────

public struct ControlBarView: View {
    @ObservedObject var stateMachine: AppStateMachine
    let obsInstalled: Bool
    let obsRunning: Bool
    let obsStatus: String?
    var onRestartOBS: () -> Void

    public init(stateMachine: AppStateMachine,
                obsInstalled: Bool,
                obsRunning: Bool,
                obsStatus: String? = nil,
                onRestartOBS: @escaping () -> Void) {
        self.stateMachine = stateMachine
        self.obsInstalled = obsInstalled
        self.obsRunning = obsRunning
        self.obsStatus = obsStatus
        self.onRestartOBS = onRestartOBS
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Tip bar — tells mom exactly what to do next
            HStack {
                Image(systemName: hintIcon)
                    .foregroundColor(hintColor)
                Text(hintText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().opacity(0.15)

            // Main controls
            HStack(spacing: 12) {

                // ── Step 1: Record ──────────────────────
                BigButton(
                    step: "1",
                    label: recordLabel,
                    sublabel: recordSub,
                    icon: recordIcon,
                    color: .red,
                    enabled: canRecord,
                    active: stateMachine.currentState == .recording
                ) {
                    stateMachine.handleHotkeyRecord()
                }

                // ── Step 2: Loop on/off ─────────────────
                BigButton(
                    step: "2",
                    label: playLabel,
                    sublabel: playSub,
                    icon: playIcon,
                    color: .green,
                    enabled: canPlay,
                    active: stateMachine.currentState == .playingBack
                ) {
                    stateMachine.handleHotkeyPlaybackToggle()
                }

                Divider().frame(height: 48).opacity(0.25)

                // ── Duration picker ─────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wie lang aufnehmen?")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    HStack(spacing: 6) {
                        ForEach([10.0, 20.0, 30.0, 60.0], id: \.self) { sec in
                            DurationChip(
                                label: sec == 60 ? "1 Min" : "\(Int(sec))s",
                                selected: stateMachine.recordingDuration == sec
                            ) { stateMachine.recordingDuration = sec }
                        }
                    }
                }

                Spacer()

                Divider().frame(height: 48).opacity(0.25)

                // ── OBS Virtual Camera ──────────────────
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Virtuelle Kamera")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    if let status = obsStatus {
                        Label(status, systemImage: "arrow.down.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                            .fixedSize()
                    } else if !obsInstalled {
                        SmallButton(label: "Einrichten", icon: "video.badge.plus", color: .purple) {
                            onRestartOBS()
                        }
                    } else if obsRunning {
                        Label("An – in Zoom \"OBS Virtual Camera\" wählen", systemImage: "video.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(.green)
                    } else {
                        SmallButton(label: "Einschalten", icon: "video.badge.plus", color: .purple) {
                            onRestartOBS()
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 0.5).foregroundColor(.white.opacity(0.12))
        }
    }

    // MARK: - State helpers

    private var canRecord: Bool { stateMachine.currentState == .idleLive }
    private var canPlay: Bool {
        switch stateMachine.currentState {
        case .recording: return false
        case .idleLive:  return stateMachine.hasRecording   // enabled after recording done
        default:         return true
        }
    }

    private var recordLabel: String {
        stateMachine.currentState == .recording ? "Läuft…" : "Aufnehmen"
    }
    private var recordSub: String {
        stateMachine.currentState == .recording
            ? String(format: "Noch %.0f Sek.", stateMachine.remainingSeconds)
            : "Nimm dich kurz auf"
    }
    private var recordIcon: String {
        stateMachine.currentState == .recording ? "record.circle.fill" : "record.circle"
    }

    private var playLabel: String {
        switch stateMachine.currentState {
        case .playingBack, .transitioningToPlayback: return "Loop stoppen"
        case .postPlaybackHold:                      return "Loop abspielen"
        default:                                     return "Loop abspielen"
        }
    }
    private var playSub: String {
        switch stateMachine.currentState {
        case .playingBack: return "Kamera zeigt den Loop"
        case .postPlaybackHold: return "Aufnahme fertig"
        default: return "Aufnahme als Loop zeigen"
        }
    }
    private var playIcon: String {
        switch stateMachine.currentState {
        case .playingBack, .transitioningToPlayback: return "stop.circle"
        default: return "play.circle"
        }
    }

    // MARK: - Hint bar

    private var hintText: String {
        switch stateMachine.currentState {
        case .idleLive:
            return "Druecke 'Aufnehmen' - du wirst kurz aufgenommen, dann laeuft der Loop in Zoom"
        case .recording:
            return "Aufnahme laeuft... bitte ruhig bleiben oder normal weitermachen :)"
        case .transitioningToPlayback:
            return "Ueberblendung... gleich siehst du in Zoom deinen Loop"
        case .playingBack:
            return "Loop ist aktiv - Zoom zeigt jetzt dein aufgenommenes Video. Druecke 'Loop stoppen' um live zu schalten"
        case .postPlaybackHold:
            return "Loop beendet. Druecke 'Loop abspielen' um ihn nochmal zu starten, oder warte - geht automatisch zurueck"
        case .transitioningToLive:
            return "Ueberblendung zurueck zu live..."
        }
    }

    private var hintIcon: String {
        switch stateMachine.currentState {
        case .idleLive:           return "hand.point.right"
        case .recording:          return "video.fill"
        case .transitioningToPlayback, .transitioningToLive: return "arrow.left.arrow.right"
        case .playingBack:        return "checkmark.circle"
        case .postPlaybackHold:   return "clock"
        }
    }

    private var hintColor: Color {
        switch stateMachine.currentState {
        case .idleLive:           return .blue
        case .recording:          return .red
        case .transitioningToPlayback, .transitioningToLive: return .yellow
        case .playingBack:        return .green
        case .postPlaybackHold:   return .orange
        }
    }
}

// MARK: - Subviews

private struct BigButton: View {
    let step: String
    let label: String
    let sublabel: String
    let icon: String
    let color: Color
    let enabled: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(enabled ? color.opacity(active ? 0.9 : 0.2) : Color.white.opacity(0.06))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(enabled ? (active ? .white : color) : color.opacity(0.25))
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Schritt \(step)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(enabled ? color.opacity(0.7) : color.opacity(0.25))
                        if active {
                            Text("● AKTIV")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(color)
                        }
                    }
                    Text(label)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(enabled ? .white : .white.opacity(0.3))
                    Text(sublabel)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(.white.opacity(enabled ? 0.5 : 0.2))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(active ? color.opacity(0.15) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? color.opacity(0.5) : (enabled ? color.opacity(0.2) : Color.clear),
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct SmallButton: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct DurationChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .bold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(selected ? .white : .gray)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Color.blue.opacity(0.5) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Color.blue.opacity(0.7) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

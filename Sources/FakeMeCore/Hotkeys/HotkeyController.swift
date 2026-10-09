import Foundation
import Cocoa

public final class HotkeyController {
    private var eventTap: CFMachPort?
    private let stateMachine: AppStateMachine
    private let keycodeF11 = CGKeyCode(103)
    private let keycodeF12 = CGKeyCode(111)

    public init(stateMachine: AppStateMachine) {
        self.stateMachine = stateMachine
    }

    public func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, eventType, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let controller = Unmanaged<HotkeyController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handleEvent(eventType, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else { return }
        self.eventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.eventTap = nil
    }

    private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if keycode == keycodeF11 {
            Task { @MainActor in
                self.stateMachine.handleHotkeyRecord()
            }
            return nil
        } else if keycode == keycodeF12 {
            Task { @MainActor in
                self.stateMachine.handleHotkeyPlaybackToggle()
            }
            return nil
        }

        return Unmanaged.passRetained(event)
    }
}

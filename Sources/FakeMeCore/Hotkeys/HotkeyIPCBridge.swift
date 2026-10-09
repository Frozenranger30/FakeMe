import Foundation

public final class HotkeyIPCBridge {
    private let notificationName_F11 = "com.fakeme.hotkey.f11"
    private let notificationName_F12 = "com.fakeme.hotkey.f12"
    private let stateMachine: AppStateMachine

    public init(stateMachine: AppStateMachine) {
        self.stateMachine = stateMachine
    }

    public func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleF11),
            name: NSNotification.Name(notificationName_F11),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleF12),
            name: NSNotification.Name(notificationName_F12),
            object: nil
        )
    }

    public func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleF11() {
        Task { @MainActor [weak self] in
            self?.stateMachine.handleHotkeyRecord()
        }
    }

    @objc private func handleF12() {
        Task { @MainActor [weak self] in
            self?.stateMachine.handleHotkeyPlaybackToggle()
        }
    }

    public func broadcastF11() {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(notificationName_F11),
            object: nil
        )
    }

    public func broadcastF12() {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(notificationName_F12),
            object: nil
        )
    }
}

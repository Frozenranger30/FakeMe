import Cocoa
import SwiftUI
import FakeMeCore
import FakeMeUI

// Holds the latest rendered frame for the SwiftUI preview
final class PreviewModel: ObservableObject {
    @Published var currentFrame: CVPixelBuffer?
}

// Pure video, no controls — this window is what OBS captures for the virtual camera
struct OutputView: View {
    @ObservedObject var preview: PreviewModel
    var body: some View {
        CameraPreviewView(pixelBuffer: preview.currentFrame)
            .background(Color.black)
    }
}

// Root view: camera preview + control bar + floating HUD overlay
struct MainContentView: View {
    @ObservedObject var preview: PreviewModel
    @ObservedObject var stateMachine: AppStateMachine
    @ObservedObject var obs: OBSIntegration
    var onRestartOBS: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                CameraPreviewView(pixelBuffer: preview.currentFrame)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FloatingHUDView(stateMachine: stateMachine)
                    .padding(16)
            }
            .background(Color.black)

            ControlBarView(
                stateMachine: stateMachine,
                obsInstalled: obs.obsInstalled,
                obsRunning: obs.cameraActive,
                obsStatus: obs.statusText,
                onRestartOBS: onRestartOBS
            )
        }
    }
}

@main
final class FakeMeAppDelegate: NSObject, NSApplicationDelegate {
    // Without a Nib/Storyboard we must wire up the delegate ourselves.
    static func main() {
        let app = NSApplication.shared
        let delegate = FakeMeAppDelegate()
        app.delegate = delegate
        app.run()
    }

    var mainWindow: NSWindow?
    var outputWindow: NSWindow?
    var settingsWindow: NSWindow?

    let stateMachine = AppStateMachine()
    let previewModel = PreviewModel()
    let pipeline: VideoPipeline
    let cameraProvider: CameraCaptureProvider
    let shmWriter = SharedMemoryWriter()
    var hotkeyController: HotkeyController?
    let obs = OBSIntegration()

    override init() {
        cameraProvider = CameraCaptureProvider()
        pipeline = VideoPipeline(frameProvider: cameraProvider)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        buildMainMenu()

        // Wire pipeline → state machine (drives state via onModeChanged)
        stateMachine.attachVideoPipeline(pipeline)

        // Open shared memory for DAL plugin
        shmWriter.open()

        // Wire pipeline → preview model + shared memory for virtual camera
        pipeline.onFrameRendered = { [weak self] buffer in
            self?.previewModel.currentFrame = buffer
            self?.shmWriter.write(buffer)
        }

        // Build main window
        let contentView = MainContentView(
            preview: previewModel,
            stateMachine: stateMachine,
            obs: obs,
            onRestartOBS: { [weak self] in self?.startVirtualCamera() }
        )
        let hostingController = NSHostingController(rootView: contentView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "FakeMe - Virtual Camera"
        win.contentViewController = hostingController
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("FakeMeMainWindow")
        win.contentMinSize = NSSize(width: 980, height: 620)  // must fully cover the output window
        if win.frame.width < 980 || win.frame.height < 620 {
            win.setContentSize(NSSize(width: 1100, height: 720))
        }
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.mainWindow = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: win, queue: .main) { _ in
            NSApp.terminate(nil)
        }

        buildOutputWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startVirtualCamera()
        }

        // Start hotkey listener (requires Accessibility permission)
        hotkeyController = HotkeyController(stateMachine: stateMachine)
        hotkeyController?.start()

        // Start camera pipeline
        Task {
            do {
                try await pipeline.start()
            } catch {
                await showCameraError(error)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func buildOutputWindow() {
        // OBS window-captures this (ScreenCaptureKit works for occluded windows).
        // 640x360 pt = 1280x720 px on Retina; borderless so only the video is captured.
        guard let main = mainWindow else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.title = "FakeMe Ausgabe"
        win.contentView = NSHostingView(rootView: OutputView(preview: previewModel))
        win.isReleasedWhenClosed = false
        win.hasShadow = false
        outputWindow = win

        // Not a child window: ScreenCaptureKit would capture the whole parent group.
        // Instead keep it independently parked right behind the main window.
        tuckOutputWindow()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
                self?.tuckOutputWindow()
            }
        }
    }

    private func tuckOutputWindow() {
        guard let main = mainWindow, let out = outputWindow else { return }
        let m = main.frame
        out.setFrameOrigin(NSPoint(x: m.midX - out.frame.width / 2, y: m.midY - out.frame.height / 2))
        out.order(.below, relativeTo: main.windowNumber)
    }

    private func startVirtualCamera() {
        guard let win = outputWindow else { return }
        guard obs.obsInstalled else {
            offerOBSInstall()
            return
        }
        obs.start(captureWindowID: win.windowNumber)
    }

    private func offerOBSInstall() {
        guard !obs.installing else { return }
        let alert = NSAlert()
        alert.messageText = "Virtuelle Kamera einrichten"
        alert.informativeText = """
        Damit Zoom, Teams und FaceTime das FakeMe-Bild sehen, braucht FakeMe das kostenlose \
        Programm OBS (ca. 200 MB).

        Soll FakeMe OBS jetzt herunterladen und installieren?
        """
        alert.addButton(withTitle: "Ja, installieren")
        alert.addButton(withTitle: "Später")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        obs.install { [weak self] ok in
            guard ok, let self else { return }
            let info = NSAlert()
            info.messageText = "OBS ist installiert – fast fertig!"
            info.informativeText = """
            Gleich öffnet sich OBS einmalig. Bitte:

            1. Bei allen Fragen von macOS auf „Erlauben" klicken \
            (vor allem „Bildschirmaufnahme").
            2. Wenn „Systemerweiterung" oder „Kameraerweiterung" erscheint: \
            in den Systemeinstellungen erlauben.

            Danach in Zoom die Kamera „OBS Virtual Camera" wählen. \
            Ab dem nächsten Start passiert das alles automatisch im Hintergrund.
            """
            info.runModal()
            self.startVirtualCamera()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        obs.stopIfLaunchedByUs()
        hotkeyController?.stop()
        shmWriter.close()
        Task { await pipeline.stop() }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About FakeMe", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit FakeMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Camera menu
        let cameraMenu = NSMenu(title: "Camera")
        cameraMenu.addItem(withTitle: "Start Recording (Fn+F11)", action: #selector(menuRecord), keyEquivalent: "")
        cameraMenu.addItem(withTitle: "Toggle Playback (Fn+F12)", action: #selector(menuPlayback), keyEquivalent: "")
        cameraMenu.addItem(.separator())
        cameraMenu.addItem(withTitle: "Reset", action: #selector(menuReset), keyEquivalent: "r")
        let cameraMenuItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraMenuItem.submenu = cameraMenu
        mainMenu.addItem(cameraMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: SettingsView(stateMachine: stateMachine))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "FakeMe Settings"
        win.contentViewController = controller
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
    }

    @objc func menuRecord() {
        Task { @MainActor in stateMachine.handleHotkeyRecord() }
    }

    @objc func menuPlayback() {
        Task { @MainActor in stateMachine.handleHotkeyPlaybackToggle() }
    }

    @objc func menuReset() {
        Task { @MainActor in
            pipeline.reset()
            stateMachine.handleHotkeyRecord()  // not ideal, but reset via pipeline
        }
    }

    // MARK: - Error handling

    @MainActor
    private func showCameraError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Camera Access Error"
        alert.informativeText = error.localizedDescription + "\n\nGo to System Settings → Privacy & Security → Camera to grant access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

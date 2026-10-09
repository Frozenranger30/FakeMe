import Foundation
import AppKit
import CryptoKit

/// Drives OBS as the virtual-camera backend: OBS window-captures FakeMe's output window
/// and publishes it as "OBS Virtual Camera" (OBS ships a signed Camera Extension).
final class OBSIntegration: ObservableObject {

    @Published var obsInstalled = false
    @Published var obsRunning = false
    /// OBS is running with our scene + virtual cam (we launched it)
    @Published var cameraActive = false
    /// Shown in the control bar while installing / on error
    @Published var statusText: String?
    @Published var installing = false

    private static let bundleID = "com.obsproject.obs-studio"
    private static let collectionName = "FakeMe"
    private static let profileName = "FakeMe"
    private var obsAppURL: URL?
    private var firstRun = false
    private var pollTimer: Timer?
    private var launchedByUs = false
    private var starting = false
    private var wsConfig: (port: Int, password: String)?
    private var wsTask: URLSessionWebSocketTask?

    private var obsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio")
    }

    init() {
        obsAppURL = Self.findOBS()
        obsInstalled = obsAppURL != nil
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.obsRunning = !Self.runningOBS().isEmpty
            if !self.obsRunning && !self.starting { self.launchedByUs = false }
            self.cameraActive = self.obsRunning && self.launchedByUs
        }
    }

    /// Starts OBS capturing the given window with its virtual camera on.
    /// No-op if our OBS instance is already running.
    func start(captureWindowID: Int) {
        guard obsInstalled else { return }
        if starting || (launchedByUs && !Self.runningOBS().isEmpty) { return }
        starting = true

        DispatchQueue.global().async { [weak self] in
            // OBS only honours launch arguments on a fresh start. A normal quit makes
            // OBS crash in its exit handlers (crash dialog), so kill it outright.
            Self.runningOBS().forEach { $0.forceTerminate() }
            let deadline = Date().addingTimeInterval(4)
            while !Self.runningOBS().isEmpty && Date() < deadline { usleep(200_000) }
            guard let self else { return }
            self.clearCrashSentinels()
            self.writeScene(windowID: captureWindowID)
            self.writeProfile()
            self.seedFirstRunConfig()
            self.wsConfig = self.enableWebSocket()
            DispatchQueue.main.async { self.launch() }
        }
    }

    /// Downloads + installs OBS, then runs `completion` on the main queue.
    func install(completion: @escaping (Bool) -> Void) {
        guard !installing else { return }
        installing = true
        statusText = "OBS wird geladen… 0 %"
        Task {
            do {
                let url = try await OBSInstaller().install { p in
                    DispatchQueue.main.async { [weak self] in
                        self?.statusText = p < 1 ? "OBS wird geladen… \(Int(p * 100)) %" : "OBS wird installiert…"
                    }
                }
                await MainActor.run {
                    self.obsAppURL = url
                    self.obsInstalled = true
                    self.firstRun = true
                    self.installing = false
                    self.statusText = nil
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    self.installing = false
                    self.statusText = "OBS-Installation fehlgeschlagen"
                    let alert = NSAlert()
                    alert.messageText = "OBS konnte nicht installiert werden"
                    alert.informativeText = error.localizedDescription
                        + "\n\nDu kannst es später über den Knopf \"Einschalten\" erneut versuchen."
                    alert.runModal()
                    completion(false)
                }
            }
        }
    }

    func stopIfLaunchedByUs() {
        guard launchedByUs else { return }
        Self.runningOBS().forEach { $0.forceTerminate() }
        launchedByUs = false
        usleep(300_000)
        clearCrashSentinels()
    }

    // MARK: - Private

    // MARK: - Camera extension approval (cannot be automated: macOS requires the user to flip the switch)

    enum ExtensionState { case enabled, waitingForUser, missing }

    static func cameraExtensionState() -> ExtensionState {
        let out = run("/usr/bin/systemextensionsctl", ["list"]).output
        guard let line = out.split(separator: "\n").first(where: {
            $0.contains("com.obsproject.obs-studio.mac-camera-extension")
        }) else { return .missing }
        if line.contains("[activated enabled]") { return .enabled }
        return line.contains("waiting for user") ? .waitingForUser : .missing
    }

    private var extensionTimer: Timer?
    private var extensionPromptShown = false

    /// Polls the extension state; guides the user to System Settings once if approval is pending.
    private func watchCameraExtension() {
        extensionTimer?.invalidate()
        extensionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            DispatchQueue.global().async {
                let state = Self.cameraExtensionState()
                DispatchQueue.main.async {
                    switch state {
                    case .enabled:
                        t.invalidate()
                        if self.statusText == Self.approveText {
                            self.statusText = nil
                            self.startVirtualCam(attempt: 0)   // approval just happened
                        }
                    case .waitingForUser:
                        self.statusText = Self.approveText
                        if !self.extensionPromptShown {
                            self.extensionPromptShown = true
                            self.promptExtensionApproval()
                        }
                    case .missing:
                        break   // OBS is still activating it
                    }
                }
            }
        }
    }

    private static let approveText = "Bitte Kameratreiber erlauben"

    private func promptExtensionApproval() {
        let alert = NSAlert()
        alert.messageText = "Ein letzter Klick: Kameratreiber erlauben"
        alert.informativeText = """
        macOS fragt aus Sicherheitsgründen, ob die virtuelle Kamera benutzt werden darf.

        Gleich öffnen sich die Systemeinstellungen. Dort bei „Kameraerweiterungen" \
        den Schalter neben „OBS Virtual Camera" einschalten (evtl. mit Passwort bestätigen).

        FakeMe merkt das automatisch und schaltet die Kamera dann ein.
        """
        alert.addButton(withTitle: "Einstellungen öffnen")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
    }

    private static func findOBS() -> URL? {
        // Never use a copy on a mounted DMG (/Volumes/...): the camera extension
        // can only be activated from an installed app.
        let candidates = [
            URL(fileURLWithPath: "/Applications/OBS.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OBS.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
        ]
        return candidates.compactMap { $0 }.first {
            !$0.path.hasPrefix("/Volumes/") && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func runningOBS() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    private func launch() {
        guard let obsAppURL else { starting = false; return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        var args = [
            "--collection", Self.collectionName,
            "--profile", Self.profileName,
            "--disable-shutdown-check",
        ]
        // On the very first run OBS must be visible so its permission dialog
        // (screen recording) and the camera-extension approval can be seen.
        if !firstRun { args.append("--minimize-to-tray") }
        cfg.activates = firstRun
        cfg.arguments = args
        NSWorkspace.shared.openApplication(at: obsAppURL, configuration: cfg) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.launchedByUs = app != nil
                self?.obsRunning = app != nil
                self?.cameraActive = app != nil
                self?.starting = false
                if app != nil {
                    self?.startVirtualCam(attempt: 0)
                    self?.watchCameraExtension()
                }
            }
        }
    }

    // MARK: - obs-websocket (v5) — "--startvirtualcam" is ignored while the camera extension is still activating

    private func enableWebSocket() -> (port: Int, password: String)? {
        let url = obsDir.appendingPathComponent("plugin_config/obs-websocket/config.json")
        var cfg = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var password = cfg["server_password"] as? String ?? ""
        if password.isEmpty {
            password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        cfg["server_enabled"] = true
        cfg["auth_required"] = true
        cfg["server_password"] = password
        cfg["alerts_enabled"] = false
        cfg["first_load"] = false
        let port = cfg["server_port"] as? Int ?? 4455
        cfg["server_port"] = port
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted),
              (try? data.write(to: url)) != nil else { return nil }
        return (port, password)
    }

    private func startVirtualCam(attempt: Int) {
        // first run: allow time for the user to approve the camera extension in System Settings
        guard let ws = wsConfig, attempt < (firstRun ? 300 : 30), launchedByUs else { return }
        let retry = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.startVirtualCam(attempt: attempt + 1) }
        }
        guard let url = URL(string: "ws://127.0.0.1:\(ws.port)") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()

        func send(_ obj: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: d, encoding: .utf8) else { return }
            task.send(.string(s)) { _ in }
        }

        func receive() {
            task.receive { [weak self] result in
                guard case .success(.string(let text)) = result,
                      let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let op = msg["op"] as? Int, let d = msg["d"] as? [String: Any] else {
                    task.cancel(with: .goingAway, reason: nil)
                    retry()
                    return
                }
                switch op {
                case 0: // Hello
                    var identify: [String: Any] = ["rpcVersion": 1]
                    if let auth = d["authentication"] as? [String: Any],
                       let challenge = auth["challenge"] as? String, let salt = auth["salt"] as? String {
                        identify["authentication"] = Self.wsAuth(password: ws.password, salt: salt, challenge: challenge)
                    }
                    send(["op": 1, "d": identify])
                    receive()
                case 2: // Identified
                    send(["op": 6, "d": ["requestType": "StartVirtualCam", "requestId": "fakeme-vcam"]])
                    receive()
                case 7: // RequestResponse
                    let status = d["requestStatus"] as? [String: Any]
                    let ok = status?["result"] as? Bool ?? false
                    let code = status?["code"] as? Int ?? 0
                    task.cancel(with: .normalClosure, reason: nil)
                    // 500 = output already running
                    if !ok && code != 500 { retry() } else {
                        DispatchQueue.main.async { self?.cameraActive = true; self?.firstRun = false }
                    }
                default:
                    receive()
                }
            }
        }
        receive()
    }

    private static func wsAuth(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    /// After a hard kill OBS finds its run sentinel and blocks startup with a (hidden) safe-mode dialog.
    private func clearCrashSentinels() {
        let dir = obsDir.appendingPathComponent(".sentinel")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix("run_") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Own profile so the user's OBS profiles are untouched: 1280x720 @ 30 fps.
    private func writeProfile() {
        let dir = obsDir.appendingPathComponent("basic/profiles/\(Self.profileName)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ini = """
        [General]
        Name=\(Self.profileName)

        [Video]
        BaseCX=1280
        BaseCY=720
        OutputCX=1280
        OutputCY=720
        FPSType=0
        FPSCommon=30

        """
        try? ini.write(to: dir.appendingPathComponent("basic.ini"), atomically: true, encoding: .utf8)
    }

    /// Fresh OBS installs show an auto-configuration wizard; mark it as done.
    private func seedFirstRunConfig() {
        let userIni = obsDir.appendingPathComponent("user.ini")
        let globalIni = obsDir.appendingPathComponent("global.ini")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: userIni.path), !fm.fileExists(atPath: globalIni.path) else { return }
        try? fm.createDirectory(at: obsDir, withIntermediateDirectories: true)
        let text = """
        [General]
        FirstRun=true
        Pre19Defaults=false
        Pre21Defaults=false
        Pre23Defaults=false
        Pre24.1Defaults=false
        ConfirmOnExit=false

        [Basic]
        Profile=\(Self.profileName)
        ProfileDir=\(Self.profileName)
        SceneCollection=\(Self.collectionName)
        SceneCollectionFile=\(Self.collectionName).json

        [BasicWindow]
        SysTrayEnabled=true

        """
        try? text.write(to: userIni, atomically: true, encoding: .utf8)
    }

    private func writeScene(windowID: Int) {
        let scenesDir = obsDir.appendingPathComponent("basic/scenes")
        try? FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
        let sourceUUID = UUID().uuidString.lowercased()
        let sceneUUID = UUID().uuidString.lowercased()
        let sourceName = "FakeMe Ausgabe"

        let common: [String: Any] = [
            "mixers": 0, "sync": 0, "volume": 1.0, "balance": 0.5,
            "enabled": true, "muted": true,
            "push-to-mute": false, "push-to-mute-delay": 0,
            "push-to-talk": false, "push-to-talk-delay": 0,
            "hotkeys": [String: Any](), "deinterlace_mode": 0,
            "deinterlace_field_order": 0, "monitoring_type": 0,
            "private_settings": [String: Any](),
        ]

        var source = common
        source["name"] = sourceName
        source["uuid"] = sourceUUID
        source["id"] = "screen_capture"
        source["versioned_id"] = "screen_capture"
        source["flags"] = 0
        source["settings"] = [
            "type": 1,              // 1 = single window (ScreenCaptureKit)
            "window": windowID,
            "show_cursor": false,
            "show_hidden_windows": true,
        ] as [String: Any]

        var scene = common
        scene["name"] = Self.collectionName
        scene["uuid"] = sceneUUID
        scene["id"] = "scene"
        scene["versioned_id"] = "scene"
        scene["flags"] = 0
        scene["settings"] = [
            "id_counter": 1,
            "items": [[
                "name": sourceName,
                "source_uuid": sourceUUID,
                "id": 1,
                "visible": true, "locked": true,
                "rot": 0.0,
                "pos": ["x": 0.0, "y": 0.0],
                "scale": ["x": 1.0, "y": 1.0],
                "align": 5,
                "bounds_type": 2,   // scale to fit inside bounds
                "bounds_align": 0,
                "bounds": ["x": 1280.0, "y": 720.0],
                "crop_top": 0, "crop_right": 0, "crop_bottom": 0, "crop_left": 0,
                "scale_filter": "disable",
                "blend_method": "default",
                "blend_type": "normal",
            ]],
        ] as [String: Any]

        let collection: [String: Any] = [
            "name": Self.collectionName,
            "current_scene": Self.collectionName,
            "current_program_scene": Self.collectionName,
            "scene_order": [["name": Self.collectionName]],
            "sources": [source, scene],
            "groups": [Any](),
            "modules": [String: Any](),
            "saved_projectors": [Any](),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: collection, options: .prettyPrinted) {
            try? data.write(to: scenesDir.appendingPathComponent("\(Self.collectionName).json"))
        }
    }
}

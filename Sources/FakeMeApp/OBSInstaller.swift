import Foundation

/// Downloads the official OBS Studio DMG from GitHub, verifies its Developer ID signature
/// and copies OBS.app into /Applications (or ~/Applications if not writable).
final class OBSInstaller: NSObject, URLSessionDownloadDelegate {

    enum InstallError: LocalizedError {
        case noRelease, download(String), mount, notFound, badSignature, copy(String)
        var errorDescription: String? {
            switch self {
            case .noRelease:        return "Die OBS-Version konnte nicht gefunden werden (keine Internetverbindung?)."
            case .download(let m):  return "Download fehlgeschlagen: \(m)"
            case .mount:            return "Die OBS-Datei konnte nicht geöffnet werden."
            case .notFound:         return "OBS.app wurde in der Datei nicht gefunden."
            case .badSignature:     return "Die heruntergeladene Datei ist nicht das echte OBS – Installation abgebrochen."
            case .copy(let m):      return "OBS konnte nicht installiert werden: \(m)"
            }
        }
    }

    static let obsTeamID = "2MMRE5MTB8"   // Wizards of OBS LLC

    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Returns the installed OBS.app URL.
    func install(progress: @escaping (Double) -> Void) async throws -> URL {
        progressHandler = progress
        let dmgURL = try await latestDMGURL()
        let dmg = try await download(dmgURL)
        defer { try? FileManager.default.removeItem(at: dmg) }
        return try installApp(fromDMG: dmg)
    }

    // MARK: - Steps

    private func latestDMGURL() async throws -> URL {
        let api = URL(string: "https://api.github.com/repos/obsproject/obs-studio/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { throw InstallError.noRelease }

        #if arch(arm64)
        let archTag = "macos-apple.dmg"
        #else
        let archTag = "macos-intel.dmg"
        #endif
        for asset in assets {
            if let name = (asset["name"] as? String)?.lowercased(), name.hasSuffix(archTag),
               let s = asset["browser_download_url"] as? String, let url = URL(string: s),
               url.host == "github.com" {
                return url
            }
        }
        throw InstallError.noRelease
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    private func installApp(fromDMG dmg: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("fakeme-obs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                        "-noautoopen", "-mountpoint", mount.path]).status == 0 else {
            throw InstallError.mount
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }

        let source = mount.appendingPathComponent("OBS.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw InstallError.notFound }
        guard Self.isGenuineOBS(source) else { throw InstallError.badSignature }

        let systemApps = URL(fileURLWithPath: "/Applications")
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let targetDir = FileManager.default.isWritableFile(atPath: systemApps.path) ? systemApps : userApps
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = targetDir.appendingPathComponent("OBS.app")

        let r = run("/usr/bin/ditto", [source.path, target.path])
        guard r.status == 0 else { throw InstallError.copy(r.output) }
        guard Self.isGenuineOBS(target) else {
            try? FileManager.default.removeItem(at: target)
            throw InstallError.badSignature
        }
        return target
    }

    static func isGenuineOBS(_ app: URL) -> Bool {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { return false }
        let info = run("/usr/bin/codesign", ["-dv", app.path])
        return info.output.contains("TeamIdentifier=\(obsTeamID)")
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it first
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("OBS-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: InstallError.download(error.localizedDescription))
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let cont = continuation else { return }
        continuation = nil
        cont.resume(throwing: InstallError.download(error.localizedDescription))
        session.finishTasksAndInvalidate()
    }
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

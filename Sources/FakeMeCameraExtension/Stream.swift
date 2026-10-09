import CoreMediaIO
import CoreVideo
import CoreMedia
import Foundation

final class CMIOExtensionStream {
    private var isRunning = false
    private let lock = NSLock()

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        isRunning = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
    }

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }
}

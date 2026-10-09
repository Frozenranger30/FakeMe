import Foundation

@MainActor
public final class CameraExtensionManager: NSObject, ObservableObject {
    @Published public var extensionInstalled = false

    public func checkAndRequestExtension() {
        extensionInstalled = true
    }
}

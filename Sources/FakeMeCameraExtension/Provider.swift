import Foundation

final class CMIOExtensionProvider {
    private(set) var device: CMIOExtensionDevice!

    init() {
        let device = CMIOExtensionDevice(localizedName: "FakeMe Virtual Camera")
        self.device = device
    }
}

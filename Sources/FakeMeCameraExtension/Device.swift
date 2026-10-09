import Foundation

final class CMIOExtensionDevice {
    let deviceID: UInt64
    let localizedName: String
    let stream: CMIOExtensionStream

    init(localizedName: String) {
        self.localizedName = localizedName
        self.deviceID = UInt64.random(in: 0...UInt64.max)
        self.stream = CMIOExtensionStream()
    }
}

import SwiftUI

@main
struct SoundBridgePhoneApp: App {
    @State private var mpcService = MPCService(displayName: UIDevice.current.name)

    var body: some Scene {
        WindowGroup {
            SpeakerView(mpcService: mpcService)
        }
    }
}

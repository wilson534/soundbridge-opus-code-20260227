import SwiftUI

@main
struct SoundBridgePadApp: App {
    @State private var mpcService = MPCService(displayName: UIDevice.current.name)

    var body: some Scene {
        WindowGroup {
            DisplayView(mpcService: mpcService)
                .onAppear {
                    mpcService.startAdvertising()
                }
        }
    }
}

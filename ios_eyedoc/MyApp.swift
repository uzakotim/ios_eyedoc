import SwiftUI

@main
struct EyeDocApp: App {
    @State private var cameraManager = BlinkCameraManager()

    var body: some Scene {
        WindowGroup {
            BlinkMonitorView()
                .environment(cameraManager)
        }
    }
}

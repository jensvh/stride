import SwiftUI

@main
struct ProbeApp: App {
    @StateObject private var probe = Probe()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(probe)
                .preferredColorScheme(.dark)
                .tint(Color(red: 1.0, green: 0.72, blue: 0.42))
                // stride://pair?r=… from the QR code that `npm run pair` shows.
                .onOpenURL { probe.pair($0) }
        }
    }
}

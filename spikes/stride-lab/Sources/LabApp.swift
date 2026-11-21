import MWDATCore
import SwiftUI

@main
struct LabApp: App {
    @StateObject private var lab: Lab

    init() {
        // The toolkit must be configured once, before anything else uses it.
        do { try Wearables.configure() } catch { print("Wearables.configure failed: \(error)") }
        _lab = StateObject(wrappedValue: Lab())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(lab)
                .environmentObject(lab.results)
                .environmentObject(lab.settings)
                .environmentObject(lab.audio)
                .environmentObject(lab.stt)
                .environmentObject(lab.glasses)
                .environmentObject(lab.glasses.display)
                .onOpenURL { url in lab.open(url) }
                .preferredColorScheme(.dark)
        }
    }
}

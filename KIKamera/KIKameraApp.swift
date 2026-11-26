import SwiftUI

@main
struct KIKameraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

extension Color {
    static let kAccent = Color(red: 1.0, green: 0.624, blue: 0.263)
    static let kBG = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let kPanel = Color(red: 0.086, green: 0.094, blue: 0.11)
    static let kLine = Color(red: 0.2, green: 0.212, blue: 0.239)
    static let kMuted = Color(red: 0.608, green: 0.631, blue: 0.671)
    static let kRec = Color(red: 0.898, green: 0.282, blue: 0.302)
}

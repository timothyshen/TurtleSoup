import SwiftUI
import FirebaseCore

@main
struct TurtleSoupApp: App {

    @State private var authService = AuthService()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authService)
        }
        Settings {
            SettingsView(authService: authService)
        }
    }
}

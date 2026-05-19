import SwiftUI
import FirebaseCore

@main
struct TurtleSoupApp: App {

    // Declared without an initializer so its construction can be deferred
    // until after FirebaseApp.configure() runs in `init()`. Stored property
    // initializers fire BEFORE the body of `init`, which would otherwise
    // mean AuthService() hits `Auth.auth().currentUser` before Firebase is
    // configured — runtime warning + nil user state.
    @State private var authService: AuthService

    init() {
        FirebaseApp.configure()
        _authService = State(initialValue: AuthService())
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

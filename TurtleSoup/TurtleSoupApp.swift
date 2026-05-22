import SwiftUI
import FirebaseCore
#if os(iOS)
import UIKit
#endif

@main
struct TurtleSoupApp: App {

    // Declared without an initializer so its construction can be deferred
    // until after FirebaseApp.configure() runs in `init()`. Stored property
    // initializers fire BEFORE the body of `init`, which would otherwise
    // mean AuthService() hits `Auth.auth().currentUser` before Firebase is
    // configured — runtime warning + nil user state.
    @State private var authService: AuthService
    @State private var roomService: RoomService
    @State private var hostAdjudicator: HostAdjudicator

    init() {
        FirebaseApp.configure()

        // (No UITabBarAppearance tweak here — RootView now uses a
        // hand-rolled tab bar instead of system TabView on iOS, because
        // iOS 26's new Liquid Glass TabView wraps tab content in a
        // rounded sheet that can't be turned off via appearance API.)

        let auth = AuthService()
        _authService = State(initialValue: auth)
        // RoomService is App-owned so its Firestore listeners survive view
        // re-creation (e.g. tab switches that rebuild RootView's children).
        // Init order matters: AuthService must exist first so RoomService
        // can capture it as a dependency.
        let room = RoomService(auth: auth)
        _roomService = State(initialValue: room)
        // HostAdjudicator also App-owned: when the host's UI navigates
        // lobby → active → finished, the underlying watch loop must keep
        // running. Building it here means it's alive for the whole app
        // session; HostAdjudicator.start() / stop() control whether the
        // observation task is actually consuming events.
        let claudeConfig = ClaudeService.Config(baseURL: AppConfig.proxyBaseURL) { [auth] in
            try await auth.getIDToken()
        }
        _hostAdjudicator = State(initialValue: HostAdjudicator(roomService: room, claudeConfig: claudeConfig))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(roomService)
                .environment(hostAdjudicator)
        }
        #if os(macOS)
        // macOS-only: ⌘, opens this scene. iOS exposes settings via a sheet
        // off the sidebar footer instead (see SidebarView.apiKeyFooter).
        Settings {
            SettingsView(authService: authService)
        }
        #endif
    }
}

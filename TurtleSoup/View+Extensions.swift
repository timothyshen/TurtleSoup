import SwiftUI

extension View {

    /// On iOS, switches the navigation bar to inline (small) title mode.
    /// On macOS this concept doesn't exist (titles are window chrome), so
    /// it's a no-op.
    ///
    /// **Why this exists:** SwiftUI's default on iOS is Large Title mode,
    /// which reserves ~140pt of vertical space above the actual content
    /// AND routes the title text through a special renderer where some
    /// Unicode glyphs (notably the 🐢 emoji in our app title) get replaced
    /// with SF Symbol fallbacks and end up as generic "?" boxes. Inline
    /// mode renders titles at body-text size in the standard nav bar,
    /// which is both spatially efficient and emoji-correct.
    ///
    /// Apply at every `.navigationTitle(...)` site by adding
    /// `.inlineNavTitleOnIOS()` directly after.
    @ViewBuilder
    func inlineNavTitleOnIOS() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

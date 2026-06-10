import SwiftUI

// MARK: - Design tokens
//
// The codebase had drifted into five shades of gray
// (secondary.opacity(0.04/0.06/0.08/0.12/0.15)) and six corner radii.
// Two semantic surface colors cover every real use case:
//
//   cardBackground  — passive containers: stat cards, list cards, banners
//   inputBackground — interactive wells: search fields, text inputs
//
// Corner radii convention (applied at call sites, not enforced here):
//   8  — controls and inputs
//   12 — cards and panels

extension Color {
    /// Passive container surface (stat cards, turn rows, banners).
    static let cardBackground = Color.secondary.opacity(0.06)
    /// Interactive input surface (search fields, text wells).
    static let inputBackground = Color.secondary.opacity(0.12)
}

// MARK: - Shared inline search field
//
// Used by 题库 and 历史 tabs on iOS, and the macOS sidebar. We can't use
// .searchable on the iOS tab roots: their nav bars are hidden
// (.toolbar(.hidden, for: .navigationBar)) so the system search bar has
// nowhere to render. One shared component keeps the two tabs identical.

struct InlineSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.inputBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

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

import SwiftUI

struct MessageBubble: View {

    let message: Message

    var body: some View {
        switch message.role {
        case .system:
            systemBubble
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        }
    }

    // MARK: - System

    private var systemBubble: some View {
        Text(message.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
    }

    // MARK: - User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(BubbleShape(isUser: true))
        }
    }

    // MARK: - Assistant

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            // 判定徽章
            if let verdict = message.verdict {
                verdictBadge(verdict)
            }
            // 补充说明
            if !message.text.isEmpty && message.text != message.verdict?.label {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(BubbleShape(isUser: false))
            }
            Spacer(minLength: 60)
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: Message.Verdict) -> some View {
        let config = badgeConfig(verdict)
        Text(verdict.label)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(config.bg)
            .foregroundStyle(config.fg)
            .clipShape(BubbleShape(isUser: false))
    }

    private func badgeConfig(_ v: Message.Verdict) -> (bg: Color, fg: Color) {
        switch v {
        case .yes:  return (.green.opacity(0.15), .green)
        case .no:   return (.red.opacity(0.15), .red)
        case .irr:  return (Color(.secondarySystemBackground), .secondary)
        case .part: return (.orange.opacity(0.15), .orange)
        case .win:  return (.teal.opacity(0.15), .teal)
        }
    }
}

// MARK: - Bubble shape

struct BubbleShape: Shape {
    let isUser: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16
        let tr: CGFloat = isUser ? 4 : r
        let tl: CGFloat = isUser ? r : 4
        return Path(roundedRect: rect,
                    cornerRadii: .init(topLeading: tl, bottomLeading: r,
                                       bottomTrailing: r, topTrailing: tr))
    }
}

// MARK: - Typing indicator
//
// Non-streaming model calls return after the full JSON verdict is built — the
// user sees nothing for the full ~1–4 s round trip. Three idle dots in that
// window feel mechanical and stuck; cycling a short caption beside them
// reframes the wait as the host actively thinking. Captions are deliberately
// vague (no "正在调用 API"-style telemetry leak) and rotate slower than the
// dots so the eye doesn't fight two animations at once.

struct TypingIndicator: View {
    @State private var phase = 0
    @State private var captionIndex = 0

    private let dotTimer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    private let captionTimer = Timer.publish(every: 1.6, on: .main, in: .common).autoconnect()

    private let captions = [
        "翻阅汤底…",
        "斟酌答复…",
        "比对线索…",
        "审视提问…"
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(phase == i ? Color.primary : Color.secondary.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(BubbleShape(isUser: false))

            // Cross-fade caption: changing .id forces a transition between
            // identities, which lets .opacity actually fade rather than snap.
            Text(captions[captionIndex])
                .font(.caption)
                .foregroundStyle(.secondary)
                .id(captionIndex)
                .transition(.opacity)

            Spacer()
        }
        .onReceive(dotTimer) { _ in phase = (phase + 1) % 3 }
        .onReceive(captionTimer) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                captionIndex = (captionIndex + 1) % captions.count
            }
        }
    }
}

// MARK: - Previews

#Preview("TypingIndicator") {
    TypingIndicator()
        .padding()
        .frame(width: 360)
}

/// Catalog of message variants: user, all 5 verdicts on assistant rows,
/// and a system bootstrap line. Lets us eyeball badge colors and bubble
/// alignment without playing a real game.
#Preview("MessageBubble — all variants") {
    VStack(spacing: 4) {
        MessageBubble(message: Message(role: .system,
                                       text: "游戏开始——你可以用陈述或问句来探索真相"))
        MessageBubble(message: Message(role: .user, text: "他认识凶手吗？"))
        MessageBubble(message: Message(role: .assistant, text: "是", verdict: .yes))
        MessageBubble(message: Message(role: .user, text: "他还活着吗？"))
        MessageBubble(message: Message(role: .assistant, text: "否", verdict: .no))
        MessageBubble(message: Message(role: .user, text: "今天天气好吗？"))
        MessageBubble(message: Message(role: .assistant, text: "无关", verdict: .irr))
        MessageBubble(message: Message(role: .user, text: "他是为了纪念某个人？"))
        MessageBubble(message: Message(role: .assistant, text: "方向对了", verdict: .part))
        MessageBubble(message: Message(role: .user,
                                       text: "他每天延后是因为亡妻"))
        MessageBubble(message: Message(role: .assistant, text: "完全猜中", verdict: .win))
    }
    .padding()
    .frame(width: 480)
}

/// "Mid-stream" assistant bubble: verdict has arrived (badge renders)
/// but comment text hasn't filled in yet. Mirrors what GameViewModel
/// produces between .verdictReady and .complete events.
#Preview("MessageBubble — verdict-only placeholder") {
    VStack(spacing: 4) {
        MessageBubble(message: Message(role: .user, text: "他在等谁？"))
        MessageBubble(message: Message(role: .assistant, text: "", verdict: .yes))
    }
    .padding()
    .frame(width: 480)
}

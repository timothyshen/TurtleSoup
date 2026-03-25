import Foundation

// MARK: - Puzzle

struct Puzzle: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var difficulty: Difficulty
    var scenario: String   // 汤面（玩家可见）
    var answer: String     // 汤底（仅注入 system prompt，不展示）
    var hint: String?
    var author: String
    var playCount: Int

    enum Difficulty: String, Codable, CaseIterable {
        case easy = "简单"
        case medium = "中等"
        case hard = "困难"

        var color: String {
            switch self {
            case .easy:   return "teal"
            case .medium: return "orange"
            case .hard:   return "red"
            }
        }
    }

    static let builtIn: [Puzzle] = [
        Puzzle(
            id: UUID(),
            title: "海边餐厅",
            difficulty: .hard,
            scenario: "一个男人走进一家海边餐厅，点了一碗海龟汤。喝了一口后，他走出餐厅，回家开枪自杀了。",
            answer: """
            这个男人曾经在一次海难中与妻子同乘救生筏。食物耗尽后，船员给了他一碗"海龟汤"让他活命，妻子却死了。
            他一直以为喝的是真正的海龟汤。多年后在餐厅喝到真正的海龟汤，味道完全不同，
            他这才意识到当年船员给他的其实是妻子的肉。无法承受这个真相，他选择了自杀。
            """,
            author: "经典题",
            playCount: 9999
        ),
        Puzzle(
            id: UUID(),
            title: "电梯里的秘密",
            difficulty: .easy,
            scenario: "一个住在30楼的男人，每天早上乘电梯下楼，但回家时只坐到20楼，然后走楼梯爬10层。为什么？",
            answer: """
            这个男人是矮子，身高不够，无法按到30楼的按钮，只能按到20楼。
            早上下楼按1楼没问题。如果有同乘者他会请人帮按，雨天带伞也可以用伞顶到30楼按钮。
            """,
            author: "经典题",
            playCount: 8888
        )
    ]
}

// MARK: - Message

struct Message: Identifiable {
    let id: UUID
    let role: Role
    let text: String
    var verdict: Verdict?
    let timestamp: Date

    enum Role: String {
        case user      = "user"
        case assistant = "assistant"
        case system    = "system"
    }

    enum Verdict: String, Codable {
        case yes   = "yes"
        case no    = "no"
        case irr   = "irr"
        case part  = "part"
        case win   = "win"

        var label: String {
            switch self {
            case .yes:  return "是"
            case .no:   return "否"
            case .irr:  return "无关"
            case .part: return "部分正确"
            case .win:  return "解谜成功 🎉"
            }
        }

        var color: String {
            switch self {
            case .yes:  return "green"
            case .no:   return "red"
            case .irr:  return "gray"
            case .part: return "orange"
            case .win:  return "teal"
            }
        }
    }

    init(role: Role, text: String, verdict: Verdict? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.verdict = verdict
        self.timestamp = Date()
    }
}

// MARK: - Claude API response

struct ClaudeAgentResponse: Decodable {
    let verdict: String
    let comment: String
}

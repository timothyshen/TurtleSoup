import SwiftUI

// MARK: - Multiplayer Rooms — UI Layer
//
// This file holds the SwiftUI views for the multiplayer rooms feature.
// Co-locating them keeps the create / join / lobby flow easy to read as a
// single state machine; each phase is one section in the file.
//
// View hierarchy:
//
//   Sidebar tab ".room"
//     ├── RoomSidebarView           ← pre-room: create + join buttons
//     │                                in-room:  status + leave
//
//   Detail pane (RootView .room branch)
//     └── MultiplayerDetailView     ← switches by RoomService state
//           ├── RoomEntryEmptyView  ← no room joined yet
//           ├── LobbyView           ← room.status == .waiting
//           ├── RoomActiveView      ← room.status == .running  (M7/M8, stub)
//           └── RoomFinishedView    ← room.status == .finished (M9, stub)
//
//   Modally:
//     ├── CreateRoomSheet
//     └── JoinRoomSheet

// MARK: - Sidebar

struct RoomSidebarView: View {

    @Environment(RoomService.self) private var roomService
    @Environment(AuthService.self) private var authService

    @State private var showCreateSheet = false
    @State private var showJoinSheet   = false

    var body: some View {
        VStack(spacing: 0) {
            if let room = roomService.room {
                inRoomStatus(room)
            } else if !authService.isSignedIn {
                notSignedInPrompt
            } else {
                entryButtons
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .sheet(isPresented: $showCreateSheet) { CreateRoomSheet() }
        .sheet(isPresented: $showJoinSheet)   { JoinRoomSheet() }
    }

    // MARK: pre-room — entry buttons

    private var entryButtons: some View {
        VStack(spacing: 10) {
            Button {
                showCreateSheet = true
            } label: {
                Label("创建房间", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button {
                showJoinSheet = true
            } label: {
                Label("加入房间", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)

            Text("现场多人海龟汤。一人作主持人（创建房间，主持人本地持有汤底并裁决），其他人输入 6 位房间码加入提问。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    // MARK: in-room — current status + leave

    @ViewBuilder
    private func inRoomStatus(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.tint)
                Text(room.code)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .tracking(2)
                Spacer()
                Text(roomStatusLabel(room.status))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor(room.status).opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor(room.status))
            }
            Text(room.mode.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(roomService.participants.count) 位玩家")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                Task { try? await roomService.leaveRoom() }
            } label: {
                Label("离开房间", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var notSignedInPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("登录后才能玩多人房间")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func roomStatusLabel(_ s: Room.Status) -> String {
        switch s {
        case .waiting:  return "等待开始"
        case .running:  return "游戏中"
        case .finished: return "已结束"
        }
    }

    private func statusColor(_ s: Room.Status) -> Color {
        switch s {
        case .waiting:  return .orange
        case .running:  return .green
        case .finished: return .secondary
        }
    }
}

// MARK: - Detail pane

struct MultiplayerDetailView: View {

    @Environment(RoomService.self) private var roomService
    @Environment(HostAdjudicator.self) private var adjudicator
    @Environment(AuthService.self) private var authService

    var publicStore: PublicPuzzleStore
    @Bindable var puzzleStore: PuzzleStore

    private var isHost: Bool {
        guard let room = roomService.room, let uid = authService.uid else { return false }
        return room.hostUid == uid
    }

    var body: some View {
        Group {
            if let room = roomService.room {
                switch room.status {
                case .waiting:
                    LobbyView(publicStore: publicStore, puzzleStore: puzzleStore)
                case .running:
                    RoomActiveView(publicStore: publicStore, puzzleStore: puzzleStore)
                case .finished:
                    RoomFinishedView()
                }
            } else {
                RoomEntryEmptyView()
            }
        }
        .navigationTitle(roomService.room.map { "房间 \($0.code)" } ?? "联机房间")
        .inlineNavTitleOnIOS()
        .onChange(of: roomService.room?.status) { _, newStatus in
            // Host's adjudicator should only run during .running. Toggle
            // here so we don't spin a watch loop in lobby/finished.
            if isHost {
                if newStatus == .running { adjudicator.start() }
                else                    { adjudicator.stop()  }
            }
        }
        .alert("房间出错", isPresented: Binding(
            get: { roomService.lastError != nil },
            set: { if !$0 { roomService.lastError = nil } }
        )) {
            Button("好") { roomService.lastError = nil }
        } message: {
            Text(roomService.lastError ?? "")
        }
        .alert("裁决错误", isPresented: Binding(
            get: { isHost && adjudicator.lastError != nil },
            set: { if !$0 { adjudicator.lastError = nil } }
        )) {
            Button("好") { adjudicator.lastError = nil }
        } message: {
            Text(adjudicator.lastError ?? "")
        }
    }
}

// MARK: - Empty state (no room joined)

struct RoomEntryEmptyView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("还没有进入房间")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("在左侧创建房间或输入房间码加入")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Create Room Sheet

struct CreateRoomSheet: View {

    @Environment(RoomService.self) private var roomService
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Room.Mode = .party
    @State private var maxRounds: Int = 5
    @State private var rotation: Room.Settings.Rotation = .sequential
    @State private var displayName: String = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("玩家名称") {
                TextField("显示名", text: $displayName)
                    .textContentType(.nickname)
                    .onAppear {
                        if displayName.isEmpty {
                            displayName = authService.displayName
                        }
                    }
            }

            Section("模式") {
                Picker("模式", selection: $mode) {
                    ForEach(Room.Mode.allCases, id: \.self) { m in
                        VStack(alignment: .leading) {
                            Text(m.label)
                            Text(m.subtitle).font(.caption).foregroundStyle(.secondary)
                        }.tag(m)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if mode == .party {
                Section("派对模式设置") {
                    Stepper(value: $maxRounds, in: 3...10) {
                        HStack {
                            Text("总轮数")
                            Spacer()
                            Text("\(maxRounds)").foregroundStyle(.secondary)
                        }
                    }
                    Picker("出题人轮换", selection: $rotation) {
                        ForEach(Room.Settings.Rotation.allCases, id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }

            Section {
                Button {
                    Task { await createTapped() }
                } label: {
                    if isCreating {
                        HStack { ProgressView().controlSize(.small); Text("创建中…") }
                    } else {
                        Text("创建房间").bold().frame(maxWidth: .infinity)
                    }
                }
                .disabled(isCreating || displayName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("取消", role: .cancel) { dismiss() }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
        .navigationTitle("创建房间")
        .inlineNavTitleOnIOS()
    }

    @MainActor
    private func createTapped() async {
        isCreating = true
        error = nil
        let settings = Room.Settings(maxRounds: maxRounds, questionerRotation: rotation)
        do {
            _ = try await roomService.createRoom(
                mode: mode,
                settings: settings,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}

// MARK: - Join Room Sheet

struct JoinRoomSheet: View {

    @Environment(RoomService.self) private var roomService
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var rawCode: String = ""
    @State private var displayName: String = ""
    @State private var isJoining = false
    @State private var error: String?

    private var normalizedCode: String? { RoomCode.normalize(rawCode) }

    var body: some View {
        Form {
            Section("房间码") {
                TextField("6 位字母数字", text: $rawCode)
                    .textContentType(.oneTimeCode)   // gets numeric+letter keyboard on iOS
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .font(.system(.title2, design: .monospaced))
                    .onChange(of: rawCode) { _, new in
                        // Live-uppercase + strip whitespace for the cleanest UX.
                        let cleaned = new
                            .uppercased()
                            .filter { !$0.isWhitespace }
                        if cleaned != rawCode { rawCode = cleaned }
                    }
            }

            Section("玩家名称") {
                TextField("显示名", text: $displayName)
                    .textContentType(.nickname)
                    .onAppear {
                        if displayName.isEmpty {
                            displayName = authService.displayName
                        }
                    }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }

            Section {
                Button {
                    Task { await joinTapped() }
                } label: {
                    if isJoining {
                        HStack { ProgressView().controlSize(.small); Text("加入中…") }
                    } else {
                        Text("加入房间").bold().frame(maxWidth: .infinity)
                    }
                }
                .disabled(isJoining
                          || normalizedCode == nil
                          || displayName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("取消", role: .cancel) { dismiss() }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 420, height: 380)
        #endif
        .navigationTitle("加入房间")
        .inlineNavTitleOnIOS()
    }

    @MainActor
    private func joinTapped() async {
        guard let code = normalizedCode else { return }
        isJoining = true
        error = nil
        do {
            try await roomService.joinRoom(
                code: code,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isJoining = false
    }
}

// MARK: - Lobby

struct LobbyView: View {

    @Environment(RoomService.self) private var roomService
    @Environment(AuthService.self) private var authService
    @Environment(HostAdjudicator.self) private var adjudicator

    var publicStore: PublicPuzzleStore
    @Bindable var puzzleStore: PuzzleStore

    @State private var showPuzzlePicker = false

    private var isHost: Bool {
        guard let room = roomService.room, let uid = authService.uid else { return false }
        return room.hostUid == uid
    }

    var body: some View {
        VStack(spacing: 0) {
            roomHeader
            Divider()
            participantsList
            if isHost {
                Divider()
                hostControls
            }
        }
        .sheet(isPresented: $showPuzzlePicker) {
            PuzzlePickerSheet(publicStore: publicStore, puzzleStore: puzzleStore) { picked in
                Task { await startRound(with: picked) }
            }
        }
    }

    @MainActor
    private func startRound(with puzzle: Puzzle) async {
        guard let room = roomService.room else { return }
        // Pick the first questioner. Sequential rotation walks participants
        // in joinedAt order (which is how RoomService sorts them).
        let participants = roomService.participants
        guard let firstQuestioner = nextQuestioner(
            participants:        participants,
            rotation:            room.settings.questionerRotation,
            previousQuestioner:  nil
        ) else { return }
        // Set the puzzle on the adjudicator BEFORE writing the round doc.
        // Otherwise a sufficiently fast participant could submit a turn
        // before we've armed the adjudicator with the answer.
        adjudicator.setPuzzle(puzzle)
        do {
            try await roomService.startNextRound(puzzle: puzzle, questionerUid: firstQuestioner)
        } catch {
            roomService.lastError = error.localizedDescription
        }
    }

    // MARK: header

    private var roomHeader: some View {
        VStack(spacing: 10) {
            Text("房间码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(roomService.room?.code ?? "------")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                Label(roomService.room?.mode.label ?? "", systemImage: "gamecontroller")
                if roomService.room?.mode == .party,
                   let max = roomService.room?.settings.maxRounds {
                    Text("· \(max) 轮")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("分享房间码邀请朋友加入")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: participants

    private var participantsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("玩家 (\(roomService.participants.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(roomService.participants) { p in
                        HStack {
                            Image(systemName: p.isHost ? "crown.fill" : "person.fill")
                                .foregroundStyle(p.isHost ? .yellow : .secondary)
                            Text(p.displayName)
                            if p.isHost {
                                Text("主持人")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: host controls

    @ViewBuilder
    private var hostControls: some View {
        VStack(spacing: 8) {
            let onlyHost = roomService.participants.count < 2

            Button {
                showPuzzlePicker = true
            } label: {
                Label("开始游戏（选题）", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(onlyHost)

            if onlyHost {
                Text("至少需要 1 位其他玩家加入才能开始")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                Task { try? await roomService.endRoom() }
            } label: {
                Text("关闭房间")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }
}

// MARK: - Active round (M7 — UI; M8 driven by HostAdjudicator)

struct RoomActiveView: View {

    @Environment(RoomService.self) private var roomService
    @Environment(AuthService.self) private var authService
    @Environment(HostAdjudicator.self) private var adjudicator

    var publicStore: PublicPuzzleStore
    @Bindable var puzzleStore: PuzzleStore

    @State private var inputText: String = ""
    @State private var isSubmitting = false
    @State private var showPuzzlePicker = false

    private var isHost: Bool {
        guard let room = roomService.room, let uid = authService.uid else { return false }
        return room.hostUid == uid
    }

    private var isQuestioner: Bool {
        guard let round = roomService.currentRound, let uid = authService.uid else { return false }
        return round.questionerUid == uid && round.status == .active
    }

    private var questionerName: String {
        guard let round = roomService.currentRound else { return "?" }
        return roomService.participants.first(where: { $0.uid == round.questionerUid })?.displayName ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            roundHeader
            Divider()
            turnsFeed
            Divider()
            footer
        }
        .sheet(isPresented: $showPuzzlePicker) {
            PuzzlePickerSheet(publicStore: publicStore, puzzleStore: puzzleStore) { picked in
                Task { await startNextRound(with: picked) }
            }
        }
        .onChange(of: roomService.currentRound?.status) { _, newStatus in
            // Elimination mode post-round effect: when the round ends
            // without a win, the questioner is out. Once only one
            // non-eliminated participant remains, end the room.
            // Host-only — participant clients observe these state changes
            // but only the host writes them (security rules enforce that
            // even if we forgot).
            guard isHost,
                  newStatus == .abandoned,
                  roomService.room?.mode == .elimination,
                  let round = roomService.currentRound else { return }
            Task { await applyEliminationPostRound(questionerUid: round.questionerUid) }
        }
    }

    @MainActor
    private func applyEliminationPostRound(questionerUid: String) async {
        // 1) Eliminate the questioner who failed to solve their puzzle.
        do {
            try await roomService.eliminateParticipant(uid: questionerUid)
        } catch {
            roomService.lastError = error.localizedDescription
            return
        }
        // 2) After the listener catches up, count non-eliminated. If ≤1
        //    remains, the game is over — end the room so RoomFinishedView
        //    shows the winner. Sleep a beat for the snapshot to land;
        //    if we read participants immediately the local cache may
        //    still show the just-eliminated player as active.
        //
        //    Host counts as a player — being host doesn't grant immunity;
        //    only `isEliminated` matters for survivor count.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let stillIn = roomService.participants.filter { !$0.isEliminated }
        if stillIn.count <= 1 {
            try? await roomService.endRoom()
        }
    }

    // MARK: header

    private var roundHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let round = roomService.currentRound, let room = roomService.room {
                HStack {
                    Text("第 \(round.index + 1) 轮")
                        .font(.headline)
                    if room.mode == .party {
                        Text("/ \(room.settings.maxRounds)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("\(round.questionCount) 问", systemImage: "questionmark.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DifficultyBadge(difficulty: round.puzzleDifficulty)
                    if isHost && round.status == .active {
                        // Host-only escape hatch for stalled rounds. Tucked
                        // into an overflow menu so the destructive options
                        // don't sit visibly next to the friendly stats.
                        Menu {
                            Button("放弃本轮", role: .destructive) {
                                Task { try? await roomService.endCurrentRound(status: .abandoned) }
                            }
                            Button("结束房间", role: .destructive) {
                                Task { try? await roomService.endRoom() }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                if let title = round.puzzleTitle {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(round.puzzleScenario)
                    .font(.body)
                    .lineSpacing(3)
                    .padding(.top, 4)
                if let hint = round.puzzleHint, !hint.isEmpty {
                    Label(hint, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Image(systemName: "person.fill.questionmark").foregroundStyle(.tint)
                    Text("本轮提问者：")
                    Text(questionerName).bold()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("加载中…").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: turns feed

    private var turnsFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(roomService.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    if adjudicator.isAdjudicating && isHost {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在裁决…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(16)
            }
            .onChange(of: roomService.turns.count) {
                if let last = roomService.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(turn.askerDisplayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if turn.isPending {
                    Text("待裁决")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                } else if let v = turn.verdict {
                    Text(v.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(verdictColor(v).opacity(0.18), in: Capsule())
                        .foregroundStyle(verdictColor(v))
                }
            }
            Text(turn.text)
                .font(.body)
            if let comment = turn.comment, !comment.isEmpty {
                Text(comment)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func verdictColor(_ v: Message.Verdict) -> Color {
        switch v {
        case .yes:  return .green
        case .no:   return .red
        case .irr:  return .secondary
        case .part: return .orange
        case .win:  return .purple
        }
    }

    // MARK: footer (input or status)

    @ViewBuilder
    private var footer: some View {
        if let round = roomService.currentRound {
            if round.status.isTerminal {
                terminalFooter(round)
            } else if isQuestioner {
                questionerInput
            } else {
                spectatorBanner
            }
        }
    }

    private var questionerInput: some View {
        HStack(spacing: 8) {
            TextField("提问（答案只能是是/否/无关/部分/解谜）", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(isSubmitting)
                .onSubmit { Task { await submitTapped() } }
            Button {
                Task { await submitTapped() }
            } label: {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private var spectatorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "ear")
            Text("等待 ") + Text(questionerName).bold() + Text(" 提问…")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private func terminalFooter(_ round: Round) -> some View {
        VStack(spacing: 8) {
            switch round.status {
            case .won:
                let winnerName = roomService.participants.first(where: { $0.uid == round.winnerUid })?.displayName ?? "?"
                Label("\(winnerName) 解谜成功！", systemImage: "rosette")
                    .font(.headline)
                    .foregroundStyle(.purple)
            case .abandoned:
                Label("本轮放弃", systemImage: "flag.slash")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }

            if isHost { hostBetweenRoundsControls(round) }
            else      { Text("等待主持人开始下一题…").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private func hostBetweenRoundsControls(_ round: Round) -> some View {
        let canAdvance = canStartAnotherRound
        HStack(spacing: 10) {
            if canAdvance {
                Button {
                    showPuzzlePicker = true
                } label: {
                    Label("下一题", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                // Party mode: all rounds played → only "结束房间" makes sense
                Text("已达本场最大轮数")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { try? await roomService.endRoom() }
            } label: { Text("结束房间") }
        }
    }

    private var canStartAnotherRound: Bool {
        guard let room = roomService.room, let round = roomService.currentRound else { return false }
        switch room.mode {
        case .party:
            return round.index + 1 < room.settings.maxRounds
        case .elimination:
            // For elimination, ANY non-eliminated participant is candidate.
            // Real elimination flow (auto-eliminating questioners on
            // abandon, declaring last-standing winner) is M9 work; for now
            // the host manually decides whether to continue.
            return roomService.participants.contains { !$0.isEliminated }
        }
    }

    // MARK: actions

    @MainActor
    private func submitTapped() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSubmitting = true
        do {
            try await roomService.submitTurn(text: text)
            inputText = ""
        } catch {
            roomService.lastError = error.localizedDescription
        }
        isSubmitting = false
    }

    @MainActor
    private func startNextRound(with puzzle: Puzzle) async {
        guard let room = roomService.room else { return }
        let prevQuestioner = roomService.currentRound?.questionerUid
        guard let next = nextQuestioner(
            participants:       roomService.participants,
            rotation:           room.settings.questionerRotation,
            previousQuestioner: prevQuestioner
        ) else { return }
        adjudicator.setPuzzle(puzzle)
        do {
            try await roomService.startNextRound(puzzle: puzzle, questionerUid: next)
        } catch {
            roomService.lastError = error.localizedDescription
        }
    }
}

// MARK: - Questioner rotation helper

/// Pure helper that picks the next round's questioner from the
/// participant roster. Lives at file scope so both LobbyView (first round)
/// and RoomActiveView (subsequent rounds) can call it without sharing a
/// class. Excludes eliminated participants.
@MainActor
fileprivate func nextQuestioner(
    participants: [Participant],
    rotation: Room.Settings.Rotation,
    previousQuestioner: String?
) -> String? {
    let pool = participants.filter { !$0.isEliminated }
    guard !pool.isEmpty else { return nil }

    switch rotation {
    case .sequential:
        // Walk the joinedAt-sorted list (RoomService already sorts by
        // joinedAt). If no previous, take the first. Else find the
        // previous's index and pick the next, wrapping.
        guard let prev = previousQuestioner,
              let idx = pool.firstIndex(where: { $0.uid == prev }) else {
            return pool.first?.uid
        }
        let nextIdx = (idx + 1) % pool.count
        return pool[nextIdx].uid

    case .random:
        // Avoid picking the same person twice in a row when possible.
        let candidates = pool.filter { $0.uid != previousQuestioner }
        return (candidates.isEmpty ? pool : candidates).randomElement()?.uid
    }
}

// MARK: - Puzzle Picker Sheet

/// Host picks a puzzle to use for the next round. Reuses the user's
/// existing puzzle library so the multiplayer flow doesn't need a parallel
/// content source. Built-in puzzles + user-authored puzzles surface here;
/// public square integration is a follow-up (it'd need a "fetch on
/// selection" path since publicStore caches by id, not full content).
struct PuzzlePickerSheet: View {

    @Environment(\.dismiss) private var dismiss
    var publicStore: PublicPuzzleStore
    @Bindable var puzzleStore: PuzzleStore
    var onPick: (Puzzle) -> Void

    @State private var selection: Puzzle?

    private var puzzles: [Puzzle] { Puzzle.builtIn + puzzleStore.puzzles }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选一道题")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            List(puzzles, selection: $selection) { p in
                PuzzleRow(puzzle: p).tag(p)
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button {
                    if let p = selection {
                        onPick(p)
                        dismiss()
                    }
                } label: {
                    Text("开始本轮").bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selection == nil)
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }
}

// MARK: - Finished room (M9 — end-game leaderboard)

struct RoomFinishedView: View {

    @Environment(RoomService.self) private var roomService

    private var participants: [Participant] { roomService.participants }
    private var room: Room? { roomService.room }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerBanner
                if let mode = room?.mode {
                    switch mode {
                    case .party:
                        if !awards.isEmpty { awardsSection }
                        leaderboardSection
                    case .elimination:
                        eliminationWinner
                        standingsSection
                    }
                }
                exitButton
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .center)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: header banner

    private var headerBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(room?.mode.label ?? "房间")
                .font(.title.bold())
            HStack(spacing: 14) {
                stat("玩家", value: "\(participants.count)")
                if room?.mode == .party, let max = room?.settings.maxRounds {
                    stat("轮数", value: "\(max)")
                }
                stat("总问数", value: "\(participants.reduce(0) { $0 + $1.questionsAsked })")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: awards (party mode)

    /// Compute the 4 award winners. Each tuple = (icon, title, winner, valueText).
    /// Empty array if no rounds played (e.g. host ended room from lobby).
    private var awards: [Award] {
        guard !participants.isEmpty,
              participants.contains(where: { $0.roundsWon > 0 || $0.questionsAsked > 0 }) else {
            return []
        }

        var result: [Award] = []

        // 冠军 — highest score (ties broken by roundsWon then displayName)
        if let champion = participants
            .filter({ $0.score > 0 || $0.roundsWon > 0 })
            .max(by: { lhsRhsScore($0, $1) }) {
            result.append(Award(
                icon: "🥇", title: "冠军",
                winnerName: champion.displayName,
                valueText: "\(champion.score) 分"
            ))
        }

        // 最快通关 — smallest fastestSolveSecs (nil = no qualifying)
        if let fastest = participants
            .compactMap({ p -> (Participant, Int)? in
                guard let s = p.fastestSolveSecs else { return nil }
                return (p, s)
            })
            .min(by: { $0.1 < $1.1 }) {
            result.append(Award(
                icon: "⚡️", title: "最快通关",
                winnerName: fastest.0.displayName,
                valueText: formatElapsed(fastest.1)
            ))
        }

        // 最高效 — best (roundsWon / questionsAsked); needs ≥1 win + ≥1 ask
        let efficiencyCandidates = participants.compactMap { p -> (Participant, Double)? in
            guard p.roundsWon > 0, p.questionsAsked > 0 else { return nil }
            return (p, Double(p.roundsWon) / Double(p.questionsAsked))
        }
        if let best = efficiencyCandidates.max(by: { $0.1 < $1.1 }) {
            let pct = Int((best.1 * 100).rounded())
            result.append(Award(
                icon: "🎯", title: "最高效",
                winnerName: best.0.displayName,
                valueText: "\(pct)% 命中"
            ))
        }

        // 最爱问 — highest total questionsAsked
        if let nosy = participants
            .filter({ $0.questionsAsked > 0 })
            .max(by: { $0.questionsAsked < $1.questionsAsked }) {
            result.append(Award(
                icon: "🤔", title: "最爱问",
                winnerName: nosy.displayName,
                valueText: "\(nosy.questionsAsked) 问"
            ))
        }

        return result
    }

    private var awardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("奖项").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(awards) { award in
                    awardCard(award)
                }
            }
        }
    }

    private func awardCard(_ a: Award) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a.icon).font(.system(size: 28))
            Text(a.title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(a.winnerName).font(.subheadline.bold())
            Text(a.valueText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: leaderboard (party mode)

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("排行榜").font(.headline)
            VStack(spacing: 4) {
                ForEach(Array(sortedParticipants.enumerated()), id: \.element.uid) { idx, p in
                    leaderboardRow(rank: idx + 1, participant: p)
                }
            }
        }
    }

    private var sortedParticipants: [Participant] {
        participants.sorted { lhs, rhs in
            // Score desc → roundsWon desc → displayName asc
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.roundsWon != rhs.roundsWon { return lhs.roundsWon > rhs.roundsWon }
            return lhs.displayName < rhs.displayName
        }
    }

    private func leaderboardRow(rank: Int, participant p: Participant) -> some View {
        HStack(spacing: 12) {
            Text("#\(rank)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 36, alignment: .leading)
                .foregroundStyle(rank <= 3 ? .primary : .secondary)
            Text(p.displayName)
                .font(.body)
            if p.isHost {
                Image(systemName: "crown.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Spacer()
            HStack(spacing: 14) {
                miniStat("分", "\(p.score)")
                miniStat("胜", "\(p.roundsWon)")
                miniStat("问", "\(p.questionsAsked)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rank == 1 ? Color.yellow.opacity(0.10) : Color.secondary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: elimination winner

    /// Pick a winner for elimination mode. Prefers: still-uneliminated
    /// participant with most roundsWon. Falls back to overall top scorer.
    /// Auto-elimination logic (M10) will make this more authoritative; for
    /// now the host may have ended the room manually.
    private var eliminationWinner: some View {
        let candidates = participants.filter { !$0.isEliminated }
        let winner = candidates.max(by: { lhsRhsScore($0, $1) }) ?? sortedParticipants.first

        return VStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("最终胜者").font(.caption).foregroundStyle(.secondary)
            Text(winner?.displayName ?? "—")
                .font(.largeTitle.bold())
            if let w = winner {
                Text("\(w.roundsWon) 胜 · \(w.questionsAsked) 问")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var standingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("淘汰记录").font(.headline)
            VStack(spacing: 4) {
                ForEach(sortedParticipants) { p in
                    HStack {
                        Image(systemName: p.isEliminated ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(p.isEliminated ? .red : .green)
                        Text(p.displayName).strikethrough(p.isEliminated)
                        Spacer()
                        Text("\(p.roundsWon) 胜")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: exit

    private var exitButton: some View {
        Button {
            Task { try? await roomService.leaveRoom() }
        } label: {
            Text("离开房间").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: helpers

    private func formatElapsed(_ secs: Int) -> String {
        if secs < 60 { return "\(secs) 秒" }
        return "\(secs / 60) 分 \(secs % 60) 秒"
    }

    /// Score-then-roundsWon comparator. Returns true if lhs < rhs.
    /// Used as the strict-weak ordering by `.max(by:)` / `.min(by:)`.
    private func lhsRhsScore(_ a: Participant, _ b: Participant) -> Bool {
        if a.score != b.score { return a.score < b.score }
        return a.roundsWon < b.roundsWon
    }
}

private struct Award: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let winnerName: String
    let valueText: String
}

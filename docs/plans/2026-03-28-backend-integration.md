# Backend Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Firebase backend (Auth + Firestore) for user accounts, game record sync, custom puzzle sync, and a public puzzle square; plus fix CoreData error handling and add a give-up path.

**Architecture:** Offline-first — CoreData remains the single source of truth for local data; Firestore syncs on write and on login. Firebase Auth provides Apple Sign In and email/password. Public puzzles live only in Firestore (`/publicPuzzles`).

**Tech Stack:** Firebase iOS SDK (SPM) — FirebaseAuth, FirebaseFirestore; AuthenticationServices (Apple Sign In); os.Logger

---

## Prerequisites

Before starting any task, verify the project compiles:

- `TurtleSoupApp.swift` currently references `PuzzleListView()` (removed in a prior commit). Fix it to use `RootView()` with a `Settings(SettingsView)` scene as described in CLAUDE.md.
- `SettingsView.swift` is currently empty — tasks below will fill it in.

```swift
// TurtleSoupApp.swift — correct entry point
import SwiftUI

@main
struct TurtleSoupApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        Settings {
            SettingsView()
        }
    }
}
```

---

## Task 1: Fix CoreData Error Handling

**Files:**
- Modify: `TurtleSoup/PersistenceController.swift:98-101`

**Step 1: Replace silent try? with os.Logger**

```swift
// Add at top of file
import os.log

// Replace save() method
private let logger = Logger(subsystem: "com.haiguitang", category: "CoreData")

func save() {
    guard ctx.hasChanges else { return }
    do {
        try ctx.save()
    } catch {
        logger.error("CoreData save failed: \(error.localizedDescription, privacy: .public)")
    }
}
```

**Step 2: Commit**

```bash
git add TurtleSoup/PersistenceController.swift
git commit -m "fix: add os.Logger error handling to CoreData save()"
```

---

## Task 2: Give-Up Path

**Files:**
- Modify: `TurtleSoup/GameViewModel.swift`
- Modify: `TurtleSoup/GameView.swift`

**Step 2.1: Add giveUp() to GameViewModel**

Add these properties and method to `GameViewModel`:

```swift
var showGiveUpConfirm: Bool = false

func giveUp() {
    guard !isGameWon else { return }
    isGameWon = true          // disables input
    persistRecord(isWon: false)
    showAnswer = true
}
```

Refactor `persistRecord()` to accept `isWon` parameter:

```swift
private func persistRecord(isWon: Bool) {
    let record = GameRecord(
        puzzleID:      puzzle.id,
        puzzleTitle:   puzzle.title,
        startedAt:     startedAt,
        endedAt:       Date(),
        isWon:         isWon,
        questionCount: questionCount,
        messages:      messages.filter { $0.role != .system }
    )
    recordStore.saveRecord(record)
}
```

Update the win path call site:

```swift
// in send(), replace persistRecord() with:
persistRecord(isWon: true)
```

**Step 2.2: Add 放弃 button to GameView infoPane**

In `GameView.swift`, inside the operations `VStack` (after the win check block), add:

```swift
if !vm.isGameWon {
    Button(role: .destructive) {
        vm.showGiveUpConfirm = true
    } label: {
        Label("放弃查看答案", systemImage: "flag.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .confirmationDialog("确认放弃？", isPresented: $vm.showGiveUpConfirm, titleVisibility: .visible) {
        Button("放弃并查看汤底", role: .destructive) { vm.giveUp() }
        Button("继续游戏", role: .cancel) {}
    } message: {
        Text("放弃将记录为未完成，游戏结束后可查看汤底。")
    }
}
```

**Step 2.3: Verify winRate still correct**

`winRate(for:)` in `GameRecordStore` already filters `isWon == YES`, so it handles losses correctly. No changes needed.

**Step 2.4: Commit**

```bash
git add TurtleSoup/GameViewModel.swift TurtleSoup/GameView.swift
git commit -m "feat: add give-up path with isWon:false persistence and confirmation dialog"
```

---

## Task 3: Firebase SDK Setup (Manual Xcode Steps)

> These steps require Xcode UI and cannot be scripted.

**Step 3.1: Add Firebase package via SPM**

1. In Xcode: File → Add Package Dependencies
2. URL: `https://github.com/firebase/firebase-ios-sdk`
3. Select version rule: Up to Next Major from `11.0.0`
4. Add these products to the **TurtleSoup** target:
   - `FirebaseAuth`
   - `FirebaseFirestore`

**Step 3.2: Create Firebase project**

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Create new project: "haiguitang"
3. Add an **Apple** app with bundle ID matching your Xcode project
4. Download `GoogleService-Info.plist`
5. Drag it into the `TurtleSoup/` folder in Xcode (**add to target**)

**Step 3.3: Enable Auth providers in Firebase Console**

- Authentication → Sign-in method → Enable **Email/Password**
- Authentication → Sign-in method → Enable **Apple**
  - For Apple Sign In on macOS, no service ID is needed for native apps

**Step 3.4: Enable Firestore**

- Firestore Database → Create database → Start in **test mode** (tighten rules later)

**Step 3.5: Add Sign In with Apple entitlement**

In Xcode: Target → Signing & Capabilities → + Capability → **Sign In with Apple**

**Step 3.6: Initialize Firebase in TurtleSoupApp**

```swift
// TurtleSoupApp.swift
import SwiftUI
import FirebaseCore

@main
struct TurtleSoupApp: App {

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        Settings {
            SettingsView()
        }
    }
}
```

**Step 3.7: Verify build compiles**

Build in Xcode (⌘B). Fix any import errors before continuing.

**Step 3.8: Commit**

```bash
git add TurtleSoup/TurtleSoupApp.swift TurtleSoup/GoogleService-Info.plist
git commit -m "feat: add Firebase SDK and configure app entry point"
```

---

## Task 4: AuthService

**Files:**
- Create: `TurtleSoup/AuthService.swift`

**Step 4.1: Create AuthService**

```swift
import Foundation
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import Observation

@Observable
@MainActor
final class AuthService: NSObject {

    private(set) var user: FirebaseAuth.User? = nil
    private var currentNonce: String?

    override init() {
        super.init()
        // Restore persisted auth state
        user = Auth.auth().currentUser
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.user = user }
        }
    }

    var isSignedIn: Bool { user != nil }
    var displayName: String { user?.displayName ?? user?.email ?? "未登录" }

    // MARK: - Email/Password

    func signIn(email: String, password: String) async throws {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        user = result.user
    }

    func signUp(email: String, password: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        user = result.user
    }

    func signOut() throws {
        try Auth.auth().signOut()
        user = nil
    }

    // MARK: - Apple Sign In

    func startAppleSignIn() -> ASAuthorizationAppleIDRequest {
        let nonce = randomNonce()
        currentNonce = nonce
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        return request
    }

    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .failure(let error): throw error
        case .success(let auth):
            guard
                let appleCredential = auth.credential as? ASAuthorizationAppleIDCredential,
                let nonce = currentNonce,
                let tokenData = appleCredential.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else { throw AuthError.invalidCredential }

            let credential = OAuthProvider.appleCredential(
                withIDToken: token,
                rawNonce: nonce,
                fullName: appleCredential.fullName
            )
            let firebaseResult = try await Auth.auth().signIn(with: credential)
            user = firebaseResult.user
        }
    }

    // MARK: - Helpers

    private func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(length)
            .description
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    enum AuthError: LocalizedError {
        case invalidCredential
        var errorDescription: String? { "无效的 Apple 登录凭证" }
    }
}
```

**Step 4.2: Inject AuthService into RootView**

In `RootView.swift`, add:

```swift
@State private var authService = AuthService()
```

Pass it to `SettingsView` and `SidebarView` as needed (see Task 5 and Task 10).

**Step 4.3: Commit**

```bash
git add TurtleSoup/AuthService.swift TurtleSoup/RootView.swift
git commit -m "feat: add AuthService with Apple Sign In and email/password support"
```

---

## Task 5: Auth UI in SettingsView

**Files:**
- Modify: `TurtleSoup/SettingsView.swift`

**Step 5.1: Implement SettingsView with auth + API key**

```swift
import SwiftUI
import AuthenticationServices

struct SettingsView: View {

    @AppStorage("claude_api_key") private var apiKey = ""
    @State var authService: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Form {
            // API Key section
            Section("Claude API") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                Text("用于本地直连 Claude API（未登录时生效）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Account section
            Section("账号") {
                if authService.isSignedIn {
                    LabeledContent("已登录", value: authService.displayName)
                    Button("退出登录", role: .destructive) {
                        try? authService.signOut()
                    }
                } else {
                    // Email/password
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                    SecureField("密码", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)

                    Toggle("注册新账号", isOn: $isSignUp)

                    if let err = errorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }

                    HStack {
                        Button(isSignUp ? "注册" : "登录") {
                            Task { await handleEmailAuth() }
                        }
                        .disabled(isLoading || email.isEmpty || password.isEmpty)

                        Spacer()

                        // Apple Sign In
                        SignInWithAppleButton(
                            isSignUp ? .signUp : .signIn,
                            onRequest: { request in
                                let appleRequest = authService.startAppleSignIn()
                                request.requestedScopes = appleRequest.requestedScopes ?? []
                                request.nonce = appleRequest.nonce
                            },
                            onCompletion: { result in
                                Task { try? await authService.handleAppleSignIn(result: result) }
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(width: 160, height: 32)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }

    private func handleEmailAuth() async {
        isLoading = true
        errorMessage = nil
        do {
            if isSignUp {
                try await authService.signUp(email: email, password: password)
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
```

**Step 5.2: Pass authService from RootView into SettingsView**

In `TurtleSoupApp.swift`, inject the shared `AuthService` instance. Since `@Observable` objects don't work directly across `App`/`Scene` boundaries without environment, the simplest approach is to create `AuthService` at the app level and pass via `.environment`:

```swift
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
```

In `RootView.swift`, receive from environment:

```swift
@Environment(AuthService.self) private var authService
```

**Step 5.3: Commit**

```bash
git add TurtleSoup/SettingsView.swift TurtleSoup/TurtleSoupApp.swift TurtleSoup/RootView.swift
git commit -m "feat: implement SettingsView with Apple Sign In and email/password auth UI"
```

---

## Task 6: FirestoreService

**Files:**
- Create: `TurtleSoup/FirestoreService.swift`

**Step 6.1: Create FirestoreService**

This service handles all Firestore CRUD. It has no `@Observable` state; callers own the state.

```swift
import Foundation
import FirebaseFirestore
import os.log

struct FirestoreService {

    private let db = Firestore.firestore()
    private let logger = Logger(subsystem: "com.haiguitang", category: "Firestore")

    // MARK: - Path helpers

    private func userRef(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }
    private func recordsRef(_ uid: String) -> CollectionReference {
        userRef(uid).collection("gameRecords")
    }
    private func puzzlesRef(_ uid: String) -> CollectionReference {
        userRef(uid).collection("puzzles")
    }
    private var publicPuzzlesRef: CollectionReference {
        db.collection("publicPuzzles")
    }

    // MARK: - Game Records

    func saveRecord(_ record: GameRecord, uid: String) async {
        let data: [String: Any] = [
            "puzzleID":      record.puzzleID.uuidString,
            "puzzleTitle":   record.puzzleTitle,
            "startedAt":     Timestamp(date: record.startedAt),
            "endedAt":       Timestamp(date: record.endedAt),
            "isWon":         record.isWon,
            "questionCount": record.questionCount
        ]
        do {
            try await recordsRef(uid)
                .document(record.startedAt.timeIntervalSince1970.description)
                .setData(data, merge: true)
        } catch {
            logger.error("Firestore saveRecord failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchRecords(uid: String) async -> [[String: Any]] {
        do {
            let snapshot = try await recordsRef(uid).getDocuments()
            return snapshot.documents.map { $0.data() }
        } catch {
            logger.error("Firestore fetchRecords failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - User Puzzles

    func savePuzzle(_ puzzle: Puzzle, uid: String) async {
        var data: [String: Any] = [
            "id":         puzzle.id.uuidString,
            "title":      puzzle.title,
            "difficulty": puzzle.difficulty.rawValue,
            "scenario":   puzzle.scenario,
            "answer":     puzzle.answer,
            "author":     puzzle.author,
            "playCount":  puzzle.playCount
        ]
        if let hint = puzzle.hint { data["hint"] = hint }
        do {
            try await puzzlesRef(uid).document(puzzle.id.uuidString).setData(data, merge: true)
        } catch {
            logger.error("Firestore savePuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deletePuzzle(id: UUID, uid: String) async {
        do {
            try await puzzlesRef(uid).document(id.uuidString).delete()
        } catch {
            logger.error("Firestore deletePuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchUserPuzzles(uid: String) async -> [[String: Any]] {
        do {
            let snapshot = try await puzzlesRef(uid).getDocuments()
            return snapshot.documents.map { $0.data() }
        } catch {
            logger.error("Firestore fetchUserPuzzles failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Public Puzzles

    func publishPuzzle(_ puzzle: Puzzle, uid: String) async {
        var data: [String: Any] = [
            "id":         puzzle.id.uuidString,
            "title":      puzzle.title,
            "difficulty": puzzle.difficulty.rawValue,
            "scenario":   puzzle.scenario,
            "answer":     puzzle.answer,
            "author":     puzzle.author,
            "playCount":  puzzle.playCount,
            "authorUID":  uid,
            "publishedAt": FieldValue.serverTimestamp()
        ]
        if let hint = puzzle.hint { data["hint"] = hint }
        do {
            try await publicPuzzlesRef.document(puzzle.id.uuidString).setData(data, merge: true)
        } catch {
            logger.error("Firestore publishPuzzle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchPublicPuzzles(limit: Int = 50) async -> [Puzzle] {
        do {
            let snapshot = try await publicPuzzlesRef
                .order(by: "publishedAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            return snapshot.documents.compactMap { doc in
                let d = doc.data()
                guard
                    let idStr = d["id"] as? String, let id = UUID(uuidString: idStr),
                    let title = d["title"] as? String,
                    let diffStr = d["difficulty"] as? String,
                    let diff = Puzzle.Difficulty(rawValue: diffStr),
                    let scenario = d["scenario"] as? String,
                    let answer = d["answer"] as? String,
                    let author = d["author"] as? String
                else { return nil }
                return Puzzle(
                    id: id, title: title, difficulty: diff,
                    scenario: scenario, answer: answer,
                    hint: d["hint"] as? String,
                    author: author,
                    playCount: d["playCount"] as? Int ?? 0
                )
            }
        } catch {
            logger.error("Firestore fetchPublicPuzzles failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
```

**Step 6.2: Commit**

```bash
git add TurtleSoup/FirestoreService.swift
git commit -m "feat: add FirestoreService with CRUD for records, puzzles, and public square"
```

---

## Task 7: Sync GameRecordStore → Firestore

**Files:**
- Modify: `TurtleSoup/GameRecordStore.swift`

**Step 7.1: Inject FirestoreService + AuthService into GameRecordStore**

The store needs to know who's logged in to know which Firestore path to write to.

```swift
@Observable
final class GameRecordStore {

    private let pc: PersistenceController
    private let firestore: FirestoreService
    // AuthService injected externally; store holds a weak reference via closure
    var currentUID: String? = nil    // set by RootView when auth state changes

    private(set) var savedRecordCount: Int = 0

    init(pc: PersistenceController = .shared, firestore: FirestoreService = FirestoreService()) {
        self.pc = pc
        self.firestore = firestore
    }

    func saveRecord(_ record: GameRecord) {
        // ... existing CoreData logic unchanged ...
        savedRecordCount += 1
        pc.save()

        // Sync to Firestore if signed in
        if let uid = currentUID {
            Task { await firestore.saveRecord(record, uid: uid) }
        }
    }
    // ... rest of file unchanged
}
```

**Step 7.2: Wire currentUID in RootView**

In `RootView.swift`, observe auth changes and update the store:

```swift
.onChange(of: authService.user?.uid) { _, uid in
    recordStore.currentUID = uid
    if let uid {
        Task { await syncRemoteRecords(uid: uid) }
    }
}
```

The `syncRemoteRecords` function pulls Firestore records and skips any that already exist locally (dedup by puzzleID + startedAt is already in `saveRecord`):

```swift
// In RootView (private helper or extension)
private func syncRemoteRecords(uid: String) async {
    let remote = await FirestoreService().fetchRecords(uid: uid)
    // Remote records are metadata only (no messages); just update play stats
    // Full implementation: map remote dicts → GameRecord and call saveRecord
    // For now: no-op placeholder — extend in future sprint
}
```

**Step 7.3: Commit**

```bash
git add TurtleSoup/GameRecordStore.swift TurtleSoup/RootView.swift
git commit -m "feat: sync GameRecordStore writes to Firestore when signed in"
```

---

## Task 8: Sync PuzzleStore → Firestore

**Files:**
- Modify: `TurtleSoup/PuzzleStore.swift`

**Step 8.1: Read PuzzleStore first**

(Read the file to understand current save/delete methods before editing.)

**Step 8.2: Add Firestore sync to PuzzleStore**

Similar pattern to GameRecordStore: add `currentUID` and `firestore` properties; call `firestore.savePuzzle` after CoreData save, and `firestore.deletePuzzle` after CoreData delete.

Key points:
- Only sync `store.puzzles` (user-created), never `Puzzle.builtIn`
- `deletePuzzle` in Firestore is called from wherever the store's delete method is

**Step 8.3: Commit**

```bash
git add TurtleSoup/PuzzleStore.swift
git commit -m "feat: sync PuzzleStore writes and deletes to Firestore when signed in"
```

---

## Task 9: PublicPuzzleStore + PublicSquareView

**Files:**
- Create: `TurtleSoup/PublicPuzzleStore.swift`
- Create: `TurtleSoup/PublicSquareView.swift`
- Modify: `TurtleSoup/PuzzleEditorView.swift` — add "发布到广场" button

**Step 9.1: Create PublicPuzzleStore**

```swift
import Observation

@Observable
@MainActor
final class PublicPuzzleStore {

    private(set) var puzzles: [Puzzle] = []
    private(set) var isLoading = false
    private let firestore = FirestoreService()

    func fetchIfNeeded() async {
        guard puzzles.isEmpty else { return }
        isLoading = true
        puzzles = await firestore.fetchPublicPuzzles()
        isLoading = false
    }

    func publish(_ puzzle: Puzzle, uid: String) async {
        await firestore.publishPuzzle(puzzle, uid: uid)
        // Optimistic insert
        if !puzzles.contains(where: { $0.id == puzzle.id }) {
            puzzles.insert(puzzle, at: 0)
        }
    }
}
```

**Step 9.2: Create PublicSquareView**

```swift
import SwiftUI

struct PublicSquareView: View {

    @State var publicStore: PublicPuzzleStore
    @Binding var selectedPuzzle: Puzzle?
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        Group {
            if publicStore.isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if publicStore.puzzles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text("广场暂无题目").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(publicStore.puzzles, selection: $selectedPuzzle) { puzzle in
                    PuzzleRow(puzzle: puzzle).tag(puzzle)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedPuzzle) {
                    if selectedPuzzle != nil {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                }
            }
        }
        .task { await publicStore.fetchIfNeeded() }
    }
}
```

**Step 9.3: Add "发布到广场" button in PuzzleEditorView**

Read `PuzzleEditorView.swift` first. Find the action buttons (save/delete area) and add:

```swift
// Only show if user is signed in and puzzle is saved
if let puzzle = editingPuzzle, let uid = authService.user?.uid {
    Button {
        Task { await publicStore.publish(puzzle, uid: uid) }
    } label: {
        Label("发布到广场", systemImage: "globe")
    }
    .buttonStyle(.bordered)
}
```

`PuzzleEditorView` needs `authService` and `publicStore` passed in from `RootView`.

**Step 9.4: Commit**

```bash
git add TurtleSoup/PublicPuzzleStore.swift TurtleSoup/PublicSquareView.swift TurtleSoup/PuzzleEditorView.swift
git commit -m "feat: add PublicPuzzleStore, PublicSquareView, and publish-to-square in editor"
```

---

## Task 10: Wire 广场 Tab into Sidebar + RootView

**Files:**
- Modify: `TurtleSoup/Models.swift` or `RootView.swift` — extend `SidebarTab`
- Modify: `TurtleSoup/SidebarView.swift` — add 广场 tab
- Modify: `TurtleSoup/RootView.swift` — add detail view branch for square tab

**Step 10.1: Extend SidebarTab**

In `RootView.swift` (where `SidebarTab` is defined):

```swift
enum SidebarTab { case library, create, square }
```

**Step 10.2: Update SidebarView segmented picker**

```swift
Picker("", selection: $sidebarTab) {
    Text("题库").tag(SidebarTab.library)
    Text("出题").tag(SidebarTab.create)
    Text("广场").tag(SidebarTab.square)
}
```

Add the new tab body branch in the `if sidebarTab ==` chain:

```swift
} else if sidebarTab == .square {
    PublicSquareView(
        publicStore: publicStore,
        selectedPuzzle: $selectedPuzzle,
        columnVisibility: $columnVisibility
    )
}
```

**Step 10.3: Add publicStore to RootView**

```swift
@State private var publicStore = PublicPuzzleStore()
```

Pass it to `SidebarView` (and `PuzzleEditorView` if needed).

**Step 10.4: Update RootView detail branch**

```swift
} detail: {
    switch sidebarTab {
    case .library:
        if let puzzle = selectedPuzzle {
            GameView(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore).id(puzzle.id)
        } else {
            EmptyDetailView()
        }
    case .create:
        PuzzleEditorView(editingPuzzle: $editingPuzzle, store: store,
                         authService: authService, publicStore: publicStore)
            .id(editingPuzzle?.id.uuidString ?? newPuzzleToken.uuidString)
    case .square:
        if let puzzle = selectedPuzzle {
            GameView(puzzle: puzzle, apiKey: apiKey, recordStore: recordStore).id(puzzle.id)
        } else {
            EmptyDetailView()
        }
    }
}
```

**Step 10.5: Commit**

```bash
git add TurtleSoup/SidebarView.swift TurtleSoup/RootView.swift
git commit -m "feat: add 广场 tab to sidebar with public puzzle browsing"
```

---

## Task 11: Firestore Security Rules

**Step 11.1: Tighten Firestore rules in Firebase Console**

Replace test-mode rules with:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Users can only read/write their own data
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    // Public puzzles: anyone can read, only authenticated users can write their own
    match /publicPuzzles/{puzzleId} {
      allow read: if true;
      allow write: if request.auth != null
                   && request.resource.data.authorUID == request.auth.uid;
    }
  }
}
```

**Step 11.2: Commit note**

Firestore rules are edited in the Firebase Console (not in the repo). Document the rules in `docs/firestore-rules.md`.

---

## Firestore Data Schema Reference

```
/users/{uid}/
  gameRecords/{startedAt_epoch}/
    puzzleID, puzzleTitle, startedAt, endedAt, isWon, questionCount

  puzzles/{puzzleId}/
    id, title, difficulty, scenario, answer, hint, author, playCount

/publicPuzzles/{puzzleId}/
  id, title, difficulty, scenario, answer, hint, author, playCount,
  authorUID, publishedAt
```

---

## Summary of Files

| Action | File |
|--------|------|
| Modify | `TurtleSoup/PersistenceController.swift` |
| Modify | `TurtleSoup/GameViewModel.swift` |
| Modify | `TurtleSoup/GameView.swift` |
| Modify | `TurtleSoup/TurtleSoupApp.swift` |
| Modify | `TurtleSoup/SettingsView.swift` |
| Modify | `TurtleSoup/RootView.swift` |
| Modify | `TurtleSoup/SidebarView.swift` |
| Modify | `TurtleSoup/GameRecordStore.swift` |
| Modify | `TurtleSoup/PuzzleStore.swift` |
| Modify | `TurtleSoup/PuzzleEditorView.swift` |
| Create | `TurtleSoup/AuthService.swift` |
| Create | `TurtleSoup/FirestoreService.swift` |
| Create | `TurtleSoup/PublicPuzzleStore.swift` |
| Create | `TurtleSoup/PublicSquareView.swift` |
| Add    | `TurtleSoup/GoogleService-Info.plist` (manual) |

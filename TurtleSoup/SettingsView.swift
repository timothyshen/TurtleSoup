import SwiftUI
import AuthenticationServices

/// Settings.
///
/// As of P3 this is just account login. The Claude API is provided by the
/// app (proxy URL hardcoded in AppConfig); users never see a key field
/// or a proxy URL field. A connectivity probe is included so the user can
/// verify the proxy is reachable before starting a game — it's the only
/// network-related affordance left in the UI.
struct SettingsView: View {

    @State var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    @State private var probeStatus: ProbeStatus = .idle
    enum ProbeStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            // MARK: Account
            Section("账号") {
                if authService.isSignedIn {
                    LabeledContent("已登录", value: authService.displayName)
                    Button("退出登录", role: .destructive) {
                        do {
                            try authService.signOut()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } else {
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("密码", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)

                    if let err = errorMessage {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    // Primary action — switches between 登录 and 注册 based
                    // on which mode the user picked via the link below.
                    // Replaces the old Toggle("注册新账号") UX which made
                    // "register" feel like an obscure setting; now it's a
                    // proper two-screen flow with one prominent CTA.
                    Button {
                        Task { await handleEmailAuth() }
                    } label: {
                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(isSignUp ? "注册中…" : "登录中…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text(isSignUp ? "注册" : "登录")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoading || email.isEmpty || password.isEmpty)

                    // Mode switch — text link below, NOT a toggle. Tapping
                    // it flips the form between login and signup states.
                    HStack {
                        Spacer()
                        Button {
                            isSignUp.toggle()
                            errorMessage = nil
                        } label: {
                            Text(isSignUp ? "已有账号？登录" : "还没有账号？注册")
                                .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        Spacer()
                    }

                    // Sign in with Apple — alternate path. Kept compact
                    // below the email flow rather than competing for
                    // visual weight beside it.
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
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                }
            }

            // MARK: Connectivity diagnostic
            Section("连接诊断") {
                connectivityProbe
                Text("点击测试 Claude 代理是否在线。游戏 / AI 出题 / AI 复盘都需要代理可达 + 已登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        // macOS Settings scene needs an explicit window size — the scene
        // doesn't size to fit its content. iOS gets full sheet width
        // automatically.
        .frame(width: 420)
        .padding()
        #endif
    }

    // MARK: - Connectivity probe

    @ViewBuilder
    private var connectivityProbe: some View {
        HStack(spacing: 10) {
            Button {
                Task { await runProbe() }
            } label: {
                Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
            }
            .controlSize(.small)
            .disabled(probeStatus == .running)

            switch probeStatus {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("测试中…").font(.caption).foregroundStyle(.secondary)
                }
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Hit the proxy's /api/health endpoint. Auth gate is not exercised
    /// here (would cost a Claude call); auth failures surface naturally
    /// on first real use.
    private func runProbe() async {
        probeStatus = .running
        let health = AppConfig.proxyBaseURL.appendingPathComponent("api/health")
        do {
            let (data, response) = try await URLSession.shared.data(from: health)
            guard let http = response as? HTTPURLResponse else {
                probeStatus = .failure("无效响应")
                return
            }
            if http.statusCode == 200 {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["ok"] as? Bool == true {
                    probeStatus = .success("代理在线")
                } else {
                    probeStatus = .failure("响应格式异常")
                }
            } else {
                probeStatus = .failure("代理返回 \(http.statusCode)")
            }
        } catch {
            probeStatus = .failure(error.localizedDescription)
        }
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

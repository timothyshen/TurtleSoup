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
                    SecureField("密码", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)

                    Toggle("注册新账号", isOn: $isSignUp)

                    if let err = errorMessage {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    HStack {
                        Button(isSignUp ? "注册" : "登录") {
                            Task { await handleEmailAuth() }
                        }
                        .disabled(isLoading || email.isEmpty || password.isEmpty)

                        Spacer()

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

            // MARK: Connectivity diagnostic
            Section("连接诊断") {
                connectivityProbe
                Text("点击测试 Claude 代理是否在线。游戏 / AI 出题 / AI 复盘都需要代理可达 + 已登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
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

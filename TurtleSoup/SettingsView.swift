import SwiftUI
import AuthenticationServices

struct SettingsView: View {

    @AppStorage("claude_api_key") private var apiKey = ""
    @AppStorage("proxy_endpoint") private var proxyEndpoint = ""
    @State var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    /// Result of the most recent "测试连接" attempt. Cleared on any field
    /// edit so a stale green check doesn't reassure after the user edits
    /// the URL or key.
    @State private var probeStatus: ProbeStatus = .idle
    enum ProbeStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            // MARK: Claude API
            Section("Claude API") {
                TextField("代理 Base URL", text: $proxyEndpoint, prompt: Text("https://xxx.vercel.app"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                Text("Vercel 部署根路径（不要带 /api/...）。填写后所有请求走云端代理，需要登录；留空则走下方本地 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("本地 API Key", text: $apiKey)
                    .textContentType(.password)
                Text("仅在代理 Endpoint 留空时使用。生产环境建议改用代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Nudge users off the .direct path. Triggers only when they
                // have a key configured but no proxy — i.e. they could switch
                // and didn't. Silent when both are empty (new install) or
                // when proxy is already on.
                if proxyEndpoint.isEmpty && !apiKey.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("当前走本地 key 直连 Anthropic — 该模式不支持 AI 出题 / AI 复盘，且 key 明文存于 UserDefaults。生产请配置上面的代理 Base URL 并登录。")
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Connectivity probe — talks to whichever path is configured.
                // Avoids the "I filled in the URL but does it actually work?"
                // moment of doubt before the user starts a game.
                connectivityProbe
            }

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
            .disabled(probeStatus == .running || !canProbe)

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

    /// True when there's something testable: either a proxy URL or a local
    /// key. Both empty → no probe target.
    private var canProbe: Bool {
        !proxyEndpoint.isEmpty || !apiKey.isEmpty
    }

    private func runProbe() async {
        probeStatus = .running

        if !proxyEndpoint.isEmpty {
            await probeProxy()
        } else {
            await probeDirectKey()
        }
    }

    /// For proxy mode, hit /api/health. We don't validate the auth gate
    /// here — that requires being signed in AND a real Claude call, which
    /// costs tokens. The smoke-test endpoint tells us the proxy is up;
    /// auth failures will surface naturally on first real use.
    private func probeProxy() async {
        guard let base = URL(string: proxyEndpoint) else {
            probeStatus = .failure("URL 不合法")
            return
        }
        let health = base.appendingPathComponent("api/health")
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
                    probeStatus = .failure("响应格式不对（健康检查未返回 ok:true）")
                }
            } else {
                probeStatus = .failure("代理返回 \(http.statusCode)")
            }
        } catch {
            probeStatus = .failure(error.localizedDescription)
        }
    }

    /// For direct mode, use /v1/messages/count_tokens — free, returns
    /// quickly, validates the key. Sends a 1-token "hi" message so we
    /// don't burn any output tokens.
    private func probeDirectKey() async {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages/count_tokens") else {
            probeStatus = .failure("Anthropic URL 不可用")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model":    "claude-sonnet-4-6",
            "messages": [["role": "user", "content": "hi"]],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                probeStatus = .failure("无效响应")
                return
            }
            switch http.statusCode {
            case 200:
                probeStatus = .success("Key 有效")
            case 401:
                probeStatus = .failure("Key 无效或已撤销")
            case 429:
                probeStatus = .failure("Anthropic rate limit — 稍后重试")
            default:
                let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                let msg = ((body?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
                probeStatus = .failure(msg)
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

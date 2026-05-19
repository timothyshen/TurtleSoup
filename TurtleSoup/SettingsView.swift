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

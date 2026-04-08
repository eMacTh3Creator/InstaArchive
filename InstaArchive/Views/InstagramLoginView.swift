import SwiftUI
import WebKit

/// A WebView that loads Instagram's login page and captures session cookies
struct InstagramLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var isLoading = true
    @State private var loginSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Log in to Instagram")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if loginSucceeded {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("Logged in successfully!")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("InstaArchive can now download full profiles.")
                        .foregroundColor(.secondary)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    Text("Log in with your Instagram account so InstaArchive can access full profiles, stories, and highlights. Your credentials go directly to Instagram — this app never sees your password.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    Divider()

                    InstagramWebView(
                        isLoading: $isLoading,
                        onLoginDetected: {
                            loginSucceeded = true
                            settings.isLoggedIn = true
                            // Reset the Instagram session so it picks up the new cookies
                            InstagramService.shared.resetSession()
                        }
                    )
                }
            }
        }
        .frame(width: 420, height: 620)
    }
}

/// NSViewRepresentable wrapper around WKWebView for Instagram login
struct InstagramWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    let onLoginDetected: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

        // Sync any existing HTTPCookieStorage cookies into the WKWebView
        if let cookies = HTTPCookieStorage.shared.cookies {
            let store = config.websiteDataStore.httpCookieStore
            for cookie in cookies where cookie.domain.contains("instagram.com") {
                store.setCookie(cookie)
            }
        }

        if let url = URL(string: "https://www.instagram.com/accounts/login/") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onLoginDetected: onLoginDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        let onLoginDetected: () -> Void
        private var hasDetectedLogin = false

        init(isLoading: Binding<Bool>, onLoginDetected: @escaping () -> Void) {
            self._isLoading = isLoading
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            checkForLogin(webView: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
            // After any navigation, check cookies
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.checkForLogin(webView: webView)
            }
        }

        private func checkForLogin(webView: WKWebView) {
            guard !hasDetectedLogin else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }

                let hasSession = cookies.contains { $0.name == "sessionid" && !$0.value.isEmpty }

                if hasSession {
                    // Copy cookies to HTTPCookieStorage so InstagramService can use them
                    for cookie in cookies where cookie.domain.contains("instagram.com") {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    self.hasDetectedLogin = true
                    DispatchQueue.main.async {
                        self.onLoginDetected()
                    }
                }
            }
        }
    }
}

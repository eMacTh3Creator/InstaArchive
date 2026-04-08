import Foundation
import Network

/// Lightweight HTTP server for managing subscriptions from a browser.
/// Runs on localhost:8485 by default.
class WebServer: ObservableObject {
    static let shared = WebServer()

    @Published var isRunning = false
    @Published var port: UInt16 = 8485

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// Weak reference set by the app at launch so the server can read/write profiles
    weak var profileStore: ProfileStore?

    /// Active session tokens (simple token-based auth)
    private var validTokens: Set<String> = []
    private let tokenLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    func start(profileStore: ProfileStore) {
        self.profileStore = profileStore
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[WebServer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.isRunning = true }
                print("[WebServer] Listening on http://localhost:\(self?.port ?? 8485)")
            case .failed(let error):
                print("[WebServer] Listener failed: \(error)")
                DispatchQueue.main.async { self?.isRunning = false }
            case .cancelled:
                DispatchQueue.main.async { self?.isRunning = false }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: DispatchQueue(label: "com.instaarchive.webserver"))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        tokenLock.lock()
        validTokens.removeAll()
        tokenLock.unlock()
        DispatchQueue.main.async { self.isRunning = false }
        print("[WebServer] Stopped")
    }

    // MARK: - Auth

    private var passwordRequired: Bool {
        !AppSettings.shared.webServerPassword.isEmpty
    }

    private func isValidToken(_ token: String) -> Bool {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return validTokens.contains(token)
    }

    private func createToken() -> String {
        let token = UUID().uuidString
        tokenLock.lock()
        validTokens.insert(token)
        tokenLock.unlock()
        return token
    }

    private func extractToken(from headers: String) -> String? {
        // Check Cookie header for token=xxx
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "cookie" {
                let cookies = parts[1].trimmingCharacters(in: .whitespaces)
                for cookie in cookies.components(separatedBy: ";") {
                    let kv = cookie.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    if kv.count == 2 && kv[0] == "ia_token" {
                        return String(kv[1])
                    }
                }
            }
        }
        return nil
    }

    private func isAuthenticated(headers: String) -> Bool {
        guard passwordRequired else { return true }
        guard let token = extractToken(from: headers) else { return false }
        return isValidToken(token)
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        let connQueue = DispatchQueue(label: "com.instaarchive.webserver.conn")
        connection.start(queue: connQueue)

        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { connection.cancel(); return }

                if let data = data {
                    buffer.append(data)
                }

                if let request = String(data: buffer, encoding: .utf8),
                   let headerEnd = request.range(of: "\r\n\r\n") {

                    let headers = String(request[..<headerEnd.lowerBound])
                    let bodyStart = request[headerEnd.upperBound...]
                    let contentLength = self.parseContentLength(from: headers)
                    let bodyReceived = bodyStart.utf8.count

                    if bodyReceived >= contentLength {
                        self.routeRequest(request, connection: connection)
                        return
                    }
                }

                if isComplete || error != nil {
                    if let request = String(data: buffer, encoding: .utf8), !request.isEmpty {
                        self.routeRequest(request, connection: connection)
                    } else {
                        connection.cancel()
                    }
                    return
                }

                readMore()
            }
        }

        readMore()
    }

    private func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func routeRequest(_ raw: String, connection: NWConnection) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract headers (everything before the blank line)
        let headers: String = {
            guard let range = raw.range(of: "\r\n\r\n") else { return raw }
            return String(raw[..<range.lowerBound])
        }()

        let body: String? = {
            guard let separatorRange = raw.range(of: "\r\n\r\n") else { return nil }
            let b = String(raw[separatorRange.upperBound...])
            return b.isEmpty ? nil : b
        }()

        // --- Auth: login/logout are always accessible ---
        if method == "POST" && path == "/api/login" {
            handleLogin(body: body, connection: connection)
            return
        }
        if method == "GET" && path == "/login" {
            handleLoginPage(connection: connection)
            return
        }

        // --- Auth check for everything else ---
        if passwordRequired && !isAuthenticated(headers: headers) {
            // Redirect browser to login page, or 401 for API calls
            if path.hasPrefix("/api/") {
                sendJSON(connection: connection, status: "401 Unauthorized", json: ["error": "Unauthorized"])
            } else {
                sendResponse(connection: connection, status: "302 Found", contentType: "text/plain",
                             body: "Redirecting...", extraHeaders: "Location: /login\r\n")
            }
            return
        }

        // --- Routes ---
        switch (method, path) {
        case ("GET", "/"):
            handleIndex(connection: connection)
        case ("GET", "/api/profiles"):
            handleGetProfiles(connection: connection)
        case ("POST", "/api/profiles"):
            handleAddProfile(body: body, connection: connection)
        case ("DELETE", _) where path.hasPrefix("/api/profiles/"):
            let username = String(path.dropFirst("/api/profiles/".count))
            handleDeleteProfile(username: username, connection: connection)
        case ("GET", _) where path.hasPrefix("/api/profile/"):
            let username = String(path.dropFirst("/api/profile/".count))
            handleGetProfileDetail(username: username, connection: connection)
        case ("GET", "/api/status"):
            handleGetStatus(connection: connection)
        case ("POST", "/api/sync/all"):
            handleSyncAll(connection: connection)
        case ("POST", _) where path.hasPrefix("/api/sync/"):
            let username = String(path.dropFirst("/api/sync/".count))
            handleSyncProfile(username: username, connection: connection)
        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "Not found")
        }
    }

    // MARK: - Auth Handlers

    private func handleLogin(body: String?, connection: NWConnection) {
        guard let body = body else {
            sendJSON(connection: connection, status: "400 Bad Request", json: ["error": "Missing password"])
            return
        }

        var password = ""
        if body.contains("password=") {
            let pairs = body.components(separatedBy: "&")
            for pair in pairs {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 && kv[0] == "password" {
                    password = kv[1].removingPercentEncoding ?? ""
                }
            }
        } else if let jsonData = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            password = json["password"] as? String ?? ""
        }

        if password == AppSettings.shared.webServerPassword {
            let token = createToken()
            sendResponse(connection: connection, status: "200 OK", contentType: "application/json",
                         body: "{\"success\":true}",
                         extraHeaders: "Set-Cookie: ia_token=\(token); Path=/; HttpOnly; SameSite=Strict\r\n")
        } else {
            sendJSON(connection: connection, status: "401 Unauthorized", json: ["error": "Wrong password"])
        }
    }

    private func handleLoginPage(connection: NWConnection) {
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.loginHTML)
    }

    // MARK: - API Handlers

    private func handleGetProfiles(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let profiles = self.profileStore?.profiles else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            let dm = DownloadManager.shared
            let data: [[String: Any]] = profiles.map { p in
                var status = "idle"
                if let s = dm.profileStatuses[p.username] {
                    switch s {
                    case .checking: status = "checking"
                    case .downloading(let prog): status = "downloading:\(Int(prog * 100))"
                    case .completed(let n): status = "completed:\(n)"
                    case .skipped: status = "skipped"
                    case .error(let e): status = "error:\(e)"
                    case .idle: status = "idle"
                    }
                }
                return [
                    "username": p.username,
                    "displayName": p.displayName,
                    "isActive": p.isActive,
                    "totalDownloaded": p.totalDownloaded,
                    "dateAdded": ISO8601DateFormatter().string(from: p.dateAdded),
                    "lastChecked": p.lastChecked.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                    "status": status
                ]
            }

            self.sendJSON(connection: connection, json: data)
        }
    }

    private func handleGetProfileDetail(username: String, connection: NWConnection) {
        let clean = (username.removingPercentEncoding ?? username).lowercased()

        DispatchQueue.main.async { [weak self] in
            guard let store = self?.profileStore else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            guard let profile = store.profiles.first(where: { $0.username == clean }) else {
                self?.sendJSON(connection: connection, status: "404 Not Found", json: ["error": "Profile not found"])
                return
            }

            let dm = DownloadManager.shared
            let items = dm.mediaItems(for: clean)

            // Count by media type
            var typeCounts: [String: Int] = [:]
            var totalSize: Int64 = 0
            for item in items {
                typeCounts[item.mediaType.rawValue, default: 0] += 1
                totalSize += item.fileSize ?? 0
            }

            // Download status
            var status = "idle"
            if let s = dm.profileStatuses[clean] {
                switch s {
                case .checking: status = "checking"
                case .downloading(let prog): status = "downloading:\(Int(prog * 100))"
                case .completed(let n): status = "completed:\(n)"
                case .skipped: status = "skipped"
                case .error(let e): status = "error:\(e)"
                case .idle: status = "idle"
                }
            }

            let json: [String: Any] = [
                "username": profile.username,
                "displayName": profile.displayName,
                "bio": profile.bio ?? "",
                "isActive": profile.isActive,
                "totalDownloaded": profile.totalDownloaded,
                "dateAdded": ISO8601DateFormatter().string(from: profile.dateAdded),
                "lastChecked": profile.lastChecked.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "lastNewContent": profile.lastNewContent.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "mediaByType": typeCounts,
                "totalFileSize": totalSize,
                "totalIndexed": items.count,
                "status": status
            ]

            self?.sendJSON(connection: connection, json: json)
        }
    }

    private func handleAddProfile(body: String?, connection: NWConnection) {
        guard let body = body, !body.isEmpty else {
            sendJSON(connection: connection, status: "400 Bad Request", json: ["error": "Missing request body"])
            return
        }

        var username = ""

        if body.contains("username=") {
            let pairs = body.components(separatedBy: "&")
            for pair in pairs {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 && kv[0] == "username" {
                    username = kv[1]
                        .removingPercentEncoding?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }
        } else if let jsonData = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            username = json["username"] as? String ?? ""
        }

        username = cleanUsername(username)

        guard !username.isEmpty else {
            sendJSON(connection: connection, status: "400 Bad Request", json: ["error": "Username is required"])
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let store = self?.profileStore else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            if store.profiles.contains(where: { $0.username == username.lowercased() }) {
                self?.sendJSON(connection: connection, status: "409 Conflict", json: [
                    "error": "Profile @\(username) is already in your list"
                ])
                return
            }

            let profile = Profile(username: username)
            store.addProfile(profile)

            self?.sendJSON(connection: connection, json: [
                "success": true,
                "message": "Added @\(username) to your archive",
                "username": username
            ])
        }
    }

    private func handleDeleteProfile(username: String, connection: NWConnection) {
        let clean = (username.removingPercentEncoding ?? username).lowercased()

        DispatchQueue.main.async { [weak self] in
            guard let store = self?.profileStore else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            guard let profile = store.profiles.first(where: { $0.username == clean }) else {
                self?.sendJSON(connection: connection, status: "404 Not Found", json: ["error": "Profile not found"])
                return
            }

            store.removeProfile(profile)
            self?.sendJSON(connection: connection, json: ["success": true, "message": "Removed @\(clean)"])
        }
    }

    private func handleGetStatus(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            let dm = DownloadManager.shared
            let profiles = self?.profileStore?.profiles ?? []

            let json: [String: Any] = [
                "isDownloading": dm.isRunning,
                "totalProfiles": profiles.count,
                "activeProfiles": profiles.filter({ $0.isActive }).count,
                "totalMediaIndexed": dm.totalDownloaded,
                "currentActivity": dm.currentActivity
            ]
            self?.sendJSON(connection: connection, json: json)
        }
    }

    // MARK: - Sync Handlers

    private func handleSyncAll(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.profileStore else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            let dm = DownloadManager.shared
            if dm.isRunning {
                self?.sendJSON(connection: connection, json: ["success": true, "message": "Sync already running"])
            } else {
                dm.checkAllProfiles(profileStore: store)
                self?.sendJSON(connection: connection, json: ["success": true, "message": "Sync started for all profiles"])
            }
        }
    }

    private func handleSyncProfile(username: String, connection: NWConnection) {
        let clean = (username.removingPercentEncoding ?? username).lowercased()

        DispatchQueue.main.async { [weak self] in
            guard let store = self?.profileStore else {
                self?.sendJSON(connection: connection, status: "500 Internal Server Error", json: ["error": "No profile store"])
                return
            }

            guard let profile = store.profiles.first(where: { $0.username == clean }) else {
                self?.sendJSON(connection: connection, status: "404 Not Found", json: ["error": "Profile not found"])
                return
            }

            let dm = DownloadManager.shared
            if dm.activeUsernames.contains(clean) {
                self?.sendJSON(connection: connection, json: ["success": true, "message": "Already syncing @\(clean)"])
            } else {
                dm.checkProfile(profile, profileStore: store)
                self?.sendJSON(connection: connection, json: ["success": true, "message": "Sync started for @\(clean)"])
            }
        }
    }

    // MARK: - HTML Pages

    private func handleIndex(connection: NWConnection) {
        sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Self.indexHTML)
    }

    // MARK: - Response Helpers

    private func sendJSON(connection: NWConnection, status: String = "200 OK", json: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let body = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "JSON encoding error")
            return
        }
        sendResponse(connection: connection, status: status, contentType: "application/json", body: body)
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String = "text/plain",
                               body: String, extraHeaders: String = "") {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Utilities

    private func cleanUsername(_ input: String) -> String {
        var clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("instagram.com/") {
            if let range = clean.range(of: "instagram.com/") {
                clean = String(clean[range.upperBound...])
                clean = clean.components(separatedBy: CharacterSet(charactersIn: "/?")).first ?? clean
            }
        }
        if clean.hasPrefix("@") { clean = String(clean.dropFirst()) }
        return clean.lowercased()
    }

    var url: String { "http://localhost:\(port)" }

    // MARK: - Login Page HTML

    static let loginHTML = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>InstaArchive — Login</title>
    <style>
      :root { --bg: #0a0a0a; --card: #161616; --border: #2a2a2a; --text: #e8e8e8; --sub: #888; --accent: #6366f1; --accent-hover: #818cf8; --red: #ef4444; }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; display: flex; align-items: center; justify-content: center; }
      .login-box { width: 340px; padding: 36px 28px; background: var(--card); border: 1px solid var(--border); border-radius: 14px; }
      h1 { font-size: 20px; font-weight: 600; margin-bottom: 6px; text-align: center; }
      .sub { color: var(--sub); font-size: 13px; text-align: center; margin-bottom: 24px; }
      input[type=password] { width: 100%; padding: 10px 14px; border-radius: 8px; border: 1px solid var(--border); background: var(--bg); color: var(--text); font-size: 14px; outline: none; margin-bottom: 16px; }
      input[type=password]:focus { border-color: var(--accent); }
      .btn { width: 100%; padding: 10px; border-radius: 8px; border: none; background: var(--accent); color: #fff; font-size: 14px; font-weight: 500; cursor: pointer; }
      .btn:hover { background: var(--accent-hover); }
      .error { color: var(--red); font-size: 13px; text-align: center; margin-bottom: 12px; display: none; }
    </style>
    </head>
    <body>
    <div class="login-box">
      <h1>InstaArchive</h1>
      <p class="sub">Enter your password to continue</p>
      <div class="error" id="err"></div>
      <form onsubmit="login(event)">
        <input type="password" id="pw" placeholder="Password" autofocus />
        <button type="submit" class="btn">Log In</button>
      </form>
    </div>
    <script>
    async function login(e) {
      e.preventDefault();
      const pw = document.getElementById('pw').value;
      const err = document.getElementById('err');
      try {
        const res = await fetch('/api/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ password: pw })
        });
        const data = await res.json();
        if (data.success) { window.location.href = '/'; }
        else { err.textContent = data.error || 'Wrong password'; err.style.display = 'block'; }
      } catch { err.textContent = 'Connection failed'; err.style.display = 'block'; }
    }
    </script>
    </body>
    </html>
    """

    // MARK: - Main App HTML

    static let indexHTML = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>InstaArchive</title>
    <style>
      :root { --bg: #0a0a0a; --card: #161616; --border: #2a2a2a; --text: #e8e8e8; --sub: #888; --accent: #6366f1; --accent-hover: #818cf8; --green: #22c55e; --red: #ef4444; --orange: #f59e0b; }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif; background: var(--bg); color: var(--text); min-height: 100vh; }
      .container { max-width: 640px; margin: 0 auto; padding: 40px 20px; }
      h1 { font-size: 24px; font-weight: 600; margin-bottom: 4px; }
      .subtitle { color: var(--sub); font-size: 14px; margin-bottom: 32px; }
      .status-bar { display: flex; gap: 24px; margin-bottom: 28px; padding: 14px 18px; background: var(--card); border: 1px solid var(--border); border-radius: 10px; }
      .stat { display: flex; flex-direction: column; }
      .stat-val { font-size: 20px; font-weight: 600; font-variant-numeric: tabular-nums; }
      .stat-label { font-size: 11px; color: var(--sub); margin-top: 2px; text-transform: uppercase; letter-spacing: 0.5px; }
      .add-form { display: flex; gap: 10px; margin-bottom: 28px; }
      .add-form input { flex: 1; padding: 10px 14px; border-radius: 8px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 14px; outline: none; transition: border-color 0.15s; }
      .add-form input:focus { border-color: var(--accent); }
      .add-form input::placeholder { color: #555; }
      .btn { padding: 10px 20px; border-radius: 8px; border: none; font-size: 14px; font-weight: 500; cursor: pointer; transition: all 0.15s; }
      .btn-primary { background: var(--accent); color: #fff; }
      .btn-primary:hover { background: var(--accent-hover); }
      .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }
      .btn-sm { padding: 5px 12px; font-size: 12px; border-radius: 6px; }
      .btn-danger { background: transparent; color: var(--red); border: 1px solid #3a1515; }
      .btn-danger:hover { background: #1a0808; }
      .btn-outline { background: transparent; color: var(--sub); border: 1px solid var(--border); }
      .btn-outline:hover { color: var(--text); border-color: #444; }
      .btn-sync { background: transparent; color: var(--green); border: 1px solid #14532d; }
      .btn-sync:hover { background: #052e16; }
      .section-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
      .section-head h2 { font-size: 16px; font-weight: 600; }
      .section-actions { display: flex; gap: 8px; align-items: center; }
      .profiles-list { display: flex; flex-direction: column; gap: 8px; }
      .profile-row { display: flex; align-items: center; gap: 12px; padding: 12px 16px; background: var(--card); border: 1px solid var(--border); border-radius: 10px; transition: border-color 0.15s; cursor: pointer; }
      .profile-row:hover { border-color: #3a3a3a; }
      .avatar { width: 36px; height: 36px; border-radius: 50%; background: linear-gradient(135deg, #7c3aed, #ec4899, #f97316); display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 15px; color: #fff; flex-shrink: 0; }
      .profile-info { flex: 1; min-width: 0; }
      .profile-name { font-size: 14px; font-weight: 500; }
      .profile-meta { font-size: 11px; color: var(--sub); margin-top: 2px; }
      .badge { display: inline-block; padding: 2px 7px; border-radius: 4px; font-size: 10px; font-weight: 600; }
      .badge-active { background: #052e16; color: var(--green); }
      .badge-paused { background: #1c1105; color: var(--orange); }
      .badge-syncing { background: #1e1b4b; color: var(--accent-hover); }
      .toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%); padding: 10px 20px; border-radius: 8px; font-size: 13px; font-weight: 500; z-index: 100; transition: opacity 0.3s; }
      .toast-success { background: #052e16; color: var(--green); border: 1px solid #14532d; }
      .toast-error { background: #1a0808; color: var(--red); border: 1px solid #7f1d1d; }
      .empty { text-align: center; padding: 40px 20px; color: var(--sub); }
      #fileInput { display: none; }
      .loading { text-align: center; padding: 20px; color: var(--sub); }

      /* Profile detail panel */
      .detail-panel { display: none; }
      .detail-panel.open { display: block; }
      .back-btn { background: none; border: none; color: var(--accent); font-size: 13px; cursor: pointer; padding: 0; margin-bottom: 20px; display: flex; align-items: center; gap: 4px; }
      .back-btn:hover { color: var(--accent-hover); }
      .detail-header { display: flex; align-items: center; gap: 16px; margin-bottom: 24px; }
      .detail-header .avatar { width: 56px; height: 56px; font-size: 24px; }
      .detail-name { font-size: 20px; font-weight: 600; }
      .detail-sub { font-size: 13px; color: var(--sub); margin-top: 2px; }
      .detail-bio { font-size: 13px; color: var(--sub); margin-top: 4px; line-height: 1.4; }
      .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 10px; margin-bottom: 24px; }
      .stat-card { padding: 14px; background: var(--card); border: 1px solid var(--border); border-radius: 10px; }
      .stat-card .stat-val { font-size: 18px; }
      .stat-card .stat-label { font-size: 10px; }
      .media-breakdown { margin-bottom: 24px; }
      .media-breakdown h3 { font-size: 14px; font-weight: 600; margin-bottom: 10px; }
      .media-row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid var(--border); font-size: 13px; }
      .media-row:last-child { border-bottom: none; }
      .media-count { color: var(--sub); font-variant-numeric: tabular-nums; }
      .detail-actions { display: flex; gap: 10px; margin-bottom: 24px; }
    </style>
    </head>
    <body>
    <div class="container">
      <!-- LIST VIEW -->
      <div id="listView">
        <h1>InstaArchive</h1>
        <p class="subtitle">Manage your archived Instagram profiles</p>

        <div class="status-bar" id="statusBar">
          <div class="stat"><span class="stat-val" id="statProfiles">-</span><span class="stat-label">Profiles</span></div>
          <div class="stat"><span class="stat-val" id="statActive">-</span><span class="stat-label">Active</span></div>
          <div class="stat"><span class="stat-val" id="statMedia">-</span><span class="stat-label">Media</span></div>
          <div class="stat"><span class="stat-val" id="statStatus">-</span><span class="stat-label">Status</span></div>
        </div>

        <form class="add-form" onsubmit="addProfile(event)">
          <input type="text" id="usernameInput" placeholder="Username, @handle, or Instagram URL" autocomplete="off" spellcheck="false" />
          <button type="submit" class="btn btn-primary" id="addBtn">Add</button>
        </form>

        <div class="section-head">
          <h2>Profiles</h2>
          <div class="section-actions">
            <button class="btn btn-sm btn-sync" onclick="syncAll()">Sync All</button>
            <button class="btn btn-sm btn-outline" onclick="exportProfiles()">Export</button>
            <button class="btn btn-sm btn-outline" onclick="document.getElementById('fileInput').click()">Import</button>
            <input type="file" id="fileInput" accept=".json" onchange="importProfiles(event)" />
          </div>
        </div>

        <div id="profilesList" class="profiles-list">
          <div class="loading">Loading...</div>
        </div>
      </div>

      <!-- DETAIL VIEW -->
      <div id="detailView" class="detail-panel">
        <button class="back-btn" onclick="showList()">&#8592; Back to profiles</button>

        <div class="detail-header">
          <div class="avatar" id="detailAvatar"></div>
          <div>
            <div class="detail-name" id="detailName"></div>
            <div class="detail-sub" id="detailDisplayName"></div>
            <div class="detail-bio" id="detailBio"></div>
          </div>
        </div>

        <div class="detail-actions">
          <button class="btn btn-sm btn-sync" id="detailSyncBtn" onclick="syncDetail()">Sync Now</button>
          <button class="btn btn-sm btn-danger" id="detailRemoveBtn" onclick="removeDetail()">Remove</button>
          <a id="detailIGLink" class="btn btn-sm btn-outline" target="_blank" rel="noopener">View on Instagram</a>
        </div>

        <div class="stats-grid" id="detailStats"></div>

        <div class="media-breakdown" id="mediaBreakdown">
          <h3>Media Breakdown</h3>
          <div id="mediaRows"></div>
        </div>
      </div>
    </div>

    <div class="toast toast-success" id="toast" style="opacity:0"></div>

    <script>
    let profiles = [];
    let currentDetail = null;

    // ---- List view ----

    async function loadProfiles() {
      try {
        const res = await fetch('/api/profiles');
        if (res.status === 401) { window.location.href = '/login'; return; }
        profiles = await res.json();
        renderProfiles();
      } catch (e) {
        document.getElementById('profilesList').innerHTML = '<div class="empty">Could not connect to InstaArchive</div>';
      }
    }

    async function loadStatus() {
      try {
        const res = await fetch('/api/status');
        if (res.status === 401) return;
        const s = await res.json();
        document.getElementById('statProfiles').textContent = s.totalProfiles;
        document.getElementById('statActive').textContent = s.activeProfiles;
        document.getElementById('statMedia').textContent = s.totalMediaIndexed >= 1000 ? (s.totalMediaIndexed / 1000).toFixed(1) + 'K' : s.totalMediaIndexed;
        document.getElementById('statStatus').textContent = s.isDownloading ? 'Downloading' : 'Idle';
      } catch {}
    }

    function statusBadge(p) {
      const s = p.status || 'idle';
      if (s.startsWith('downloading')) return `<span class="badge badge-syncing">Syncing ${s.split(':')[1] || ''}%</span>`;
      if (s === 'checking') return '<span class="badge badge-syncing">Checking</span>';
      return `<span class="badge ${p.isActive ? 'badge-active' : 'badge-paused'}">${p.isActive ? 'Active' : 'Paused'}</span>`;
    }

    function renderProfiles() {
      const el = document.getElementById('profilesList');
      if (profiles.length === 0) {
        el.innerHTML = '<div class="empty">No profiles yet. Add one above.</div>';
        return;
      }
      el.innerHTML = profiles.map(p => `
        <div class="profile-row" onclick="showDetail('${p.username}')">
          <div class="avatar">${p.username[0].toUpperCase()}</div>
          <div class="profile-info">
            <div class="profile-name">@${p.username}</div>
            <div class="profile-meta">${p.totalDownloaded} items${p.displayName !== p.username ? ' &middot; ' + esc(p.displayName) : ''}</div>
          </div>
          ${statusBadge(p)}
          <button class="btn btn-sm btn-sync" onclick="event.stopPropagation(); syncProfile('${p.username}')">Sync</button>
          <button class="btn btn-sm btn-danger" onclick="event.stopPropagation(); removeProfile('${p.username}')">Remove</button>
        </div>
      `).join('');
    }

    function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

    async function addProfile(e) {
      e.preventDefault();
      const input = document.getElementById('usernameInput');
      const username = input.value.trim();
      if (!username) return;
      document.getElementById('addBtn').disabled = true;
      try {
        const res = await fetch('/api/profiles', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username })
        });
        const data = await res.json();
        if (data.error) { showToast(data.error, 'error'); }
        else { showToast(data.message, 'success'); input.value = ''; }
        loadProfiles(); loadStatus();
      } catch (err) { showToast('Failed to add profile', 'error'); }
      document.getElementById('addBtn').disabled = false;
    }

    async function removeProfile(username) {
      if (!confirm('Remove @' + username + '?')) return;
      try {
        await fetch('/api/profiles/' + username, { method: 'DELETE' });
        showToast('Removed @' + username, 'success');
        loadProfiles(); loadStatus();
      } catch { showToast('Failed to remove', 'error'); }
    }

    async function syncProfile(username) {
      try {
        const res = await fetch('/api/sync/' + username, { method: 'POST' });
        const data = await res.json();
        showToast(data.message, 'success');
        setTimeout(loadProfiles, 1000);
      } catch { showToast('Failed to start sync', 'error'); }
    }

    async function syncAll() {
      try {
        const res = await fetch('/api/sync/all', { method: 'POST' });
        const data = await res.json();
        showToast(data.message, 'success');
        setTimeout(loadProfiles, 1000);
      } catch { showToast('Failed to start sync', 'error'); }
    }

    function exportProfiles() {
      const data = JSON.stringify(profiles, null, 2);
      const blob = new Blob([data], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = 'instaarchive-profiles.json'; a.click();
      URL.revokeObjectURL(url);
      showToast('Exported ' + profiles.length + ' profiles', 'success');
    }

    async function importProfiles(e) {
      const file = e.target.files[0];
      if (!file) return;
      try {
        const text = await file.text();
        const imported = JSON.parse(text);
        const list = Array.isArray(imported) ? imported : (imported.profiles || []);
        let added = 0;
        for (const p of list) {
          const username = p.username || p;
          if (!username || typeof username !== 'string') continue;
          try {
            const res = await fetch('/api/profiles', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username }) });
            const data = await res.json();
            if (data.success) added++;
          } catch {}
        }
        showToast('Imported ' + added + ' new profile' + (added === 1 ? '' : 's'), 'success');
        loadProfiles(); loadStatus();
      } catch { showToast('Invalid JSON file', 'error'); }
      e.target.value = '';
    }

    // ---- Detail view ----

    async function showDetail(username) {
      currentDetail = username;
      try {
        const res = await fetch('/api/profile/' + username);
        const d = await res.json();
        if (d.error) { showToast(d.error, 'error'); return; }

        document.getElementById('detailAvatar').textContent = d.username[0].toUpperCase();
        document.getElementById('detailName').textContent = '@' + d.username;
        document.getElementById('detailDisplayName').textContent = d.displayName !== d.username ? d.displayName : '';
        document.getElementById('detailBio').textContent = d.bio || '';
        document.getElementById('detailIGLink').href = 'https://www.instagram.com/' + d.username + '/';

        // Stats cards
        const fmtBytes = (b) => {
          if (b >= 1073741824) return (b / 1073741824).toFixed(1) + ' GB';
          if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB';
          if (b >= 1024) return (b / 1024).toFixed(0) + ' KB';
          return b + ' B';
        };
        const fmtDate = (iso) => {
          if (!iso) return 'Never';
          const d = new Date(iso);
          return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
        };

        document.getElementById('detailStats').innerHTML = [
          { v: d.totalIndexed, l: 'Total Media' },
          { v: fmtBytes(d.totalFileSize), l: 'Storage Used' },
          { v: fmtDate(d.lastChecked), l: 'Last Checked' },
          { v: fmtDate(d.lastNewContent), l: 'Last New Content' },
          { v: fmtDate(d.dateAdded), l: 'Date Added' },
          { v: d.isActive ? 'Active' : 'Paused', l: 'Status' },
        ].map(s => `<div class="stat-card"><div class="stat-val">${s.v}</div><div class="stat-label">${s.l}</div></div>`).join('');

        // Media breakdown
        const types = d.mediaByType || {};
        const rows = Object.entries(types).sort((a,b) => b[1] - a[1]);
        if (rows.length > 0) {
          document.getElementById('mediaBreakdown').style.display = 'block';
          document.getElementById('mediaRows').innerHTML = rows.map(([type, count]) =>
            `<div class="media-row"><span>${type}</span><span class="media-count">${count}</span></div>`
          ).join('');
        } else {
          document.getElementById('mediaBreakdown').style.display = 'none';
        }

        document.getElementById('listView').style.display = 'none';
        document.getElementById('detailView').className = 'detail-panel open';
      } catch { showToast('Failed to load profile', 'error'); }
    }

    function showList() {
      currentDetail = null;
      document.getElementById('detailView').className = 'detail-panel';
      document.getElementById('listView').style.display = 'block';
      loadProfiles();
    }

    async function syncDetail() {
      if (!currentDetail) return;
      await syncProfile(currentDetail);
      setTimeout(() => showDetail(currentDetail), 1500);
    }

    async function removeDetail() {
      if (!currentDetail) return;
      if (!confirm('Remove @' + currentDetail + '?')) return;
      try {
        await fetch('/api/profiles/' + currentDetail, { method: 'DELETE' });
        showToast('Removed @' + currentDetail, 'success');
        showList();
      } catch { showToast('Failed to remove', 'error'); }
    }

    // ---- Utils ----

    function showToast(msg, type) {
      const el = document.getElementById('toast');
      el.textContent = msg;
      el.className = 'toast toast-' + type;
      el.style.opacity = '1';
      setTimeout(() => { el.style.opacity = '0'; }, 2500);
    }

    loadProfiles();
    loadStatus();
    setInterval(() => { loadStatus(); if (!currentDetail) loadProfiles(); }, 5000);
    </script>
    </body>
    </html>
    """
}

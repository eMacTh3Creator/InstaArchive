import Foundation

/// Errors that can occur during Instagram operations
enum InstagramError: LocalizedError {
    case profileNotFound
    case profilePrivate
    case rateLimited
    case networkError(Error)
    case parsingError(String)
    case invalidURL
    case sessionError

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return "Profile not found. Check the username and try again."
        case .profilePrivate:
            return "This profile is private. Only public profiles can be archived."
        case .rateLimited:
            return "Too many requests. Please wait a few minutes and try again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parsingError(let detail):
            return "Failed to parse Instagram data: \(detail)"
        case .invalidURL:
            return "Invalid URL."
        case .sessionError:
            return "Instagram session expired or blocked. Log out in Settings, then log back in."
        }
    }
}

/// Fetched profile information from Instagram
struct InstagramProfileInfo {
    let username: String
    let fullName: String
    let biography: String
    let profilePicURL: String
    let isPrivate: Bool
    let postCount: Int
    let followerCount: Int
    let userId: String
}

/// Represents a discovered media item on Instagram
struct DiscoveredMedia {
    let instagramId: String
    let mediaType: MediaType
    let mediaURLs: [String]       // Can have multiple (carousel)
    let thumbnailURL: String?
    let caption: String?
    let timestamp: Date
    let isVideo: Bool
}

/// Service for interacting with Instagram's public web interface
class InstagramService {
    static let shared = InstagramService()
    private let log = Logger.shared

    private let session: URLSession
    private let baseURL = "https://www.instagram.com"
    private let igAppId = "936619743392459"

    /// Pick the highest-resolution image candidate from image_versions2.candidates.
    /// Instagram returns candidates in arbitrary order — sorting by width descending
    /// ensures we always get the full-res image, not a thumbnail.
    private func bestImageURL(from candidates: [[String: Any]]) -> String? {
        let sorted = candidates.sorted { candidateScore($0) > candidateScore($1) }
        guard let best = sorted.first, let url = best["url"] as? String else { return nil }
        let w = numericValue(best["width"])
        let h = numericValue(best["height"])
        // Only build the per-candidate widths array for diagnostics on
        // low-res outliers — it's noise on the happy path and allocates
        // a throwaway array per image otherwise.
        if w < 500 {
            let smallest = sorted.last.flatMap { numericValue($0["width"]) } ?? 0
            let allWidths = sorted.map { numericValue($0["width"]) }
            log.warn("bestImageURL: picked \(w)x\(h) — only \(candidates.count) candidates (widths: \(allWidths)), smallest=\(smallest)px. URL prefix: \(String(url.prefix(80)))", context: "resolution")
        }
        return url
    }

    private func numericValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    private func candidateScore(_ candidate: [String: Any]) -> Int {
        let width = numericValue(candidate["width"] ?? candidate["config_width"] ?? candidate["original_width"])
        let height = numericValue(candidate["height"] ?? candidate["config_height"] ?? candidate["original_height"])
        let bitrate = numericValue(candidate["bit_rate"] ?? candidate["bitrate"])
        return max(width * height, (width * 10_000) + height + bitrate)
    }

    private func bestVideoURL(from candidates: [[String: Any]]) -> String? {
        return candidates
            .sorted { candidateScore($0) > candidateScore($1) }
            .first?["url"] as? String
            ?? candidates
                .sorted { candidateScore($0) > candidateScore($1) }
                .first?["src"] as? String
    }

    private func bestResourceURL(from resources: [[String: Any]]) -> String? {
        return resources
            .sorted { candidateScore($0) > candidateScore($1) }
            .first?["src"] as? String
    }

    private func bestGraphPreviewURL(from edges: [[String: Any]]) -> String? {
        let resources = edges.compactMap { $0["node"] as? [String: Any] }
        return bestResourceURL(from: resources)
    }

    /// Resolve the best image URL from a mixed Instagram media object.
    /// This prefers full image candidates and only falls back to preview fields
    /// like `display_url` when no richer source is available.
    private func bestImageURL(from mediaObject: [String: Any]) -> String? {
        if let candidates = (mediaObject["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
           let url = bestImageURL(from: candidates) {
            return url
        }

        if let resources = mediaObject["display_resources"] as? [[String: Any]],
           let url = bestResourceURL(from: resources) {
            log.info("bestImageURL: fell through to display_resources (\(resources.count) entries)", context: "resolution")
            return url
        }

        if let resources = mediaObject["thumbnail_resources"] as? [[String: Any]],
           let url = bestResourceURL(from: resources) {
            log.warn("bestImageURL: fell through to thumbnail_resources — may be low-res", context: "resolution")
            return url
        }

        if let previewEdges = (mediaObject["edge_media_preview_image"] as? [String: Any])?["edges"] as? [[String: Any]],
           let url = bestGraphPreviewURL(from: previewEdges) {
            log.warn("bestImageURL: fell through to edge_media_preview_image — may be low-res", context: "resolution")
            return url
        }

        if let displayURL = mediaObject["display_url"] as? String, !displayURL.isEmpty {
            return displayURL
        }

        if let thumbnailSrc = mediaObject["thumbnail_src"] as? String, !thumbnailSrc.isEmpty {
            log.warn("bestImageURL: fell through to thumbnail_src — this IS a thumbnail", context: "resolution")
            return thumbnailSrc
        }

        return nil
    }

    // Rate limiting — thread-safe with lock
    private var lastRequestTime: Date?
    private let rateLock = NSLock()
    private let minimumRequestInterval: TimeInterval = 5.0
    private var requestCount: Int = 0
    private var hourWindowStart: Date = Date()
    private var paginationDepth: Int = 0  // Tracks how deep into pagination we are

    // Session state
    private var csrfToken: String?
    private var igWWWClaim: String = "0"   // X-IG-WWW-Claim header (0 = logged out)
    private var sessionInitialized = false
    private var cachedUserIds: [String: String] = [:]

    /// Whether CDN URL upgrades (stripping size constraints from the `stp`
    /// query param) work for this session. Three states:
    /// - `.untested`: no upgrade attempt has succeeded or failed yet
    /// - `.works`: at least one upgrade succeeded — use upgrades for all images
    /// - `.broken`: upgrades fail consistently — skip the upgrade path
    /// Failures are counted before latching `.broken` so a single transient
    /// network error doesn't permanently disable upgrades for the session.
    private enum CDNUpgradeState { case untested, works, broken }
    private var cdnUpgradeState: CDNUpgradeState = .untested
    private var cdnUpgradeFailureCount: Int = 0
    private let cdnUpgradeFailureThreshold = 3

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        // NOTE: Do NOT set Accept-Encoding here. URLSession handles gzip/deflate
        // decompression automatically, but ONLY if you don't override Accept-Encoding.
        // Setting it manually causes URLSession to return raw compressed bytes.
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            "Connection": "keep-alive",
            "sec-ch-ua": "\"Chromium\";v=\"136\", \"Google Chrome\";v=\"136\", \"Not-A.Brand\";v=\"99\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"macOS\""
        ]
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Session Management

    private func ensureSession() async throws {
        if sessionInitialized, csrfToken != nil { return }

        // Check if we have an existing sessionid cookie (from WKWebView login)
        let existingCookies = HTTPCookieStorage.shared.cookies ?? []
        let hasSessionId = existingCookies.contains { $0.name == "sessionid" && $0.domain.contains("instagram") && !$0.value.isEmpty }
        if hasSessionId {
            // We have login cookies — extract CSRF token and claim from them
            for cookie in existingCookies where cookie.domain.contains("instagram") {
                if cookie.name == "csrftoken" { csrfToken = cookie.value }
                if cookie.name == "ig_www_claim" { igWWWClaim = cookie.value }
            }
            if csrfToken == nil {
                csrfToken = generateCSRFToken()
            }
            sessionInitialized = true
            log.info("Session initialized from existing login cookies (authenticated, claim=\(igWWWClaim != "0" ? "yes" : "no"))", context: "session")
            return
        }

        await waitForRateLimit()

        guard let url = URL(string: baseURL + "/") else {
            throw InstagramError.sessionError
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")

        do {
            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               let responseURL = httpResponse.url {
                let cookies = HTTPCookieStorage.shared.cookies(for: responseURL) ?? []
                for cookie in cookies {
                    if cookie.name == "csrftoken" {
                        csrfToken = cookie.value
                    }
                }
                if csrfToken == nil,
                   let allHeaders = httpResponse.allHeaderFields as? [String: String] {
                    let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: allHeaders, for: responseURL)
                    for cookie in responseCookies {
                        if cookie.name == "csrftoken" {
                            csrfToken = cookie.value
                            HTTPCookieStorage.shared.setCookie(cookie)
                        }
                    }
                }
            }

            if csrfToken == nil {
                csrfToken = generateCSRFToken()
            }

            // Extract ig_www_claim from cookies or response headers
            let allCookies = HTTPCookieStorage.shared.cookies ?? []
            for cookie in allCookies where cookie.domain.contains("instagram") {
                if cookie.name == "ig_www_claim" && !cookie.value.isEmpty { igWWWClaim = cookie.value }
            }
            // Also check X-IG-Set-WWW-Claim response header
            if let httpResp = response as? HTTPURLResponse,
               let claim = httpResp.value(forHTTPHeaderField: "X-IG-Set-WWW-Claim"),
               !claim.isEmpty {
                igWWWClaim = claim
            }

            let isAuthenticated = allCookies.contains {
                $0.name == "sessionid" && $0.domain.contains("instagram") && !$0.value.isEmpty
            }

            sessionInitialized = true
            log.info("Session initialized, CSRF: \(csrfToken != nil ? "yes" : "no"), authenticated: \(isAuthenticated), claim: \(igWWWClaim != "0" ? "yes" : "no")", context: "session")
        } catch {
            log.error("Session init failed: \(error.localizedDescription)", context: "session")
            throw InstagramError.sessionError
        }
    }

    private func generateCSRFToken() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<32).map { _ in chars.randomElement()! })
    }

    func resetSession() {
        sessionInitialized = false
        csrfToken = nil
        // Only clear non-session cookies so the user doesn't have to log in again.
        // Preserving sessionid allows re-initialization without a manual re-login.
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("instagram.com") && cookie.name != "sessionid" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Rate Limiting

    /// Read and update rate limit state atomically. Returns (lastRequest, hourlyCount).
    private func rateLimitState() -> (lastRequest: Date?, hourlyCount: Int) {
        rateLock.lock()
        defer { rateLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(hourWindowStart) > 3600 {
            requestCount = 0
            hourWindowStart = now
        }
        requestCount += 1
        let last = lastRequestTime
        let count = requestCount
        return (last, count)
    }

    /// Mark a request as sent (thread-safe).
    private func markRequestSent() {
        rateLock.lock()
        lastRequestTime = Date()
        rateLock.unlock()
    }

    /// Thread-safe rate limiter with human-like jitter and hourly budget.
    /// Instagram's detection looks for: consistent intervals, high volume bursts,
    /// and sustained request rates that no human would produce.
    private func waitForRateLimit() async {
        // Human-like jitter: mix of short and occasional longer pauses
        let roll = Double.random(in: 0...1)
        let jitter: Double
        if roll < 0.55 {
            jitter = Double.random(in: 2.0...5.0)     // 55%: normal browsing pace
        } else if roll < 0.82 {
            jitter = Double.random(in: 5.0...12.0)    // 27%: slower / reading pause
        } else if roll < 0.95 {
            jitter = Double.random(in: 12.0...25.0)   // 13%: long pause (distracted)
        } else {
            jitter = Double.random(in: 25.0...45.0)   //  5%: very long pause (tab-switched)
        }

        // Deeper into pagination → longer delays (mimics scroll fatigue)
        let depthMultiplier = 1.0 + Double(min(paginationDepth, 10)) * 0.1
        let effectiveInterval = (minimumRequestInterval + jitter) * depthMultiplier

        let (last, currentCount) = rateLimitState()

        // If approaching hourly limit, add aggressive progressive backoff
        if currentCount > 100 {
            let extraDelay = Double(currentCount - 100) * 3.0
            log.warn("Approaching hourly request limit (\(currentCount)/120), adding \(Int(extraDelay))s cooldown", context: "rate")
            try? await Task.sleep(nanoseconds: UInt64(extraDelay * 1_000_000_000))
        }

        if let last = last {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < effectiveInterval {
                let delay = effectiveInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        markRequestSent()
    }

    // MARK: - Response Validation

    /// Check if an API response is actually HTML instead of JSON.
    /// Instagram returns HTML (login page, challenge, consent) with HTTP 200
    /// when your session is invalid or they want additional verification.
    private func validateAPIResponse(data: Data, response: HTTPURLResponse, context: String) throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""

        // If Content-Type says HTML, it's definitely not a JSON API response
        let isHTMLContentType = contentType.contains("text/html")

        // Also check the body — Instagram sometimes omits/lies about Content-Type
        let prefix = String(data: data.prefix(200), encoding: .utf8) ?? ""
        let looksLikeHTML = prefix.contains("<!DOCTYPE") || prefix.contains("<html") || prefix.contains("<head")

        guard isHTMLContentType || looksLikeHTML else {
            return // Looks like JSON, proceed normally
        }

        let body = String(data: data.prefix(2000), encoding: .utf8) ?? ""
        log.error("\(context): Got HTML instead of JSON (Content-Type: \(contentType), \(data.count) bytes)", context: "api")

        // Detect specific Instagram pages
        if body.contains("/accounts/login") || body.contains("\"loginPage\"") || body.contains("\"LoginAndSignupPage\"") {
            log.error("\(context): Instagram redirected to login page — session is expired", context: "api")
            throw InstagramError.sessionError
        }

        if body.contains("/challenge/") || body.contains("\"challenge\"") {
            log.error("\(context): Instagram is requesting a challenge (suspicious login verification)", context: "api")
            throw InstagramError.parsingError("Instagram requires verification. Open instagram.com in your browser, complete any security checks, then try again.")
        }

        if body.contains("consent") || body.contains("/privacy/checks/") {
            log.error("\(context): Instagram is showing a consent/privacy screen", context: "api")
            throw InstagramError.parsingError("Instagram requires you to accept updated terms. Open instagram.com in your browser, accept the prompt, then try again.")
        }

        if body.contains("/accounts/suspended/") {
            throw InstagramError.parsingError("This Instagram account appears to be suspended.")
        }

        // Generic HTML fallback
        throw InstagramError.sessionError
    }

    // MARK: - Common Request Builder

    private func makeAPIRequest(url: URL, referer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(igAppId, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(csrfToken ?? "", forHTTPHeaderField: "X-CSRFToken")
        request.setValue(igWWWClaim, forHTTPHeaderField: "X-IG-WWW-Claim")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue(referer ?? "https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        // NOTE: Do NOT send 'dpr' or 'viewport-width' headers.
        // Instagram's API optimises candidate sets for the declared DPR.
        // With dpr:3 it returns only 2 candidates (150px & 480px) because
        // 480 * 3 = 1440 effective pixels. Omitting these headers makes the
        // API return the full standard candidate set (up to 1440px actual),
        // which is what the real desktop Chrome web client does for XHR.
        // Signal high-bandwidth connection so Instagram serves full-quality content
        request.setValue("WIFI", forHTTPHeaderField: "X-IG-Connection-Type")
        request.setValue("3700", forHTTPHeaderField: "X-IG-Bandwidth-Speed-KBPS")
        request.setValue("3726400", forHTTPHeaderField: "X-IG-Bandwidth-TotalBytes-B")
        request.setValue("1200", forHTTPHeaderField: "X-IG-Bandwidth-TotalTime-MS")
        request.setValue("3700", forHTTPHeaderField: "X-IG-ABR-Connection-Speed-KBPS")
        return request
    }

    /// Update the WWW claim from API response headers (Instagram rotates this).
    private func captureClaimFromResponse(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else { return }
        if let claim = http.value(forHTTPHeaderField: "X-IG-Set-WWW-Claim"),
           !claim.isEmpty, claim != "0" {
            igWWWClaim = claim
        }
    }

    // MARK: - Profile Info

    func fetchProfileInfo(username: String) async throws -> InstagramProfileInfo {
        try await ensureSession()
        await waitForRateLimit()

        let urlString = "\(baseURL)/api/v1/users/web_profile_info/?username=\(username)"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")

        let (data, response) = try await session.data(for: request)
        captureClaimFromResponse(response)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        log.info("Profile info HTTP \(httpResponse.statusCode) for @\(username)", context: "api")

        // Detect HTML responses disguised as 200 OK
        try validateAPIResponse(data: data, response: httpResponse, context: "fetchProfileInfo(@\(username))")

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            log.error("Profile @\(username) not found (404)", context: "api")
            throw InstagramError.profileNotFound
        case 429:
            log.error("Rate limited fetching @\(username) (429)", context: "api")
            throw InstagramError.rateLimited
        case 401, 403:
            log.warn("Auth failed for @\(username) (\(httpResponse.statusCode)), resetting session and retrying", context: "api")
            resetSession()
            try await ensureSession()
            return try await fetchProfileInfoRetry(username: username)
        default:
            log.warn("Unexpected HTTP \(httpResponse.statusCode) for @\(username), trying page scrape fallback", context: "api")
            return try await fetchProfileInfoFromPage(username: username)
        }

        return try parseProfileInfo(from: data)
    }

    private func fetchProfileInfoRetry(username: String) async throws -> InstagramProfileInfo {
        await waitForRateLimit()

        let urlString = "\(baseURL)/api/v1/users/web_profile_info/?username=\(username)"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        log.info("Profile info retry HTTP \(httpResponse.statusCode) for @\(username)", context: "api")

        try validateAPIResponse(data: data, response: httpResponse, context: "fetchProfileInfoRetry(@\(username))")

        if httpResponse.statusCode == 200 {
            return try parseProfileInfo(from: data)
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            log.error("Auth still failing after session reset for @\(username) — session may be expired", context: "api")
            throw InstagramError.sessionError
        }

        return try await fetchProfileInfoFromPage(username: username)
    }

    private func parseProfileInfo(from data: Data) throws -> InstagramProfileInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Log raw response for debugging
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary data)"
            log.error("API response is not valid JSON (\(data.count) bytes). Preview: \(preview)", context: "parse")

            // Give a more helpful error depending on what we got
            if preview.contains("<") {
                throw InstagramError.sessionError
            }
            throw InstagramError.parsingError("Instagram returned an unexpected response (\(data.count) bytes). Try logging out and back in.")
        }

        // Try multiple known response structures
        let user: [String: Any]
        if let dataObj = json["data"] as? [String: Any],
           let u = dataObj["user"] as? [String: Any] {
            // Standard: {"data": {"user": {...}}}
            user = u
        } else if let u = json["user"] as? [String: Any] {
            // Alternative: {"user": {...}}
            user = u
        } else if let graphql = json["graphql"] as? [String: Any],
                  let u = graphql["user"] as? [String: Any] {
            // Legacy GraphQL: {"graphql": {"user": {...}}}
            user = u
        } else if json["username"] != nil {
            // Direct user object at top level
            user = json
        } else {
            // Log the actual keys so we can diagnose
            let topKeys = Array(json.keys).sorted().joined(separator: ", ")
            let status = json["status"] as? String ?? "none"
            let message = json["message"] as? String ?? json["spam"] as? String ?? ""
            log.error("Unexpected API structure. status=\(status), message=\(message), keys=[\(topKeys)]", context: "parse")

            if status == "fail" || !message.isEmpty {
                let displayMsg = message.isEmpty ? "Instagram rejected the request (status: fail)" : message
                throw InstagramError.parsingError(displayMsg)
            }
            throw InstagramError.parsingError("Instagram API changed format. Top-level keys: [\(topKeys)]. Check logs for details.")
        }

        let username = user["username"] as? String ?? ""
        let userId: String = {
            if let id = user["id"] as? String, !id.isEmpty { return id }
            if let pk = user["pk"] as? Int64 { return String(pk) }
            if let pk = user["pk"] as? String { return pk }
            if let pk = user["pk"] as? Int { return String(pk) }
            return ""
        }()
        let fullName = user["full_name"] as? String ?? username
        let biography = user["biography"] as? String ?? ""
        let profilePicURL = user["profile_pic_url_hd"] as? String
            ?? user["profile_pic_url"] as? String ?? ""
        let isPrivate = user["is_private"] as? Bool ?? false

        // Post count: try both GraphQL and v1 API field names
        let edgeOwner = user["edge_owner_to_timeline_media"] as? [String: Any]
        let postCount = edgeOwner?["count"] as? Int
            ?? user["media_count"] as? Int ?? 0

        // Follower count: try both field names
        let edgeFollowers = user["edge_followed_by"] as? [String: Any]
        let followerCount = edgeFollowers?["count"] as? Int
            ?? user["follower_count"] as? Int ?? 0

        if !userId.isEmpty {
            cachedUserIds[username] = userId
        }

        log.info("Parsed profile @\(username) (id=\(userId), posts=\(postCount))", context: "parse")

        return InstagramProfileInfo(
            username: username,
            fullName: fullName,
            biography: biography,
            profilePicURL: profilePicURL,
            isPrivate: isPrivate,
            postCount: postCount,
            followerCount: followerCount,
            userId: userId
        )
    }

    // MARK: - Profile Page Scraping Fallback

    private func fetchProfileInfoFromPage(username: String) async throws -> InstagramProfileInfo {
        await waitForRateLimit()
        log.info("Falling back to page scrape for @\(username)", context: "api")

        let urlString = "\(baseURL)/\(username)/"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        log.info("Page scrape HTTP \(httpResponse.statusCode) for @\(username) (\(data.count) bytes)", context: "api")

        if httpResponse.statusCode == 404 {
            throw InstagramError.profileNotFound
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            log.error("Instagram rejected page request for @\(username) — login may be required", context: "api")
            throw InstagramError.sessionError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw InstagramError.parsingError("Could not decode profile page")
        }

        // Check if Instagram redirected to a login page
        if html.contains("\"loginPage\"") || html.contains("/accounts/login/") && !html.contains("\"edge_owner") {
            log.error("Instagram redirected to login page for @\(username) — session expired or not logged in", context: "api")
            throw InstagramError.sessionError
        }

        if let info = try? extractFromJsonLD(html: html, username: username) {
            log.info("Extracted profile data from JSON-LD for @\(username)", context: "api")
            return info
        }
        if let info = try? extractFromAdditionalData(html: html, username: username) {
            log.info("Extracted profile data from embedded JSON for @\(username)", context: "api")
            return info
        }
        if let info = try? extractFromMetaTags(html: html, username: username) {
            log.info("Extracted profile data from meta tags for @\(username)", context: "api")
            return info
        }

        log.error("All page scraping methods failed for @\(username) — page may have changed format", context: "api")
        throw InstagramError.parsingError("Could not extract profile data. Instagram may have changed their page format, or you may need to log in.")
    }

    private func extractFromJsonLD(html: String, username: String) throws -> InstagramProfileInfo {
        guard let startRange = html.range(of: "<script type=\"application/ld+json\">"),
              let endRange = html.range(of: "</script>", range: startRange.upperBound..<html.endIndex) else {
            throw InstagramError.parsingError("No JSON-LD found")
        }

        let jsonString = String(html[startRange.upperBound..<endRange.lowerBound])
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw InstagramError.parsingError("Invalid JSON-LD")
        }

        let name = json["name"] as? String ?? username
        let description = json["description"] as? String ?? ""
        let profilePic = (json["image"] as? String) ?? ""
        let stats = json["mainEntityOfPage"] as? [String: Any]
        let followers = (stats?["interactionStatistic"] as? [[String: Any]])?.first?["userInteractionCount"] as? Int ?? 0

        return InstagramProfileInfo(
            username: username,
            fullName: name,
            biography: description,
            profilePicURL: profilePic,
            isPrivate: false,
            postCount: 0,
            followerCount: followers,
            userId: ""
        )
    }

    private func extractFromAdditionalData(html: String, username: String) throws -> InstagramProfileInfo {
        let patterns = [
            "\"user\":{",
            "\"graphql\":{\"user\":{",
            "window.__additionalDataLoaded("
        ]

        for pattern in patterns {
            guard let startIdx = html.range(of: pattern) else { continue }

            let searchStart = pattern == "window.__additionalDataLoaded(" ? startIdx.upperBound : startIdx.lowerBound
            if let userJson = extractJSONObject(from: html, startingNear: searchStart, key: "user") {
                let uname = userJson["username"] as? String ?? username
                let userId = userJson["id"] as? String ?? userJson["pk"] as? String ?? ""
                if !userId.isEmpty {
                    cachedUserIds[uname] = userId
                }

                return InstagramProfileInfo(
                    username: uname,
                    fullName: userJson["full_name"] as? String ?? uname,
                    biography: userJson["biography"] as? String ?? "",
                    profilePicURL: userJson["profile_pic_url_hd"] as? String ?? userJson["profile_pic_url"] as? String ?? "",
                    isPrivate: userJson["is_private"] as? Bool ?? false,
                    postCount: (userJson["edge_owner_to_timeline_media"] as? [String: Any])?["count"] as? Int ?? 0,
                    followerCount: (userJson["edge_followed_by"] as? [String: Any])?["count"] as? Int ?? 0,
                    userId: userId
                )
            }
        }

        throw InstagramError.parsingError("No embedded user data found")
    }

    private func extractFromMetaTags(html: String, username: String) throws -> InstagramProfileInfo {
        let ogDescription = extractMetaContent(html: html, property: "og:description") ?? ""
        let ogImage = extractMetaContent(html: html, property: "og:image") ?? ""
        let ogTitle = extractMetaContent(html: html, property: "og:title") ?? username

        var followerCount = 0
        if let match = ogDescription.range(of: "([\\d,.]+[KMB]?)\\s+Followers", options: .regularExpression) {
            let countStr = String(ogDescription[match]).components(separatedBy: " ").first ?? "0"
            followerCount = parseAbbreviatedNumber(countStr)
        }

        let displayName = ogTitle
            .replacingOccurrences(of: "(@\(username))", with: "")
            .replacingOccurrences(of: "• Instagram photos and videos", with: "")
            .trimmingCharacters(in: .whitespaces)

        return InstagramProfileInfo(
            username: username,
            fullName: displayName.isEmpty ? username : displayName,
            biography: "",
            profilePicURL: ogImage,
            isPrivate: false,
            postCount: 0,
            followerCount: followerCount,
            userId: ""
        )
    }

    private func extractMetaContent(html: String, property: String) -> String? {
        let pattern = "<meta\\s+(?:property|name)=\"\(NSRegularExpression.escapedPattern(for: property))\"\\s+content=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let contentRange = Range(match.range(at: 1), in: html) else {
            let altPattern = "<meta\\s+content=\"([^\"]*)\"\\s+(?:property|name)=\"\(NSRegularExpression.escapedPattern(for: property))\""
            guard let altRegex = try? NSRegularExpression(pattern: altPattern, options: .caseInsensitive),
                  let altMatch = altRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let altRange = Range(altMatch.range(at: 1), in: html) else {
                return nil
            }
            return String(html[altRange])
        }
        return String(html[contentRange])
    }

    private func parseAbbreviatedNumber(_ str: String) -> Int {
        let clean = str.replacingOccurrences(of: ",", with: "")
        if clean.hasSuffix("K") {
            return Int((Double(clean.dropLast()) ?? 0) * 1_000)
        } else if clean.hasSuffix("M") {
            return Int((Double(clean.dropLast()) ?? 0) * 1_000_000)
        } else if clean.hasSuffix("B") {
            return Int((Double(clean.dropLast()) ?? 0) * 1_000_000_000)
        }
        return Int(clean) ?? 0
    }

    private func extractJSONObject(from html: String, startingNear: String.Index, key: String) -> [String: Any]? {
        let searchArea = String(html[startingNear...].prefix(50000))
        let target = "\"\(key)\":{"

        guard let keyRange = searchArea.range(of: target) else { return nil }

        let braceStart = searchArea.index(keyRange.upperBound, offsetBy: -1)
        var depth = 0
        var braceEnd: String.Index?

        for idx in searchArea[braceStart...].indices {
            let char = searchArea[idx]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = searchArea.index(after: idx)
                    break
                }
            }
        }

        guard let end = braceEnd else { return nil }
        let jsonStr = String(searchArea[braceStart..<end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // MARK: - Fetch All Media (with full pagination)

    /// Which strategy last succeeded for paginated fetching
    private var workingStrategy: String?

    /// Fetch ALL posts from a public profile, paginating until complete.
    /// Pass `knownIds` to stop early when we reach already-downloaded content.
    func fetchAllMedia(username: String, knownIds: Set<String> = []) async throws -> [DiscoveredMedia] {
        try await ensureSession()

        workingStrategy = nil
        paginationDepth = 0
        var allMedia: [DiscoveredMedia] = []
        var cursor: String? = nil
        var hasMore = true
        var seenIds = Set<String>()
        var pagesWithAllKnown = 0

        while hasMore {
            let result: (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool)
            do {
                result = try await fetchRecentMedia(username: username, after: cursor)
            } catch {
                log.warn("fetchRecentMedia failed on page \(allMedia.count / 33 + 1): \(error.localizedDescription)", context: "media")
                break
            }

            if result.media.isEmpty {
                log.info("Got empty page, stopping pagination", context: "media")
                break
            }

            var newOnThisPage = 0
            var knownOnThisPage = 0
            for media in result.media {
                guard !seenIds.contains(media.instagramId) else { continue }
                seenIds.insert(media.instagramId)
                allMedia.append(media)
                newOnThisPage += 1

                if knownIds.contains(media.instagramId) {
                    knownOnThisPage += 1
                }
            }

            // Only stop early if an ENTIRE page is all already-known AND we have knownIds
            // (meaning this isn't the first time checking this profile)
            if newOnThisPage > 0 && knownOnThisPage == newOnThisPage && !knownIds.isEmpty {
                pagesWithAllKnown += 1
                if pagesWithAllKnown >= 2 {
                    log.info("Two consecutive pages of known items, stopping", context: "media")
                    break
                }
            } else {
                pagesWithAllKnown = 0
            }

            if newOnThisPage == 0 {
                break
            }

            hasMore = result.hasMore
            cursor = result.nextCursor

            if allMedia.count > 5000 {
                log.warn("Hit safety cap of 5000 items for @\(username)", context: "media")
                break
            }

            log.info("Page complete: \(newOnThisPage) items, total \(allMedia.count), hasMore: \(hasMore)", context: "media")
        }

        log.info("Fetched \(allMedia.count) total media items for @\(username) via \(workingStrategy ?? "unknown")", context: "media")
        return allMedia
    }

    /// Fetch a single page of posts (used internally by fetchAllMedia).
    /// Tries strategies in order, logging failures instead of swallowing them.
    func fetchRecentMedia(username: String, after cursor: String? = nil) async throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        try await ensureSession()

        // If we already found a working strategy, prefer it
        if let strategy = workingStrategy {
            switch strategy {
            case "v1":
                if let result = try? await fetchMediaViaAPI(username: username, cursor: cursor),
                   !result.media.isEmpty {
                    log.info("v1 API page: \(result.media.count) items", context: "media")
                    return result
                }
            case "graphql":
                if let result = try? await fetchMediaViaGraphQL(username: username, cursor: cursor),
                   !result.media.isEmpty {
                    return result
                }
            default:
                break
            }
            // If preferred strategy stopped working, fall through to try all
            log.warn("Preferred strategy '\(strategy)' stopped working, trying all", context: "media")
            workingStrategy = nil
        }

        // Strategy 1: v1 API
        // v1 returns reduced 150/480px candidates by design; downloadMediaData()
        // upgrades CDN URLs at fetch time, so we always accept v1 results.
        do {
            let result = try await fetchMediaViaAPI(username: username, cursor: cursor)
            if !result.media.isEmpty {
                workingStrategy = "v1"
                log.info("v1 API: \(result.media.count) items for @\(username)", context: "media")
                return result
            } else {
                log.info("v1 API: 0 items for @\(username)", context: "media")
            }
        } catch {
            log.warn("v1 API failed for @\(username): \(error.localizedDescription)", context: "media")
        }

        // Strategy 2: GraphQL
        do {
            let result = try await fetchMediaViaGraphQL(username: username, cursor: cursor)
            if !result.media.isEmpty {
                workingStrategy = "graphql"
                log.info("GraphQL: \(result.media.count) items for @\(username)", context: "media")
                return result
            } else {
                log.info("GraphQL: 0 items for @\(username)", context: "media")
            }
        } catch {
            log.warn("GraphQL failed for @\(username): \(error.localizedDescription)", context: "media")
        }

        // Strategy 3: HTML scraping + per-post fetching (first page only)
        if cursor == nil {
            let result = try await fetchMediaFromProfilePage(username: username)
            if !result.media.isEmpty {
                workingStrategy = "html"
                log.info("HTML scrape: \(result.media.count) items for @\(username)", context: "media")
                return result
            }
        }

        throw InstagramError.parsingError("Could not fetch media through any available method")
    }

    // MARK: - Profile Picture

    /// Create a DiscoveredMedia for the profile picture
    func makeProfilePicMedia(profileInfo: InstagramProfileInfo) -> DiscoveredMedia? {
        guard !profileInfo.profilePicURL.isEmpty else { return nil }
        return DiscoveredMedia(
            instagramId: "profilepic_\(profileInfo.username)",
            mediaType: .profilePic,
            mediaURLs: [profileInfo.profilePicURL],
            thumbnailURL: profileInfo.profilePicURL,
            caption: "Profile picture",
            timestamp: Date(),
            isVideo: false
        )
    }

    // MARK: - Stories

    /// Fetch stories for a public profile
    func fetchStories(userId: String, username: String) async throws -> [DiscoveredMedia] {
        try await ensureSession()
        await waitForRateLimit()

        // Try v1 API for stories
        let urlString = "\(baseURL)/api/v1/feed/user/\(userId)/story/"
        guard let url = URL(string: urlString) else { return [] }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            log.warn("Stories API returned status \((response as? HTTPURLResponse)?.statusCode ?? 0) for @\(username)", context: "stories")
            // Try GraphQL fallback
            return try await fetchStoriesViaGraphQL(userId: userId, username: username)
        }

        return parseStoriesResponse(from: data, username: username)
    }

    private func fetchStoriesViaGraphQL(userId: String, username: String) async throws -> [DiscoveredMedia] {
        await waitForRateLimit()

        let variables: [String: Any] = [
            "reel_ids": [userId],
            "precomposed_overlay": false
        ]

        guard let variablesData = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesData, encoding: .utf8) else {
            return []
        }

        // GraphQL query for reels/stories
        let queryHash = "d4d88dc1500312af6f937f7b804c68c3"

        var urlComponents = URLComponents(string: "\(baseURL)/graphql/query/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "query_hash", value: queryHash),
            URLQueryItem(name: "variables", value: variablesString)
        ]

        guard let url = urlComponents.url else { return [] }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = json["data"] as? [String: Any],
              let reelsMedia = responseData["reels_media"] as? [[String: Any]],
              let reel = reelsMedia.first,
              let items = reel["items"] as? [[String: Any]] else {
            return []
        }

        var media: [DiscoveredMedia] = []
        for item in items {
            let storyId = item["id"] as? String ?? UUID().uuidString
            let isVideo = item["is_video"] as? Bool ?? false
            let timestamp = item["taken_at_timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970

            var mediaURLs: [String] = []
            if isVideo,
               let videoResources = item["video_resources"] as? [[String: Any]],
               let videoURL = bestVideoURL(from: videoResources) {
                mediaURLs.append(videoURL)
            } else if isVideo, let videoURL = item["video_url"] as? String {
                mediaURLs.append(videoURL)
            } else if let url = bestImageURL(from: item) {
                mediaURLs.append(url)
            }

            guard !mediaURLs.isEmpty else { continue }

            media.append(DiscoveredMedia(
                instagramId: "story_\(storyId)",
                mediaType: .story,
                mediaURLs: mediaURLs,
                thumbnailURL: bestImageURL(from: item),
                caption: nil,
                timestamp: Date(timeIntervalSince1970: timestamp),
                isVideo: isVideo
            ))
        }

        return media
    }

    private func parseStoriesResponse(from data: Data, username: String) -> [DiscoveredMedia] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reel = json["reel"] as? [String: Any],
              let items = reel["items"] as? [[String: Any]] else {
            return []
        }

        var media: [DiscoveredMedia] = []
        for item in items {
            let storyId = item["pk"] as? String
                ?? (item["pk"] as? Int64).map(String.init)
                ?? item["id"] as? String
                ?? UUID().uuidString
            let mediaType = item["media_type"] as? Int ?? 1
            let isVideo = mediaType == 2
            let timestamp = item["taken_at"] as? TimeInterval ?? Date().timeIntervalSince1970

            var mediaURLs: [String] = []
            if isVideo,
               let videoVersions = item["video_versions"] as? [[String: Any]],
               let videoURL = bestVideoURL(from: videoVersions) {
                mediaURLs.append(videoURL)
            } else if let imageURL = bestImageURL(from: item) {
                mediaURLs.append(imageURL)
            }

            guard !mediaURLs.isEmpty else { continue }

            let thumbnailURL = bestImageURL(from: item)

            media.append(DiscoveredMedia(
                instagramId: "story_\(storyId)",
                mediaType: .story,
                mediaURLs: mediaURLs,
                thumbnailURL: thumbnailURL,
                caption: nil,
                timestamp: Date(timeIntervalSince1970: timestamp),
                isVideo: isVideo
            ))
        }

        log.info("Found \(media.count) stories for @\(username)", context: "stories")
        return media
    }

    // MARK: - Highlights

    /// Fetch highlight reels and their actual media items
    func fetchHighlights(userId: String, username: String) async throws -> [DiscoveredMedia] {
        try await ensureSession()
        await waitForRateLimit()

        // Step 1: Get the list of highlight reel IDs
        let highlightIds = try await fetchHighlightReelIds(userId: userId)

        guard !highlightIds.isEmpty else {
            log.info("No highlights found for @\(username)", context: "highlights")
            return []
        }

        log.info("Found \(highlightIds.count) highlight reels for @\(username)", context: "highlights")

        // Step 2: Fetch items from each highlight reel
        var allMedia: [DiscoveredMedia] = []
        for highlightId in highlightIds {
            let items = try await fetchHighlightReelItems(highlightId: highlightId, username: username)
            allMedia.append(contentsOf: items)
        }

        log.info("Fetched \(allMedia.count) total highlight items for @\(username)", context: "highlights")
        return allMedia
    }

    /// Get the list of highlight reel IDs for a user
    private func fetchHighlightReelIds(userId: String) async throws -> [String] {
        // Try v1 API first
        let urlString = "\(baseURL)/api/v1/highlights/\(userId)/highlights_tray/"
        if let url = URL(string: urlString) {
            let request = makeAPIRequest(url: url)
            if let (data, response) = try? await session.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tray = json["tray"] as? [[String: Any]] {
                return tray.compactMap { item -> String? in
                    if let id = item["id"] as? String { return id }
                    if let id = item["id"] as? Int64 { return String(id) }
                    return nil
                }
            }
        }

        await waitForRateLimit()

        // Fallback to GraphQL
        let queryHash = "d4d88dc1500312af6f937f7b804c68c3"
        let variables: [String: Any] = [
            "user_id": userId,
            "include_chaining": false,
            "include_reel": false,
            "include_suggested_users": false,
            "include_logged_out_extras": false,
            "include_highlight_reels": true,
            "include_live_status": false
        ]

        guard let variablesData = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesData, encoding: .utf8) else {
            return []
        }

        var urlComponents = URLComponents(string: "\(baseURL)/graphql/query/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "query_hash", value: queryHash),
            URLQueryItem(name: "variables", value: variablesString)
        ]

        guard let url = urlComponents.url else { return [] }

        let request = makeAPIRequest(url: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = json["data"] as? [String: Any],
              let user = responseData["user"] as? [String: Any],
              let edges = (user["edge_highlight_reels"] as? [String: Any])?["edges"] as? [[String: Any]] else {
            return []
        }

        return edges.compactMap { edge -> String? in
            guard let node = edge["node"] as? [String: Any] else { return nil }
            if let id = node["id"] as? String { return id }
            if let id = node["id"] as? Int64 { return String(id) }
            return nil
        }
    }

    /// Fetch the actual media items within a highlight reel
    private func fetchHighlightReelItems(highlightId: String, username: String) async throws -> [DiscoveredMedia] {
        await waitForRateLimit()

        // v1 API to fetch reel items
        let reelId = highlightId.hasPrefix("highlight:") ? highlightId : "highlight:\(highlightId)"
        let urlString = "\(baseURL)/api/v1/feed/reels_media/?reel_ids=\(reelId)"
        guard let url = URL(string: urlString) else { return [] }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Try the GraphQL approach for this specific highlight
            return try await fetchHighlightReelItemsViaGraphQL(highlightId: highlightId, username: username)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Try "reels" dict format first, then "reels_media" array format
        var items: [[String: Any]]?
        if let reels = json["reels"] as? [String: Any] {
            let reelData = reels[reelId] as? [String: Any]
                ?? reels[highlightId] as? [String: Any]
                ?? reels.values.first as? [String: Any]
            items = reelData?["items"] as? [[String: Any]]
        } else if let reelsMedia = json["reels_media"] as? [[String: Any]],
                  let reel = reelsMedia.first {
            items = reel["items"] as? [[String: Any]]
        }

        guard let reelItems = items else {
            return []
        }

        return parseHighlightItems(reelItems, highlightId: highlightId)
    }

    private func fetchHighlightReelItemsViaGraphQL(highlightId: String, username: String) async throws -> [DiscoveredMedia] {
        await waitForRateLimit()

        let reelId = highlightId.hasPrefix("highlight:") ? highlightId : "highlight:\(highlightId)"
        let queryHash = "45246d3fe16ccc6577e0bd297a5db1ab"
        let variables: [String: Any] = [
            "reel_ids": [reelId],
            "precomposed_overlay": false
        ]

        guard let variablesData = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesData, encoding: .utf8) else {
            return []
        }

        var urlComponents = URLComponents(string: "\(baseURL)/graphql/query/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "query_hash", value: queryHash),
            URLQueryItem(name: "variables", value: variablesString)
        ]

        guard let url = urlComponents.url else { return [] }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = json["data"] as? [String: Any],
              let reelsMedia = responseData["reels_media"] as? [[String: Any]],
              let reel = reelsMedia.first,
              let items = reel["items"] as? [[String: Any]] else {
            return []
        }

        return parseHighlightItems(items, highlightId: highlightId)
    }

    private func parseHighlightItems(_ items: [[String: Any]], highlightId: String) -> [DiscoveredMedia] {
        var media: [DiscoveredMedia] = []

        for item in items {
            let itemId = item["pk"] as? String
                ?? (item["pk"] as? Int64).map(String.init)
                ?? item["id"] as? String
                ?? UUID().uuidString
            let mediaTypeInt = item["media_type"] as? Int ?? 1
            let isVideo = mediaTypeInt == 2
            let timestamp = item["taken_at"] as? TimeInterval ?? Date().timeIntervalSince1970

            var mediaURLs: [String] = []
            if isVideo,
               let videoVersions = item["video_versions"] as? [[String: Any]],
               let videoURL = bestVideoURL(from: videoVersions) {
                mediaURLs.append(videoURL)
            } else if let imageURL = bestImageURL(from: item) {
                mediaURLs.append(imageURL)
            }

            // GraphQL format
            if mediaURLs.isEmpty {
                if isVideo, let videoURL = item["video_url"] as? String {
                    mediaURLs.append(videoURL)
                } else if let imageURL = bestImageURL(from: item) {
                    mediaURLs.append(imageURL)
                }
            }

            guard !mediaURLs.isEmpty else { continue }

            let thumbnailURL = bestImageURL(from: item)

            media.append(DiscoveredMedia(
                instagramId: "highlight_\(highlightId)_\(itemId)",
                mediaType: .highlight,
                mediaURLs: mediaURLs,
                thumbnailURL: thumbnailURL,
                caption: nil,
                timestamp: Date(timeIntervalSince1970: timestamp),
                isVideo: isVideo
            ))
        }

        return media
    }

    // MARK: - Fetch Media (single page, internal)

    private func fetchMediaViaAPI(username: String, cursor: String?) async throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        await waitForRateLimit()

        let userId = try await getUserId(for: username)

        var urlComponents = URLComponents(string: "\(baseURL)/api/v1/feed/user/\(userId)/")!
        var queryItems = [URLQueryItem(name: "count", value: "33")]
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "max_id", value: cursor))
        }
        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        paginationDepth += 1

        let (data, response) = try await session.data(for: request)
        captureClaimFromResponse(response)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            log.warn("Feed API returned status \(statusCode) for @\(username)", context: "api")
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        return try parseV1FeedResponse(from: data, username: username)
    }

    private func parseV1FeedResponse(from data: Data, username: String) throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw InstagramError.parsingError("Could not parse v1 feed response")
        }

        let hasMore = json["more_available"] as? Bool ?? false
        let nextCursor = json["next_max_id"] as? String

        var discoveredMedia: [DiscoveredMedia] = []

        for item in items {
            let code = item["code"] as? String ?? ""
            let mediaType = item["media_type"] as? Int ?? 1
            let isVideo = mediaType == 2
            let timestamp = item["taken_at"] as? TimeInterval ?? Date().timeIntervalSince1970

            let caption = (item["caption"] as? [String: Any])?["text"] as? String

            var mediaURLs: [String] = []
            var thumbnailURL: String?
            var itemMediaType: MediaType = .post

            if mediaType == 8, let carouselMedia = item["carousel_media"] as? [[String: Any]] {
                for carouselItem in carouselMedia {
                    if let videoVersions = carouselItem["video_versions"] as? [[String: Any]],
                       let videoURL = bestVideoURL(from: videoVersions) {
                        mediaURLs.append(videoURL)
                    } else if let imageURL = bestImageURL(from: carouselItem) {
                        mediaURLs.append(imageURL)
                    }
                }
                thumbnailURL = bestImageURL(from: item)
            } else if isVideo {
                if let videoVersions = item["video_versions"] as? [[String: Any]],
                   let videoURL = bestVideoURL(from: videoVersions) {
                    mediaURLs.append(videoURL)
                }
                let productType = item["product_type"] as? String ?? ""
                itemMediaType = productType == "clips" ? .reel : .video
                thumbnailURL = bestImageURL(from: item)
            } else {
                if let imageURL = bestImageURL(from: item) {
                    mediaURLs.append(imageURL)
                    thumbnailURL = imageURL
                }
            }

            guard !mediaURLs.isEmpty else { continue }

            discoveredMedia.append(DiscoveredMedia(
                instagramId: code,
                mediaType: itemMediaType,
                mediaURLs: mediaURLs,
                thumbnailURL: thumbnailURL,
                caption: caption,
                timestamp: Date(timeIntervalSince1970: timestamp),
                isVideo: isVideo
            ))
        }

        return (discoveredMedia, nextCursor, hasMore)
    }

    private func fetchMediaViaGraphQL(username: String, cursor: String?) async throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        await waitForRateLimit()

        let userId = try await getUserId(for: username)

        let docId = "17991233890457762"

        let variables: [String: Any] = [
            "id": userId,
            "first": 33,
            "after": cursor ?? ""
        ]

        guard let variablesData = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesData, encoding: .utf8) else {
            throw InstagramError.invalidURL
        }

        var urlComponents = URLComponents(string: "\(baseURL)/graphql/query/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "doc_id", value: docId),
            URLQueryItem(name: "variables", value: variablesString)
        ]

        guard let url = urlComponents.url else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        paginationDepth += 1

        let (data, response) = try await session.data(for: request)
        captureClaimFromResponse(response)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        return try parseGraphQLMediaResponse(from: data, username: username)
    }

    private func parseGraphQLMediaResponse(from data: Data, username: String) throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary, \(data.count) bytes)"
            log.error("GraphQL response is not valid JSON for @\(username). Preview: \(preview)", context: "graphql")
            throw InstagramError.parsingError("Invalid JSON response")
        }

        let timelineMedia: [String: Any]?

        if let d = json["data"] as? [String: Any],
           let user = d["user"] as? [String: Any] {
            timelineMedia = user["edge_owner_to_timeline_media"] as? [String: Any]
        } else if let d = json["data"] as? [String: Any],
                  let xdt = d["xdt_api__v1__feed__user_timeline_graphql_connection"] as? [String: Any] {
            return try parseModernGraphQLResponse(xdt, username: username)
        } else {
            let topKeys = Array(json.keys).sorted().joined(separator: ", ")
            let status = json["status"] as? String ?? "none"
            let message = json["message"] as? String ?? ""
            log.error("GraphQL unexpected structure for @\(username). status=\(status), message=\(message), keys=[\(topKeys)]", context: "graphql")
            throw InstagramError.parsingError("Unexpected GraphQL response structure")
        }

        guard let media = timelineMedia,
              let edges = media["edges"] as? [[String: Any]] else {
            throw InstagramError.parsingError("Could not find media edges")
        }

        let pageInfo = media["page_info"] as? [String: Any]
        let hasMore = pageInfo?["has_next_page"] as? Bool ?? false
        let nextCursor = pageInfo?["end_cursor"] as? String

        var discoveredMedia: [DiscoveredMedia] = []

        for edge in edges {
            guard let node = edge["node"] as? [String: Any] else { continue }
            if let media = parseGraphQLNode(node) {
                discoveredMedia.append(media)
            }
        }

        return (discoveredMedia, nextCursor, hasMore)
    }

    private func parseModernGraphQLResponse(_ connection: [String: Any], username: String) throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        let edges = connection["edges"] as? [[String: Any]] ?? []
        let pageInfo = connection["page_info"] as? [String: Any]
        let hasMore = pageInfo?["has_next_page"] as? Bool ?? false
        let nextCursor = pageInfo?["end_cursor"] as? String

        var discoveredMedia: [DiscoveredMedia] = []
        for edge in edges {
            guard let node = edge["node"] as? [String: Any] else { continue }
            if let media = parseGraphQLNode(node) {
                discoveredMedia.append(media)
            }
        }

        return (discoveredMedia, nextCursor, hasMore)
    }

    private func parseGraphQLNode(_ node: [String: Any]) -> DiscoveredMedia? {
        let shortcode = node["shortcode"] as? String ?? node["code"] as? String ?? ""
        guard !shortcode.isEmpty else { return nil }

        let isVideo = node["is_video"] as? Bool ?? false
        let typename = node["__typename"] as? String ?? ""
        let timestamp = node["taken_at_timestamp"] as? TimeInterval
            ?? node["taken_at"] as? TimeInterval
            ?? Date().timeIntervalSince1970

        let mediaType: MediaType
        if typename == "GraphSidecar" || typename == "XDTCarouselV2" {
            mediaType = .post
        } else if isVideo {
            mediaType = node["product_type"] as? String == "clips" ? .reel : .video
        } else {
            mediaType = .post
        }

        var mediaURLs: [String] = []

        if let sidecarEdges = (node["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]] {
            for sidecarEdge in sidecarEdges {
                if let sidecarNode = sidecarEdge["node"] as? [String: Any] {
                    if let videoURL = sidecarNode["video_url"] as? String {
                        mediaURLs.append(videoURL)
                    } else if let imageURL = bestImageURL(from: sidecarNode) {
                        mediaURLs.append(imageURL)
                    }
                }
            }
        } else if let carouselMedia = node["carousel_media"] as? [[String: Any]] {
            for item in carouselMedia {
                if let videoVersions = item["video_versions"] as? [[String: Any]],
                   let url = bestVideoURL(from: videoVersions) {
                    mediaURLs.append(url)
                } else if let url = bestImageURL(from: item) {
                    mediaURLs.append(url)
                }
            }
        } else if isVideo, let videoURL = node["video_url"] as? String {
            mediaURLs.append(videoURL)
        } else if let url = bestImageURL(from: node) {
            mediaURLs.append(url)
        }

        guard !mediaURLs.isEmpty else { return nil }

        let captionEdges = (node["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]]
        let caption = (captionEdges?.first?["node"] as? [String: Any])?["text"] as? String
            ?? (node["caption"] as? [String: Any])?["text"] as? String

        let thumbnailURL = bestImageURL(from: node)

        return DiscoveredMedia(
            instagramId: shortcode,
            mediaType: mediaType,
            mediaURLs: mediaURLs,
            thumbnailURL: thumbnailURL,
            caption: caption,
            timestamp: Date(timeIntervalSince1970: timestamp),
            isVideo: isVideo
        )
    }

    private func fetchMediaFromProfilePage(username: String) async throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        await waitForRateLimit()

        let urlString = "\(baseURL)/\(username)/"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw InstagramError.parsingError("Could not decode page")
        }

        var discoveredMedia: [DiscoveredMedia] = []
        var foundShortcodes = Set<String>()

        // 1. Try to extract the full embedded JSON data blob (window._sharedData, etc.)
        if let embeddedMedia = extractEmbeddedMediaData(from: html) {
            discoveredMedia.append(contentsOf: embeddedMedia)
            foundShortcodes = Set(embeddedMedia.map { $0.instagramId })
            log.info("Extracted \(embeddedMedia.count) items from embedded JSON", context: "scrape")
        }

        // 2. Find shortcodes from HTML and try to get their data inline
        let shortcodePattern = "\"shortcode\":\"([A-Za-z0-9_-]+)\""
        if let regex = try? NSRegularExpression(pattern: shortcodePattern) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let range = Range(match.range(at: 1), in: html) {
                    let shortcode = String(html[range])
                    guard !foundShortcodes.contains(shortcode) else { continue }
                    foundShortcodes.insert(shortcode)

                    // Try to extract media URL from nearby context
                    let searchStart = max(html.index(range.lowerBound, offsetBy: -1000, limitedBy: html.startIndex) ?? html.startIndex, html.startIndex)
                    let searchEnd = min(html.index(range.upperBound, offsetBy: 1000, limitedBy: html.endIndex) ?? html.endIndex, html.endIndex)
                    let context = String(html[searchStart..<searchEnd])

                    if let imageURL = extractBestImageURLFromContext(context) {
                        let isVideo = context.contains("\"is_video\":true")
                        let timestamp = extractTimestamp(from: context) ?? Date().timeIntervalSince1970

                        var mediaURLs = [imageURL]
                        if isVideo, let videoURL = extractURLFromContext(context, key: "video_url") {
                            mediaURLs = [videoURL]
                        }

                        discoveredMedia.append(DiscoveredMedia(
                            instagramId: shortcode,
                            mediaType: isVideo ? .video : .post,
                            mediaURLs: mediaURLs,
                            thumbnailURL: imageURL,
                            caption: nil,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            isVideo: isVideo
                        ))
                    }
                }
            }
        }

        // 3. Also find shortcodes from href="/p/SHORTCODE/" links
        let hrefPattern = "href=\"/p/([A-Za-z0-9_-]+)/\""
        if let regex = try? NSRegularExpression(pattern: hrefPattern) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let range = Range(match.range(at: 1), in: html) {
                    let shortcode = String(html[range])
                    if !foundShortcodes.contains(shortcode) {
                        foundShortcodes.insert(shortcode)
                    }
                }
            }
        }

        // 4. For any shortcodes we found but don't have media URLs for, fetch individually
        let shortcodesWithMedia = Set(discoveredMedia.map { $0.instagramId })
        let missingShortcodes = foundShortcodes.subtracting(shortcodesWithMedia)

        if !missingShortcodes.isEmpty {
            log.info("Fetching \(missingShortcodes.count) individual posts by shortcode", context: "scrape")
            for shortcode in missingShortcodes {
                if let media = try? await fetchSinglePost(shortcode: shortcode) {
                    discoveredMedia.append(media)
                }
            }
        }

        log.info("Profile page total: \(discoveredMedia.count) items from \(foundShortcodes.count) shortcodes", context: "scrape")
        return (discoveredMedia, nil, false)
    }

    /// Extract media data from embedded JSON blobs in the page HTML
    private func extractEmbeddedMediaData(from html: String) -> [DiscoveredMedia]? {
        // Try various patterns Instagram uses to embed data
        let patterns = [
            "window._sharedData\\s*=\\s*(\\{.+?\\});",
            "window.__additionalDataLoaded\\s*\\([^,]+,\\s*(\\{.+?\\})\\);",
            "\"entry_data\":\\{\"ProfilePage\":\\[(\\{.+?\\})\\]\\}"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let jsonRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let jsonStr = String(html[jsonRange])
            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Navigate to user media edges
            var timelineMedia: [String: Any]?

            // Path 1: entry_data.ProfilePage[0].graphql.user
            if let entryData = json["entry_data"] as? [String: Any],
               let profilePage = (entryData["ProfilePage"] as? [[String: Any]])?.first,
               let graphql = profilePage["graphql"] as? [String: Any],
               let user = graphql["user"] as? [String: Any] {
                timelineMedia = user["edge_owner_to_timeline_media"] as? [String: Any]
            }
            // Path 2: graphql.user direct
            else if let graphql = json["graphql"] as? [String: Any],
                    let user = graphql["user"] as? [String: Any] {
                timelineMedia = user["edge_owner_to_timeline_media"] as? [String: Any]
            }
            // Path 3: data.user direct
            else if let data = json["data"] as? [String: Any],
                    let user = data["user"] as? [String: Any] {
                timelineMedia = user["edge_owner_to_timeline_media"] as? [String: Any]
            }

            if let edges = timelineMedia?["edges"] as? [[String: Any]] {
                var media: [DiscoveredMedia] = []
                for edge in edges {
                    if let node = edge["node"] as? [String: Any],
                       let m = parseGraphQLNode(node) {
                        media.append(m)
                    }
                }
                if !media.isEmpty {
                    return media
                }
            }
        }

        return nil
    }

    /// Fetch a single post by shortcode to get its media URLs
    func fetchSinglePost(shortcode: String) async throws -> DiscoveredMedia {
        await waitForRateLimit()

        // Try the v1 media info API
        let urlString = "\(baseURL)/api/v1/media/\(shortcode)/info/"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/p/\(shortcode)/")

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]],
               let item = items.first {
                // Parse like a v1 feed item
                let code = item["code"] as? String ?? shortcode
                let mediaType = item["media_type"] as? Int ?? 1
                let isVideo = mediaType == 2
                let timestamp = item["taken_at"] as? TimeInterval ?? Date().timeIntervalSince1970
                let caption = (item["caption"] as? [String: Any])?["text"] as? String

                var mediaURLs: [String] = []
                var itemMediaType: MediaType = .post

                if mediaType == 8, let carouselMedia = item["carousel_media"] as? [[String: Any]] {
                    for carouselItem in carouselMedia {
                        if let videoVersions = carouselItem["video_versions"] as? [[String: Any]],
                           let videoURL = bestVideoURL(from: videoVersions) {
                            mediaURLs.append(videoURL)
                        } else if let imageURL = bestImageURL(from: carouselItem) {
                            mediaURLs.append(imageURL)
                        }
                    }
                } else if isVideo {
                    if let videoVersions = item["video_versions"] as? [[String: Any]],
                       let videoURL = bestVideoURL(from: videoVersions) {
                        mediaURLs.append(videoURL)
                    }
                    let productType = item["product_type"] as? String ?? ""
                    itemMediaType = productType == "clips" ? .reel : .video
                } else {
                    if let imageURL = bestImageURL(from: item) {
                        mediaURLs.append(imageURL)
                    }
                }

                if !mediaURLs.isEmpty {
                    let thumbnailURL = bestImageURL(from: item)
                    return DiscoveredMedia(
                        instagramId: code,
                        mediaType: itemMediaType,
                        mediaURLs: mediaURLs,
                        thumbnailURL: thumbnailURL,
                        caption: caption,
                        timestamp: Date(timeIntervalSince1970: timestamp),
                        isVideo: isVideo
                    )
                }
            }
        } catch {
            log.warn("v1 media info failed for \(shortcode): \(error.localizedDescription)", context: "api")
        }

        // Fallback: try the post page HTML
        return try await fetchSinglePostFromPage(shortcode: shortcode)
    }

    /// Fetch a single post by scraping its page
    private func fetchSinglePostFromPage(shortcode: String) async throws -> DiscoveredMedia {
        await waitForRateLimit()

        let urlString = "\(baseURL)/p/\(shortcode)/"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw InstagramError.parsingError("Could not load post page for \(shortcode)")
        }

        // Try to extract from meta tags
        let ogImage = extractMetaContent(html: html, property: "og:image")
        let ogVideo = extractMetaContent(html: html, property: "og:video")
        let ogType = extractMetaContent(html: html, property: "og:type") ?? ""
        let isVideo = ogType.contains("video") || ogVideo != nil

        var mediaURLs: [String] = []
        if let video = ogVideo, !video.isEmpty {
            mediaURLs.append(video)
        } else if let image = extractBestImageURLFromHTML(html) ?? ogImage, !image.isEmpty {
            mediaURLs.append(image)
        }

        // Also try embedded JSON
        if mediaURLs.isEmpty || !isVideo {
            if let imageURL = extractBestImageURLFromHTML(html) {
                if mediaURLs.isEmpty { mediaURLs.append(imageURL) }
            }
            if let videoURL = extractURLFromHTML(html, key: "video_url") {
                mediaURLs = [videoURL]
            }
        }

        guard !mediaURLs.isEmpty else {
            throw InstagramError.parsingError("No media URLs found for post \(shortcode)")
        }

        return DiscoveredMedia(
            instagramId: shortcode,
            mediaType: isVideo ? .video : .post,
            mediaURLs: mediaURLs,
            thumbnailURL: ogImage,
            caption: nil,
            timestamp: Date(),
            isVideo: isVideo
        )
    }

    /// Extract a URL value from anywhere in an HTML page
    private func extractURLFromHTML(_ html: String, key: String) -> String? {
        let pattern = "\"\(key)\":\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private func extractURLFromContext(_ context: String, key: String) -> String? {
        let pattern = "\"\(key)\":\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)),
              let range = Range(match.range(at: 1), in: context) else {
            return nil
        }
        return String(context[range])
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private func extractBestImageURLFromHTML(_ html: String) -> String? {
        extractBestImageURL(from: html, arrayKeys: ["image_versions2", "display_resources", "thumbnail_resources"])
            ?? extractURLFromHTML(html, key: "display_url")
    }

    private func extractBestImageURLFromContext(_ context: String) -> String? {
        extractBestImageURL(from: context, arrayKeys: ["image_versions2", "display_resources", "thumbnail_resources"])
            ?? extractURLFromContext(context, key: "display_url")
    }

    private func extractBestImageURL(from text: String, arrayKeys: [String]) -> String? {
        for key in arrayKeys {
            if let fragment = extractJSONArrayFragment(from: text, forKey: key),
               let bestURL = bestURLInJSONArrayFragment(fragment) {
                return bestURL
            }
        }
        return nil
    }

    private func extractJSONArrayFragment(from text: String, forKey key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*(?:\\{\"candidates\":)?\\[(.*?)\\](?:\\})?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func bestURLInJSONArrayFragment(_ fragment: String) -> String? {
        let objectPattern = "\\{[^\\{\\}]*\\}"
        guard let regex = try? NSRegularExpression(pattern: objectPattern) else {
            return nil
        }

        let matches = regex.matches(in: fragment, range: NSRange(fragment.startIndex..., in: fragment))
        var bestURL: String?
        var bestScore = 0

        for match in matches {
            guard let range = Range(match.range, in: fragment) else { continue }
            let object = String(fragment[range])
            let url = extractURLFromContext(object, key: "url") ?? extractURLFromContext(object, key: "src")
            guard let url else { continue }

            let width = extractInteger(from: object, key: "width")
                ?? extractInteger(from: object, key: "config_width")
                ?? extractInteger(from: object, key: "original_width")
                ?? 0
            let height = extractInteger(from: object, key: "height")
                ?? extractInteger(from: object, key: "config_height")
                ?? extractInteger(from: object, key: "original_height")
                ?? 0
            let score = max(width * height, (width * 10_000) + height)

            if score > bestScore {
                bestScore = score
                bestURL = url
            }
        }

        return bestURL
    }

    private func extractInteger(from text: String, key: String) -> Int? {
        let pattern = "\"\(key)\":(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[range])
    }

    private func extractTimestamp(from context: String) -> TimeInterval? {
        let pattern = "\"taken_at_timestamp\":(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)),
              let range = Range(match.range(at: 1), in: context) else {
            return nil
        }
        return TimeInterval(String(context[range]))
    }

    // MARK: - User ID Resolution

    private func getUserId(for username: String) async throws -> String {
        if let cached = cachedUserIds[username] {
            return cached
        }

        let info = try await fetchProfileInfo(username: username)
        if !info.userId.isEmpty {
            cachedUserIds[username] = info.userId
            return info.userId
        }

        await waitForRateLimit()

        let urlString = "\(baseURL)/api/v1/users/web_profile_info/?username=\(username)"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        let request = makeAPIRequest(url: url, referer: "https://www.instagram.com/\(username)/")
        let (data, _) = try await session.data(for: request)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try all known response shapes
            let userObj: [String: Any]? =
                (json["data"] as? [String: Any])?["user"] as? [String: Any]
                ?? json["user"] as? [String: Any]
                ?? (json["graphql"] as? [String: Any])?["user"] as? [String: Any]
                ?? (json["username"] != nil ? json : nil)

            if let user = userObj {
                let userId: String? = user["id"] as? String
                    ?? (user["pk"] as? Int64).map(String.init)
                    ?? (user["pk"] as? Int).map(String.init)
                    ?? user["pk"] as? String
                if let uid = userId, !uid.isEmpty {
                    cachedUserIds[username] = uid
                    return uid
                }
            }
        }

        log.error("Could not resolve user ID for @\(username)", context: "api")
        throw InstagramError.parsingError("Could not resolve user ID for @\(username). You may need to log in again.")
    }

    // MARK: - CDN URL Resolution Upgrade

    /// Compiled once per process. Matches `_p480x480` (proportional resize) and
    /// `_s150x150` (square crop) directives inside the `stp` query parameter.
    private static let stpSizeDirectivePattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "_[ps]\\d+x\\d+")
    }()

    /// Upgrade an Instagram CDN image URL to request original/full resolution
    /// by removing size-limiting transform parameters.
    ///
    /// Instagram CDN URLs include a `stp` query parameter that controls server-side
    /// processing: e.g. `stp=dst-jpg_e35_p480x480` means "JPEG, quality e35, cap at
    /// 480×480". The `_p{W}x{H}` suffix is a resize directive. Removing it while
    /// keeping the format/encoding (`dst-jpg_e35`) instructs the CDN to serve the
    /// original resolution. Crucially, `stp` is NOT part of the `oh`/`oe` URL
    /// signature, so modifying it does not break the signed URL.
    private func upgradeImageURL(_ urlString: String) -> String {
        // Fast path: avoid URLComponents parsing for URLs that can't be upgraded.
        guard urlString.contains("stp=") else { return urlString }
        guard var components = URLComponents(string: urlString),
              let host = components.host,
              host.contains("cdninstagram.com") || host.contains("fbcdn.net") else {
            return urlString
        }
        guard var queryItems = components.queryItems else { return urlString }

        var modified = false
        for (index, item) in queryItems.enumerated() where item.name == "stp" {
            guard let value = item.value else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let cleaned = Self.stpSizeDirectivePattern.stringByReplacingMatches(
                in: value, range: range, withTemplate: ""
            )
            if cleaned != value {
                queryItems[index] = URLQueryItem(name: "stp", value: cleaned)
                modified = true
            }
        }

        guard modified else { return urlString }
        components.queryItems = queryItems
        return components.url?.absoluteString ?? urlString
    }

    // MARK: - Download Media File

    func downloadMediaData(from urlString: String) async throws -> Data {
        // No rate limiting for CDN downloads — these are pre-signed URLs
        // that don't count against Instagram's API rate limit.

        // Try CDN URL upgrade for full resolution, unless the latch says it's broken.
        if cdnUpgradeState != .broken {
            let upgraded = upgradeImageURL(urlString)
            if upgraded != urlString {
                do {
                    let data = try await performCDNDownload(from: upgraded)
                    if cdnUpgradeState != .works {
                        cdnUpgradeState = .works
                        cdnUpgradeFailureCount = 0
                        log.info("CDN URL upgrade works — downloading original-resolution images", context: "resolution")
                    }
                    return data
                } catch {
                    // Only latch to `.broken` after repeated failures — a single
                    // transient network error shouldn't permanently disable
                    // upgrades for the whole session. Once we've seen `.works`
                    // at least once, we never latch off.
                    if cdnUpgradeState == .untested {
                        cdnUpgradeFailureCount += 1
                        if cdnUpgradeFailureCount >= cdnUpgradeFailureThreshold {
                            cdnUpgradeState = .broken
                            log.warn("CDN URL upgrade rejected \(cdnUpgradeFailureCount)× — using API-provided URLs as-is", context: "resolution")
                        }
                    }
                    // Fall through to original URL
                }
            }
        }

        return try await performCDNDownload(from: urlString)
    }

    /// Raw CDN download without any URL rewriting.
    ///
    /// IMPORTANT (v1.5.13): the Accept header explicitly prefers JPEG + MP4.
    /// v1.5.12 sent `image/avif,image/webp,image/apng,...` which matched what
    /// Chrome actually asks for, but Instagram's CDN honored it and served
    /// WebP/AVIF bytes — which then got saved with the storage layer's
    /// hardcoded `.jpg` extension, producing "damaged" files at the correct
    /// resolution. Forcing `image/jpeg` first makes the CDN serve JPEG so the
    /// extension matches the content.
    ///
    /// Image responses are additionally validated against the JPEG magic
    /// bytes (`FF D8 FF`). If a CDN-upgraded URL still returns non-JPEG
    /// bytes, this throws, and `downloadMediaData` falls back to the
    /// original (non-upgraded) URL.
    private func performCDNDownload(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/jpeg,video/mp4,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log.warn("CDN download got non-HTTP response for URL: \(String(urlString.prefix(120)))", context: "download")
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "(none)"

        guard httpResponse.statusCode == 200 else {
            log.warn("CDN download HTTP \(httpResponse.statusCode) ct=\(contentType) url: \(String(urlString.prefix(120)))", context: "download")
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        guard data.count > 100 else {
            log.warn("CDN download suspiciously small (\(data.count) bytes) ct=\(contentType)", context: "download")
            throw InstagramError.parsingError("Downloaded file is too small, likely an error page")
        }

        // If the server claims it's an image, require JPEG. StorageManager hardcodes
        // `.jpg` for all non-video media, so any other format (WebP/AVIF/PNG) would
        // produce an unreadable file — exactly the "damaged but proper resolution"
        // symptom seen in v1.5.12.
        if contentType.hasPrefix("image/") {
            let isJPEG = data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
            if !isJPEG {
                let firstBytes = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                log.warn("CDN returned non-JPEG image (\(data.count) bytes, ct=\(contentType), magic=[\(firstBytes)]) url: \(String(urlString.prefix(120)))", context: "download")
                throw InstagramError.parsingError("CDN returned \(contentType) instead of JPEG")
            }
        }

        return data
    }
}

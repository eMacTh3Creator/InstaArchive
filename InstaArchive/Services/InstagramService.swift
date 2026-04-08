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
            return "Could not establish a session with Instagram. Try again later."
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

    private let session: URLSession
    private let baseURL = "https://www.instagram.com"
    private let igAppId = "936619743392459"

    // Rate limiting
    private var lastRequestTime: Date?
    private let minimumRequestInterval: TimeInterval = 2.5

    // Session state
    private var csrfToken: String?
    private var sessionInitialized = false
    private var cachedUserIds: [String: String] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive"
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
            // We have login cookies — extract CSRF token from them
            for cookie in existingCookies where cookie.name == "csrftoken" && cookie.domain.contains("instagram") {
                csrfToken = cookie.value
            }
            if csrfToken == nil {
                csrfToken = generateCSRFToken()
            }
            sessionInitialized = true
            print("[InstaArchive] Session initialized from existing login cookies (authenticated)")
            return
        }

        await waitForRateLimit()

        guard let url = URL(string: baseURL + "/") else {
            throw InstagramError.sessionError
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")

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

            let isAuthenticated = (HTTPCookieStorage.shared.cookies ?? []).contains {
                $0.name == "sessionid" && $0.domain.contains("instagram") && !$0.value.isEmpty
            }

            sessionInitialized = true
            print("[InstaArchive] Session initialized, CSRF: \(csrfToken != nil ? "yes" : "no"), authenticated: \(isAuthenticated)")
        } catch {
            print("[InstaArchive] Failed to initialize session: \(error)")
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
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("instagram.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - Rate Limiting

    private func waitForRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minimumRequestInterval {
                let delay = minimumRequestInterval - elapsed
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    // MARK: - Common Request Builder

    private func makeAPIRequest(url: URL, referer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(igAppId, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(csrfToken ?? "", forHTTPHeaderField: "X-CSRFToken")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer ?? "https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        return request
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        print("[InstaArchive] Profile info response status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            throw InstagramError.profileNotFound
        case 429:
            throw InstagramError.rateLimited
        case 401, 403:
            resetSession()
            try await ensureSession()
            return try await fetchProfileInfoRetry(username: username)
        default:
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

        if httpResponse.statusCode == 200 {
            return try parseProfileInfo(from: data)
        }

        return try await fetchProfileInfoFromPage(username: username)
    }

    private func parseProfileInfo(from data: Data) throws -> InstagramProfileInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = json["data"] as? [String: Any],
              let user = userData["user"] as? [String: Any] else {
            throw InstagramError.parsingError("Could not parse API profile response")
        }

        let username = user["username"] as? String ?? ""
        let userId = user["id"] as? String ?? user["pk"] as? String ?? ""
        let fullName = user["full_name"] as? String ?? username
        let biography = user["biography"] as? String ?? ""
        let profilePicURL = user["profile_pic_url_hd"] as? String
            ?? user["profile_pic_url"] as? String ?? ""
        let isPrivate = user["is_private"] as? Bool ?? false

        let edgeOwner = user["edge_owner_to_timeline_media"] as? [String: Any]
        let postCount = edgeOwner?["count"] as? Int ?? 0

        let edgeFollowers = user["edge_followed_by"] as? [String: Any]
        let followerCount = edgeFollowers?["count"] as? Int ?? 0

        if !userId.isEmpty {
            cachedUserIds[username] = userId
        }

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

        let urlString = "\(baseURL)/\(username)/"
        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 404 {
            throw InstagramError.profileNotFound
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw InstagramError.parsingError("Could not decode profile page")
        }

        if let info = try? extractFromJsonLD(html: html, username: username) {
            return info
        }
        if let info = try? extractFromAdditionalData(html: html, username: username) {
            return info
        }
        if let info = try? extractFromMetaTags(html: html, username: username) {
            return info
        }

        throw InstagramError.parsingError("Could not extract profile data from page")
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
                print("[InstaArchive] fetchRecentMedia failed on page \(allMedia.count / 33 + 1): \(error)")
                break
            }

            if result.media.isEmpty {
                print("[InstaArchive] Got empty page, stopping pagination")
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
                    print("[InstaArchive] Two consecutive pages of known items, stopping")
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
                print("[InstaArchive] Hit safety cap of 5000 items for @\(username)")
                break
            }

            print("[InstaArchive] Page complete: \(newOnThisPage) items, total so far: \(allMedia.count), hasMore: \(hasMore)")
        }

        print("[InstaArchive] Fetched \(allMedia.count) total media items for @\(username) via \(workingStrategy ?? "unknown")")
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
            print("[InstaArchive] Preferred strategy '\(strategy)' stopped working, trying all")
            workingStrategy = nil
        }

        // Strategy 1: v1 API
        do {
            let result = try await fetchMediaViaAPI(username: username, cursor: cursor)
            if !result.media.isEmpty {
                workingStrategy = "v1"
                print("[InstaArchive] v1 API returned \(result.media.count) items (hasMore: \(result.hasMore))")
                return result
            } else {
                print("[InstaArchive] v1 API returned 0 items")
            }
        } catch {
            print("[InstaArchive] v1 API failed: \(error.localizedDescription)")
        }

        // Strategy 2: GraphQL
        do {
            let result = try await fetchMediaViaGraphQL(username: username, cursor: cursor)
            if !result.media.isEmpty {
                workingStrategy = "graphql"
                print("[InstaArchive] GraphQL returned \(result.media.count) items (hasMore: \(result.hasMore))")
                return result
            } else {
                print("[InstaArchive] GraphQL returned 0 items")
            }
        } catch {
            print("[InstaArchive] GraphQL failed: \(error.localizedDescription)")
        }

        // Strategy 3: HTML scraping + per-post fetching (first page only)
        if cursor == nil {
            let result = try await fetchMediaFromProfilePage(username: username)
            if !result.media.isEmpty {
                workingStrategy = "html"
                print("[InstaArchive] HTML scraping returned \(result.media.count) items")
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
            print("[InstaArchive] Stories API returned status \((response as? HTTPURLResponse)?.statusCode ?? 0) for @\(username)")
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
            if isVideo, let videoURL = (item["video_resources"] as? [[String: Any]])?.first?["src"] as? String {
                mediaURLs.append(videoURL)
            } else if isVideo, let videoURL = item["video_url"] as? String {
                mediaURLs.append(videoURL)
            } else if let displayURL = item["display_url"] as? String {
                mediaURLs.append(displayURL)
            } else if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                      let url = candidates.first?["url"] as? String {
                mediaURLs.append(url)
            }

            guard !mediaURLs.isEmpty else { continue }

            media.append(DiscoveredMedia(
                instagramId: "story_\(storyId)",
                mediaType: .story,
                mediaURLs: mediaURLs,
                thumbnailURL: item["display_url"] as? String,
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
               let bestVideo = videoVersions.first,
               let videoURL = bestVideo["url"] as? String {
                mediaURLs.append(videoURL)
            } else if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                      let bestImage = candidates.first,
                      let imageURL = bestImage["url"] as? String {
                mediaURLs.append(imageURL)
            }

            guard !mediaURLs.isEmpty else { continue }

            let thumbnailURL = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String

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

        print("[InstaArchive] Found \(media.count) stories for @\(username)")
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
            print("[InstaArchive] No highlights found for @\(username)")
            return []
        }

        print("[InstaArchive] Found \(highlightIds.count) highlight reels for @\(username)")

        // Step 2: Fetch items from each highlight reel
        var allMedia: [DiscoveredMedia] = []
        for highlightId in highlightIds {
            let items = try await fetchHighlightReelItems(highlightId: highlightId, username: username)
            allMedia.append(contentsOf: items)
        }

        print("[InstaArchive] Fetched \(allMedia.count) total highlight items for @\(username)")
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
               let bestVideo = videoVersions.first,
               let videoURL = bestVideo["url"] as? String {
                mediaURLs.append(videoURL)
            } else if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                      let bestImage = candidates.first,
                      let imageURL = bestImage["url"] as? String {
                mediaURLs.append(imageURL)
            }

            // GraphQL format
            if mediaURLs.isEmpty {
                if isVideo, let videoURL = item["video_url"] as? String {
                    mediaURLs.append(videoURL)
                } else if let displayURL = item["display_url"] as? String {
                    mediaURLs.append(displayURL)
                }
            }

            guard !mediaURLs.isEmpty else { continue }

            let thumbnailURL = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String
                ?? item["display_url"] as? String

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

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[InstaArchive] Feed API returned status \(statusCode)")
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
                       let bestVideo = videoVersions.first,
                       let videoURL = bestVideo["url"] as? String {
                        mediaURLs.append(videoURL)
                    } else if let candidates = (carouselItem["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                              let bestImage = candidates.first,
                              let imageURL = bestImage["url"] as? String {
                        mediaURLs.append(imageURL)
                    }
                }
                thumbnailURL = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String
            } else if isVideo {
                if let videoVersions = item["video_versions"] as? [[String: Any]],
                   let bestVideo = videoVersions.first,
                   let videoURL = bestVideo["url"] as? String {
                    mediaURLs.append(videoURL)
                }
                let productType = item["product_type"] as? String ?? ""
                itemMediaType = productType == "clips" ? .reel : .video
                thumbnailURL = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String
            } else {
                if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                   let bestImage = candidates.first,
                   let imageURL = bestImage["url"] as? String {
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

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        return try parseGraphQLMediaResponse(from: data, username: username)
    }

    private func parseGraphQLMediaResponse(from data: Data, username: String) throws -> (media: [DiscoveredMedia], nextCursor: String?, hasMore: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
                    } else if let displayURL = sidecarNode["display_url"] as? String {
                        mediaURLs.append(displayURL)
                    }
                }
            }
        } else if let carouselMedia = node["carousel_media"] as? [[String: Any]] {
            for item in carouselMedia {
                if let videoVersions = item["video_versions"] as? [[String: Any]],
                   let url = videoVersions.first?["url"] as? String {
                    mediaURLs.append(url)
                } else if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                          let url = candidates.first?["url"] as? String {
                    mediaURLs.append(url)
                }
            }
        } else if isVideo, let videoURL = node["video_url"] as? String {
            mediaURLs.append(videoURL)
        } else if let displayURL = node["display_url"] as? String {
            mediaURLs.append(displayURL)
        } else if let candidates = (node["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                  let url = candidates.first?["url"] as? String {
            mediaURLs.append(url)
        }

        guard !mediaURLs.isEmpty else { return nil }

        let captionEdges = (node["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]]
        let caption = (captionEdges?.first?["node"] as? [String: Any])?["text"] as? String
            ?? (node["caption"] as? [String: Any])?["text"] as? String

        let thumbnailURL = node["thumbnail_src"] as? String
            ?? node["display_url"] as? String
            ?? ((node["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String

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
            print("[InstaArchive] Extracted \(embeddedMedia.count) items from embedded JSON")
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

                    if let displayURL = extractURLFromContext(context, key: "display_url") {
                        let isVideo = context.contains("\"is_video\":true")
                        let timestamp = extractTimestamp(from: context) ?? Date().timeIntervalSince1970

                        var mediaURLs = [displayURL]
                        if isVideo, let videoURL = extractURLFromContext(context, key: "video_url") {
                            mediaURLs = [videoURL]
                        }

                        discoveredMedia.append(DiscoveredMedia(
                            instagramId: shortcode,
                            mediaType: isVideo ? .video : .post,
                            mediaURLs: mediaURLs,
                            thumbnailURL: displayURL,
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
            print("[InstaArchive] Fetching \(missingShortcodes.count) individual posts by shortcode")
            for shortcode in missingShortcodes {
                if let media = try? await fetchSinglePost(shortcode: shortcode) {
                    discoveredMedia.append(media)
                }
            }
        }

        print("[InstaArchive] Profile page total: \(discoveredMedia.count) items from \(foundShortcodes.count) shortcodes")
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
                           let bestVideo = videoVersions.first,
                           let videoURL = bestVideo["url"] as? String {
                            mediaURLs.append(videoURL)
                        } else if let candidates = (carouselItem["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                                  let bestImage = candidates.first,
                                  let imageURL = bestImage["url"] as? String {
                            mediaURLs.append(imageURL)
                        }
                    }
                } else if isVideo {
                    if let videoVersions = item["video_versions"] as? [[String: Any]],
                       let bestVideo = videoVersions.first,
                       let videoURL = bestVideo["url"] as? String {
                        mediaURLs.append(videoURL)
                    }
                    let productType = item["product_type"] as? String ?? ""
                    itemMediaType = productType == "clips" ? .reel : .video
                } else {
                    if let candidates = (item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]],
                       let bestImage = candidates.first,
                       let imageURL = bestImage["url"] as? String {
                        mediaURLs.append(imageURL)
                    }
                }

                if !mediaURLs.isEmpty {
                    let thumbnailURL = ((item["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["url"] as? String
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
            print("[InstaArchive] v1 media info failed for \(shortcode): \(error.localizedDescription)")
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
        } else if let image = ogImage, !image.isEmpty {
            mediaURLs.append(image)
        }

        // Also try embedded JSON
        if mediaURLs.isEmpty || !isVideo {
            if let displayURL = extractURLFromHTML(html, key: "display_url") {
                if mediaURLs.isEmpty { mediaURLs.append(displayURL) }
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

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let userData = json["data"] as? [String: Any],
           let user = userData["user"] as? [String: Any],
           let userId = user["id"] as? String ?? user["pk"] as? String {
            cachedUserIds[username] = userId
            return userId
        }

        throw InstagramError.parsingError("Could not resolve user ID for @\(username)")
    }

    // MARK: - Download Media File

    func downloadMediaData(from urlString: String) async throws -> Data {
        // No rate limiting for CDN downloads — these are pre-signed URLs
        // that don't count against Instagram's API rate limit.

        guard let url = URL(string: urlString) else {
            throw InstagramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[InstaArchive] Download failed with status \(statusCode) for URL: \(urlString.prefix(80))...")
            throw InstagramError.networkError(URLError(.badServerResponse))
        }

        guard data.count > 100 else {
            print("[InstaArchive] Downloaded data suspiciously small (\(data.count) bytes)")
            throw InstagramError.parsingError("Downloaded file is too small, likely an error page")
        }

        return data
    }
}

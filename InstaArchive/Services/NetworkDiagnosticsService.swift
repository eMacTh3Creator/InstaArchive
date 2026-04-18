import Foundation
import SwiftUI

enum NetworkDiagnosticsLevel: String {
    case idle
    case ok
    case warning
    case error
}

struct NetworkProbeResult {
    let modeLabel: String
    let ignoreSystemProxies: Bool
    let success: Bool
    let statusCode: Int?
    let detail: String
    let durationMilliseconds: Int

    var webPayload: [String: Any] {
        [
            "modeLabel": modeLabel,
            "ignoreSystemProxies": ignoreSystemProxies,
            "success": success,
            "statusCode": statusCode as Any,
            "detail": detail,
            "durationMilliseconds": durationMilliseconds
        ]
    }
}

struct NetworkDiagnosticsSnapshot {
    let level: NetworkDiagnosticsLevel
    let title: String
    let summary: String
    let recommendation: String?
    let checkedAt: Date?
    let proxySummary: String
    let proxyKeys: [String]
    let currentProbe: NetworkProbeResult?
    let alternateProbe: NetworkProbeResult?
    let suggestedIgnoreSystemProxies: Bool?

    static let idle = NetworkDiagnosticsSnapshot(
        level: .idle,
        title: "Diagnostics Not Run Yet",
        summary: "Run diagnostics to compare InstaArchive's normal network path against proxy bypass mode.",
        recommendation: nil,
        checkedAt: nil,
        proxySummary: "No diagnostics have been collected yet.",
        proxyKeys: [],
        currentProbe: nil,
        alternateProbe: nil,
        suggestedIgnoreSystemProxies: nil
    )

    var shouldWarnUser: Bool {
        level == .warning || level == .error
    }

    var webPayload: [String: Any] {
        [
            "level": level.rawValue,
            "title": title,
            "summary": summary,
            "recommendation": recommendation as Any,
            "checkedAt": checkedAt?.ISO8601Format() as Any,
            "proxySummary": proxySummary,
            "proxyKeys": proxyKeys,
            "currentProbe": currentProbe?.webPayload as Any,
            "alternateProbe": alternateProbe?.webPayload as Any,
            "suggestedIgnoreSystemProxies": suggestedIgnoreSystemProxies as Any,
            "shouldWarnUser": shouldWarnUser
        ]
    }
}

final class NetworkDiagnosticsService: ObservableObject {
    static let shared = NetworkDiagnosticsService()

    @Published private(set) var snapshot: NetworkDiagnosticsSnapshot = .idle
    @Published private(set) var isRunning = false

    private init() {}

    func refreshIfStale(maxAge: TimeInterval = 600) {
        if Thread.isMainThread {
            refreshIfStaleOnMain(maxAge: maxAge)
        } else {
            DispatchQueue.main.async {
                self.refreshIfStaleOnMain(maxAge: maxAge)
            }
        }
    }

    func refresh() {
        if Thread.isMainThread {
            startRefreshOnMain()
        } else {
            DispatchQueue.main.async {
                self.startRefreshOnMain()
            }
        }
    }

    private func refreshIfStaleOnMain(maxAge: TimeInterval) {
        guard !isRunning else { return }
        if let checkedAt = snapshot.checkedAt,
           Date().timeIntervalSince(checkedAt) < maxAge {
            return
        }
        startRefreshOnMain()
    }

    private func startRefreshOnMain() {
        guard !isRunning else { return }
        isRunning = true

        Task.detached(priority: .utility) {
            let snapshot = await InstagramService.shared.runConnectivityDiagnostics()
            await MainActor.run {
                self.snapshot = snapshot
                self.isRunning = false
            }
        }
    }
}

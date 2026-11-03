import Foundation
import Observation

struct PR: Decodable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let createdAt: Date
    let headRefOid: String
    let baseRefName: String
    let reviewDecision: String?
    let bodyHTML: String
    let author: Login?
    let repository: Repo
    let commits: Commits

    struct Login: Decodable { let login: String }
    struct Repo: Decodable { let nameWithOwner: String }
    struct Commits: Decodable { let nodes: [Node] }
    struct Node: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let state: String; let contexts: Contexts }
    struct Contexts: Decodable { let nodes: [Check] }

    var authorLogin: String { author?.login ?? "ghost" }
    var repoName: String { repository.nameWithOwner.split(separator: "/").last.map(String.init) ?? "" }
    var ciState: String? { commits.nodes.first?.commit.statusCheckRollup?.state }
    var reviewKey: String { "\(id)@\(headRefOid)" }
    var checks: [Check] { commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? [] }
}

/// A CheckRun or a legacy StatusContext; GraphQL returns one shape or the other.
struct Check: Decodable {
    let name: String?, conclusion: String?, status: String?, detailsUrl: URL?
    let context: String?, state: String?, targetUrl: URL?

    enum Bucket { case passed, failed, running }

    var title: String { name ?? context ?? "?" }
    var link: URL? { detailsUrl ?? targetUrl }
    var bucket: Bucket {
        switch conclusion ?? state {
        case "SUCCESS", "NEUTRAL", "SKIPPED": .passed
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": .failed
        default: .running
        }
    }
}

private let query = """
query {
  mine: search(query: "is:open is:pr author:@me archived:false sort:updated-desc", type: ISSUE, first: 50) { nodes { ...pr } }
  requested: search(query: "is:open is:pr user-review-requested:@me archived:false sort:updated-desc", type: ISSUE, first: 50) { nodes { ...pr } }
  dismissed: search(query: "is:open is:pr reviewed-by:@me review:required -author:@me archived:false sort:updated-desc", type: ISSUE, first: 50) { nodes { ...pr } }
}
fragment pr on PullRequest {
  id number title url isDraft createdAt headRefOid baseRefName reviewDecision bodyHTML
  author { login }
  repository { nameWithOwner }
  commits(last: 1) { nodes { commit { statusCheckRollup { state
    contexts(first: 100) { nodes {
      ... on CheckRun { name conclusion status detailsUrl }
      ... on StatusContext { context state targetUrl }
    } } } } } }
}
"""

private struct Response: Decodable {
    let data: Lists
    struct Lists: Decodable { let mine, requested, dismissed: Search }
    struct Search: Decodable { let nodes: [PR] }
}

struct GHError: LocalizedError {
    let errorDescription: String?
}

/// Runs a CLI off the main thread. A GUI app doesn't get the login shell's PATH, so Homebrew's bin is added.
func cli(_ args: [String]) async throws -> Data {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return cont.resume(throwing: error) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20 * 60) { if p.isRunning { p.terminate() } }
            // Drain both pipes concurrently before waiting: either one filling its buffer (gh's big
            // responses, codex's stderr progress log) blocks the child and deadlocks us.
            var errData = Data()
            let errDone = DispatchGroup()
            errDone.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                errDone.leave()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                cont.resume(returning: data)
            } else {
                let msg = String(data: errData.suffix(600), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(throwing: GHError(errorDescription: msg ?? "\(args[0]) exited \(p.terminationStatus)"))
            }
        }
    }
}

@Observable @MainActor
final class Store {
    var mine: [PR] = []
    var requested: [PR] = []
    var error: String?
    var updatedAt: Date?
    var refreshing = false
    var reviews: [String: ReviewState] = [:]
    private var reviewing = false
    private let reviewsFile = appSupport.appendingPathComponent("reviews.json")

    init() {
        try? FileManager.default.removeItem(at: workDir)
        if let data = try? Data(contentsOf: reviewsFile),
           let saved = try? JSONDecoder().decode([String: Review].self, from: data) {
            reviews = saved.mapValues { .done($0) }
        }
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await cli(["gh", "api", "graphql", "-f", "query=\(query)"])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lists = try decoder.decode(Response.self, from: data).data
            mine = lists.mine.nodes
            var seen = Set<String>()
            requested = (lists.requested.nodes + lists.dismissed.nodes).filter { seen.insert($0.id).inserted }
            error = nil
            updatedAt = .now
            for pr in requested where reviews[pr.reviewKey] == nil { reviews[pr.reviewKey] = .queued }
            pumpReviews()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ args: [String]) async {
        do { _ = try await cli(["gh"] + args) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    /// Submits the findings as a "changes requested" review. GitHub then drops the PR from the review-requested
    /// list; when the author re-requests, the new head SHA gets a fresh Codex run.
    func postFindings(_ pr: PR, _ review: Review) async {
        let inline: [String: Any] = [
            "commit_id": pr.headRefOid,
            "event": "REQUEST_CHANGES",
            "body": "Requesting changes, see the inline comments.",
            "comments": review.items.map { ["path": $0.file, "line": $0.line, "side": "RIGHT", "body": $0.why] },
        ]
        let summary: [String: Any] = [
            "commit_id": pr.headRefOid,
            "event": "REQUEST_CHANGES",
            "body": "Requesting changes:\n\n" + review.items.map { "- `\($0.file):\($0.line)` \($0.why)" }.joined(separator: "\n"),
        ]
        do {
            do {
                try await submitReview(pr, inline)
            } catch where error.localizedDescription.contains("422") {
                // A line outside the diff can't take an inline comment and GitHub rejects the whole review.
                try await submitReview(pr, summary)
            }
            var posted = review
            posted.postedAt = .now
            reviews[pr.reviewKey] = .done(posted)
            saveReviews()
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func submitReview(_ pr: PR, _ payload: [String: Any]) async throws {
        let file = appSupport.appendingPathComponent("review-payload.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        _ = try await cli(["gh", "api", "--method", "POST", "repos/\(pr.repository.nameWithOwner)/pulls/\(pr.number)/reviews",
                           "--input", file.path])
    }

    private func saveReviews() {
        let done = reviews.compactMapValues { if case .done(let r) = $0 { r } else { nil } }
        try? JSONEncoder().encode(done).write(to: reviewsFile)
    }

    func rerunReview(_ pr: PR) {
        reviews[pr.reviewKey] = .queued
        pumpReviews()
    }

    /// One review at a time: each is a multi-minute Codex run over a full checkout.
    private func pumpReviews() {
        guard !reviewing, let pr = requested.first(where: {
            if case .queued = reviews[$0.reviewKey] { true } else { false }
        }) else { return }
        reviewing = true
        reviews[pr.reviewKey] = .running
        Task {
            do {
                reviews[pr.reviewKey] = .done(try await codexReview(pr))
                saveReviews()
            } catch {
                reviews[pr.reviewKey] = .failed(error.localizedDescription)
            }
            reviewing = false
            pumpReviews()
        }
    }
}

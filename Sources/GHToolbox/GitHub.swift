import Foundation
import Observation

struct PR: Decodable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
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
  id number title url isDraft reviewDecision bodyHTML
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

/// Runs `gh` off the main thread. A GUI app doesn't get the login shell's PATH, so Homebrew's bin is added.
func gh(_ args: [String]) async throws -> Data {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["gh"] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return cont.resume(throwing: error) }
            // Drain before waiting: a body-heavy response overflows the pipe buffer and would deadlock.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                cont.resume(returning: data)
            } else {
                let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(throwing: GHError(errorDescription: msg ?? "gh exited \(p.terminationStatus)"))
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

    init() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func refresh() async {
        do {
            let data = try await gh(["api", "graphql", "-f", "query=\(query)"])
            let lists = try JSONDecoder().decode(Response.self, from: data).data
            mine = lists.mine.nodes
            var seen = Set<String>()
            requested = (lists.requested.nodes + lists.dismissed.nodes).filter { seen.insert($0.id).inserted }
            error = nil
            updatedAt = .now
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ args: [String]) async {
        do { _ = try await gh(args) } catch { self.error = error.localizedDescription }
        await refresh()
    }
}

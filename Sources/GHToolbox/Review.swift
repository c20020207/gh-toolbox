import Foundation

struct Review: Codable {
    let verdict: String
    let summary: String
    let items: [Item]

    struct Item: Codable {
        let file: String
        let line: Int
        let why: String
    }
}

enum ReviewState {
    case queued, running
    case done(Review)
    case failed(String)
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("GHToolbox")
let workDir = appSupport.appendingPathComponent("work")

private let schema = """
{"type":"object","additionalProperties":false,"required":["verdict","summary","items"],
 "properties":{"verdict":{"type":"string","enum":["ok","look"]},"summary":{"type":"string"},
  "items":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["file","line","why"],
   "properties":{"file":{"type":"string"},"line":{"type":"integer"},"why":{"type":"string"}}}}}}
"""

/// Checks the PR head out into a throwaway worktree of a blobless clone the app owns, then asks Codex
/// (read-only sandbox) for a structured verdict.
func codexReview(_ pr: PR) async throws -> Review {
    let repo = appSupport.appendingPathComponent("repos/\(pr.repository.nameWithOwner)")
    if !FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
        try FileManager.default.createDirectory(at: repo.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await cli(["git", "clone", "-q", "--filter=blob:none", "--no-checkout",
                           "https://github.com/\(pr.repository.nameWithOwner).git", repo.path])
    }
    let git = ["git", "-C", repo.path]
    let base = pr.baseRefName
    _ = try await cli(git + ["fetch", "-q", "origin", "+refs/heads/\(base):refs/remotes/origin/\(base)", "pull/\(pr.number)/head"])

    let id = UUID().uuidString
    let work = workDir.appendingPathComponent(id)
    let out = workDir.appendingPathComponent("\(id).json")
    let schemaFile = workDir.appendingPathComponent("schema.json")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
    _ = try await cli(git + ["worktree", "prune"])
    _ = try await cli(git + ["worktree", "add", "-q", "--detach", work.path, pr.headRefOid])
    defer {
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: out)
    }

    let mergeBase = String(decoding: try await cli(git + ["merge-base", "origin/\(base)", pr.headRefOid]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = """
    You are pre-screening pull request #\(pr.number) "\(pr.title)" for a reviewer deciding whether to approve it. \
    The PR head is checked out in the current directory. Run `git diff \(mergeBase)...HEAD` to see the change \
    and read surrounding code as needed. If docs/review-rules.md exists, apply it. Flag only what a careful \
    reviewer must look at: correctness bugs, security or tenant-isolation issues, data loss, unsafe migrations, \
    risky logic without tests. Skip style and naming nits. verdict is "ok" when nothing needs a closer look, \
    otherwise "look" with one item per concern: file (repo-relative path), line (in the new version) and a one \
    or two sentence why. summary is one sentence on what the PR does.
    """
    _ = try await cli(["codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                       "--output-schema", schemaFile.path, "-o", out.path, "-C", work.path, prompt])
    return try JSONDecoder().decode(Review.self, from: Data(contentsOf: out))
}

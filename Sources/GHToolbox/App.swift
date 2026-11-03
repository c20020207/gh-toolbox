import SwiftUI
import WebKit

@main
struct GHToolboxApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environment(store)
        } label: {
            HStack {
                Image(systemName: "arrow.triangle.pull")
                if !store.requested.isEmpty { Text("\(store.requested.count)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var selection: String?

    private var selected: PR? {
        (store.requested + store.mine).first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Review requested") {
                        if store.requested.isEmpty {
                            Text("Nothing waiting on you").foregroundStyle(.secondary)
                        }
                        ForEach(store.requested) { PRRow(pr: $0, review: store.reviews[$0.reviewKey]) }
                    }
                    Section("My PRs") {
                        ForEach(store.mine) { PRRow(pr: $0) }
                    }
                }
                Divider()
                footer
            }
            .frame(width: 320)
            Divider()
            if let pr = selected {
                PRDetail(pr: pr, isMine: store.mine.contains { $0.id == pr.id })
            } else {
                Text("Select a PR").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 600)
    }

    private var footer: some View {
        HStack {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
            } else if let at = store.updatedAt {
                Text("Updated \(at, style: .relative) ago").foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(8)
    }
}

struct CIDot: View {
    let state: String?

    private var color: Color {
        switch state {
        case "SUCCESS": .green
        case "FAILURE", "ERROR": .red
        case "PENDING", "EXPECTED": .orange
        default: .gray.opacity(0.4)
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct PRRow: View {
    let pr: PR
    var review: ReviewState?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CIDot(state: pr.ciState)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title).lineLimit(2)
                (Text("\(pr.repoName)#\(String(pr.number)) · \(pr.authorLogin) · opened ")
                    + Text(pr.createdAt, format: .relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if pr.isDraft { Tag(text: "Draft", color: .gray) }
            switch review {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.mini)
            case .done(let r) where r.verdict == "ok": Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .done(let r): Tag(text: "\(r.items.count) to check", color: .orange)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case nil: EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PRDetail: View {
    @Environment(Store.self) private var store
    let pr: PR
    let isMine: Bool
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pr.title).font(.title3.bold()).textSelection(.enabled)
            HStack(spacing: 6) {
                (Text("\(pr.repository.nameWithOwner)#\(String(pr.number)) by \(pr.authorLogin), opened ")
                    + Text(pr.createdAt, format: .relative(presentation: .named))
                    + Text(" (\(pr.createdAt.formatted(date: .abbreviated, time: .omitted)))"))
                    .foregroundStyle(.secondary)
                if pr.isDraft { Tag(text: "Draft", color: .gray) }
                switch pr.reviewDecision {
                case "APPROVED": Tag(text: "Approved", color: .green)
                case "CHANGES_REQUESTED": Tag(text: "Changes requested", color: .red)
                default: EmptyView()
                }
            }
            checks
            actions
            if !isMine { codexReview }
            Divider()
            HTMLView(key: pr.id, html: pr.bodyHTML)
        }
        .padding(14)
    }

    private var checks: some View {
        let all = pr.checks
        let failed = all.filter { $0.bucket == .failed }
        let running = all.filter { $0.bucket == .running }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CIDot(state: pr.ciState)
                Text(all.isEmpty ? "No checks" :
                    "\(all.count - failed.count - running.count) passed · \(failed.count) failed · \(running.count) running")
                Link("All checks", destination: pr.url.appendingPathComponent("checks")).font(.caption)
            }
            ForEach(Array(failed.enumerated()), id: \.offset) { _, check in
                checkLink(check, icon: "xmark.circle.fill", color: .red)
            }
            ForEach(Array(running.prefix(5).enumerated()), id: \.offset) { _, check in
                checkLink(check, icon: "clock", color: .orange)
            }
        }
    }

    @ViewBuilder
    private func checkLink(_ check: Check, icon: String, color: Color) -> some View {
        let label = Label(check.title, systemImage: icon).foregroundStyle(color).font(.callout)
        if let url = check.link { Link(destination: url) { label } } else { label }
    }

    private var actions: some View {
        HStack {
            Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
            if isMine {
                Button(pr.isDraft ? "Ready for review" : "Convert to draft") {
                    perform(["pr", "ready", pr.url.absoluteString] + (pr.isDraft ? [] : ["--undo"]))
                }
                Button("Close PR", role: .destructive) { perform(["pr", "close", pr.url.absoluteString]) }
            } else {
                Button("Approve") { perform(["pr", "review", pr.url.absoluteString, "--approve"]) }
                    .buttonStyle(.borderedProminent)
            }
            if working { ProgressView().controlSize(.small) }
        }
        .disabled(working)
    }

    @ViewBuilder
    private var codexReview: some View {
        let state = store.reviews[pr.reviewKey]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch state {
                case .queued, nil:
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text("Codex review queued")
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Codex is reviewing, usually a few minutes")
                case .done(let r) where r.verdict == "ok":
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Codex found nothing that needs a closer look")
                case .done(let r):
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    Text("Codex flagged \(r.items.count) thing\(r.items.count == 1 ? "" : "s") to check")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Review failed: \(message)").lineLimit(2)
                }
                Spacer()
                switch state {
                case .done, .failed:
                    Button("Re-run") { store.rerunReview(pr) }.buttonStyle(.borderless).font(.caption)
                default: EmptyView()
                }
            }
            .font(.callout.weight(.medium))
            if case .done(let r) = state {
                Text(r.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(Array(r.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Link("\(item.file):\(String(item.line))", destination: blobURL(item))
                            .font(.caption.monospaced())
                        Text(item.why).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func blobURL(_ item: Review.Item) -> URL {
        URL(string: "https://github.com/\(pr.repository.nameWithOwner)/blob/\(pr.headRefOid)/\(item.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.file)#L\(item.line)")!
    }

    private func perform(_ args: [String]) {
        working = true
        Task {
            await store.run(args)
            working = false
        }
    }
}

/// Renders GitHub's own bodyHTML; links open in the default browser.
struct HTMLView: NSViewRepresentable {
    let key: String
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    // Keyed on the PR, not the HTML: image URLs carry a fresh JWT on every poll, which would reload and reset scroll.
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.loadHTMLString(style + html, baseURL: URL(string: "https://github.com"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var key: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private var style: String {
        """
        <meta name="color-scheme" content="light dark">
        <style>
        body { font: 13px/1.5 -apple-system, sans-serif; margin: 0 4px 16px; color: CanvasText; }
        a { color: #0969da; } @media (prefers-color-scheme: dark) { a { color: #4493f8; } }
        img { max-width: 100%; }
        code, pre { font: 12px ui-monospace, monospace; background: rgba(127,127,127,.12); border-radius: 4px; }
        code { padding: 1px 4px; } pre { padding: 8px; overflow: auto; } pre code { padding: 0; background: none; }
        table { border-collapse: collapse; } td, th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
        blockquote, .markdown-alert { margin: 0 0 8px; padding-left: 12px; border-left: 3px solid rgba(127,127,127,.4); }
        h1, h2, h3 { margin: 16px 0 8px; } h1 { font-size: 18px; } h2 { font-size: 16px; } h3 { font-size: 14px; }
        .octicon, .anchor { display: none; }
        </style>
        """
    }
}

import Foundation

/// Site-classification catalog: "is this URL/host focus or distract?"
///
/// Two layers, lowest first:
///   1. Bundled `sites.json` seed (ships with the app, shared by all users — PR new entries here).
///   2. User overrides at `~/Library/Application Support/CyberPet/site_overrides.json`,
///      written when the user explicitly marks a site or when an LLM auto-classifies one.
///
/// Lookup is host-substring match (case-insensitive). If a host is unknown and an LLM
/// classifier closure is set, the catalog fires it once per host and stores the answer
/// into overrides — next sample of the same host hits cache.
@MainActor
public final class SiteCatalog {
    /// Async classifier supplied by the host app (typically wrapped around an LLM call).
    /// Receives host (lowercased) and an optional page title; returns a label or nil if it
    /// cannot decide. Should NOT block; will be awaited from a Task.
    public typealias LLMClassify = @Sendable (String, String?) async -> ActivityLabel?

    public var llm: LLMClassify? = nil
    /// Notified after a host is auto-classified by the LLM (host, label, optional reason).
    public var onLearned: ((String, ActivityLabel) -> Void)? = nil

    private var seed: [(host: String, label: ActivityLabel)] = []
    private var learned: [String: ActivityLabel] = [:]
    private var pending: Set<String> = []
    private let overridesURL: URL

    public init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("CyberPet", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.overridesURL = dir.appendingPathComponent("site_overrides.json")

        loadSeed()
        loadOverrides()
    }

    /// Look up a host. Returns the catalog's label, or nil if unknown.
    public func lookup(host: String) -> ActivityLabel? {
        let h = host.lowercased()
        if let exact = learned[h] { return exact }
        for (key, label) in seed where h.contains(key) { return label }
        for (key, label) in learned where h.contains(key) { return label }
        return nil
    }

    /// If host is unknown AND an LLM classifier is configured, kick off async classification.
    /// Idempotent — at most one in-flight request per host.
    public func ensureClassified(host: String, title: String?) {
        let h = host.lowercased()
        if lookup(host: h) != nil { return }
        if pending.contains(h) { return }
        guard let llm else { return }
        pending.insert(h)
        Task { @MainActor in
            defer { self.pending.remove(h) }
            let label = await llm(h, title)
            if let label, label != .neutral {
                self.learned[h] = label
                self.persistOverrides()
                self.onLearned?(h, label)
            } else if label == .neutral {
                // Cache neutrals too so we don't re-ask every sample.
                self.learned[h] = .neutral
                self.persistOverrides()
            }
        }
    }

    /// Manually record a classification (e.g. user clicked "标记为合理" / "这是摸鱼").
    public func record(host: String, label: ActivityLabel) {
        learned[host.lowercased()] = label
        persistOverrides()
    }

    public var snapshot: (seed: Int, learned: [String: ActivityLabel]) {
        (seed.count, learned)
    }

    /// Read-only access to the bundled seed entries (sorted by host) for UI display.
    public var seedEntries: [(host: String, label: ActivityLabel)] {
        seed.sorted { $0.host < $1.host }
    }

    // MARK: - Persistence

    private func loadSeed() {
        guard let url = Bundle.module.url(forResource: "sites", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        struct File: Decodable { let sites: [Entry] }
        struct Entry: Decodable { let host: String; let label: ActivityLabel }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        seed = f.sites.map { (host: $0.host.lowercased(), label: $0.label) }
    }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: overridesURL) else { return }
        if let dict = try? JSONDecoder().decode([String: ActivityLabel].self, from: data) {
            learned = dict
        }
    }

    private func persistOverrides() {
        guard let data = try? JSONEncoder().encode(learned) else { return }
        try? data.write(to: overridesURL, options: .atomic)
    }
}

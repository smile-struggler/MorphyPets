import Foundation

/// Manages the user's pet library on disk: ~/Library/Application Support/CyberPet/pets/<id>/
public final class PetLibrary {
    public static let codexPetsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/pets", isDirectory: true)

    public let storeDirectory: URL
    private let fm = FileManager.default

    public init(storeDirectory: URL? = nil) {
        if let storeDirectory {
            self.storeDirectory = storeDirectory
        } else {
            let appSupport = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            self.storeDirectory = (appSupport ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("CyberPet/pets", isDirectory: true)
        }
        try? fm.createDirectory(at: self.storeDirectory, withIntermediateDirectories: true)
    }

    private var orderFileURL: URL {
        storeDirectory.appendingPathComponent("_order.json")
    }

    private func loadOrder() -> [String] {
        guard let data = try? Data(contentsOf: orderFileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func saveOrder(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: orderFileURL, options: .atomic)
    }

    public func installedPets() -> [PetManifest] {
        guard let entries = try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let manifests = entries.compactMap { dir -> PetManifest? in
            guard dir.hasDirectoryPath else { return nil }
            return try? PetManifest.load(from: dir)
        }
        // Apply persisted display order; unknown IDs appended at the end alphabetically.
        let order = loadOrder()
        let byID = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        var out: [PetManifest] = []
        var seen: Set<String> = []
        for id in order {
            if let m = byID[id] { out.append(m); seen.insert(id) }
        }
        let leftover = manifests.filter { !seen.contains($0.id) }.sorted { $0.displayName < $1.displayName }
        out.append(contentsOf: leftover)
        return out
    }

    /// Persist a new display order. Pass the full ordered list of pet IDs.
    public func setOrder(_ ids: [String]) {
        saveOrder(ids)
    }

    /// Remove a pet from disk. Returns true if anything was deleted.
    @discardableResult
    public func uninstall(pet: PetManifest) -> Bool {
        let dir = directory(for: pet)
        guard fm.fileExists(atPath: dir.path) else { return false }
        try? fm.removeItem(at: dir)
        // Drop from order list if present.
        let order = loadOrder().filter { $0 != pet.id }
        saveOrder(order)
        return true
    }

    public func directory(for pet: PetManifest) -> URL {
        storeDirectory.appendingPathComponent(pet.id, isDirectory: true)
    }

    /// List Codex-installed pets available for import.
    public func discoverCodexPets() -> [(manifest: PetManifest, sourceDir: URL)] {
        guard fm.fileExists(atPath: Self.codexPetsDir.path),
              let entries = try? fm.contentsOfDirectory(at: Self.codexPetsDir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { dir in
            guard let manifest = try? PetManifest.load(from: dir) else { return nil }
            return (manifest, dir)
        }
    }

    /// Copy a pet directory (`pet.json` + spritesheet) into the store. Returns the installed manifest.
    @discardableResult
    public func importPet(from sourceDir: URL) throws -> PetManifest {
        let manifest = try PetManifest.load(from: sourceDir)
        let dest = storeDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: sourceDir, to: dest)
        return manifest
    }

    /// Ensure the bundled `ikun` fallback is present in the store.
    @discardableResult
    public func ensureBuiltinIkun(bundledAt bundledDir: URL?) throws -> PetManifest? {
        guard let bundledDir, fm.fileExists(atPath: bundledDir.path) else { return nil }
        let manifest = try PetManifest.load(from: bundledDir)
        let dest = storeDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        if !fm.fileExists(atPath: dest.path) {
            try fm.copyItem(at: bundledDir, to: dest)
        }
        return manifest
    }
}

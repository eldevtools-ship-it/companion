import Foundation

// MARK: - From Compagnon to Kumo
// The app was called Compagnon. On the first launch as Kumo, everything it kept under
// that name moves over, once, without losing anything:
// - settings (UserDefaults of the old identifier) are copied into Kumo's;
// - ~/Library/Application Support/Compagnon (notes, chats, relay) becomes …/Kumo, and the
//   old path stays as a link so the hooks in ~/.claude/settings.json keep working until
//   you update them from Settings (backup, diff, confirmation, as always);
// - Keychain secrets are moved by KeychainStore when it first reads them.

enum KumoMigration {
    static let legacyBundleID = "com.eldevtools.Compagnon"
    static let legacyFolderName = "Compagnon"
    private static let doneKey = "migratedFromCompagnon"

    /// Runs before anything reads settings or files (KumoApp.init).
    static func run() {
        migrateDefaults()
        migrateSupportFolder()
    }

    private static func migrateDefaults() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: doneKey) else { return }
        if let old = ud.persistentDomain(forName: legacyBundleID) {
            for (key, value) in old where ud.object(forKey: key) == nil {
                ud.set(value, forKey: key)
            }
            appendAppLog("migration.log", "settings: \(old.count) keys copied from \(legacyBundleID)")
        }
        ud.set(true, forKey: doneKey)
    }

    private static func migrateSupportFolder() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = base.appendingPathComponent("Kumo", isDirectory: true)
        // Already a link (migration done) or nothing to move
        let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        guard !oldIsLink, fm.fileExists(atPath: old.path) else { return }
        do {
            if fm.fileExists(atPath: new.path) {
                // Both exist (Kumo started once already): bring over what Kumo doesn't have
                for name in try fm.contentsOfDirectory(atPath: old.path)
                where !fm.fileExists(atPath: new.appendingPathComponent(name).path) {
                    try fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
                }
                try fm.removeItem(at: old)
            } else {
                try fm.moveItem(at: old, to: new)
            }
            try fm.createSymbolicLink(at: old, withDestinationURL: new)
            appendAppLog("migration.log", "support folder moved to \(new.path), link left at \(old.path)")
        } catch {
            appendAppLog("migration.log", "support folder: \(error.localizedDescription)")
        }
    }
}

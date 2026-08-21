import Foundation

/// Keeps on-disk dictation data readable only by its owner, and out of backups.
///
/// Everything Plainsay writes to disk is a verbatim record of something the
/// user said. `~/Library` being `drwx------` was the only thing keeping another
/// local account from reading it: the files themselves landed at the default
/// 0644 and the directories at 0755, and nothing marked them as excluded from
/// Time Machine — so the last hundred dictations were being copied into every
/// backup. Raised in an external review (#1).
enum PrivateFiles {
    /// 0700 for a directory, 0600 for a file — owner only, no group, no other.
    static func restrictToOwner(_ url: URL, isDirectory: Bool) {
        let perms: NSNumber = isDirectory ? 0o700 : 0o600
        try? FileManager.default.setAttributes(
            [.posixPermissions: perms], ofItemAtPath: url.path
        )
    }

    /// Marks the item so Time Machine and iCloud skip it.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Creates a directory that only the owner can enter, and that backups skip.
    static func makePrivateDirectory(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        // `createDirectory` only applies `attributes` to directories it
        // actually creates, so an existing one keeps whatever mode it had —
        // including the 0755 every install before this shipped with.
        restrictToOwner(url, isDirectory: true)
        excludeFromBackup(url)
    }

    /// Applies owner-only permissions to a file that was just written.
    ///
    /// Has to run *after* the write, not before: `Data.write(options: .atomic)`
    /// writes a temporary file and renames it over the destination, so any
    /// mode set on the old file is replaced by the temporary file's own.
    static func protectWrittenFile(_ url: URL) {
        restrictToOwner(url, isDirectory: false)
        excludeFromBackup(url)
    }
}

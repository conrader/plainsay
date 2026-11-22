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
    /// Returns whether the mode was set.
    @discardableResult
    static func restrictToOwner(_ url: URL, isDirectory: Bool) -> Bool {
        let perms: NSNumber = isDirectory ? 0o700 : 0o600
        return (try? FileManager.default.setAttributes(
            [.posixPermissions: perms], ofItemAtPath: url.path
        )) != nil
    }

    /// Marks the item so Time Machine and iCloud skip it. Returns whether that
    /// took; trivially true where there is no such backup to skip.
    @discardableResult
    static func excludeFromBackup(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        guard (try? url.setResourceValues(values)) != nil else { return false }
        return isExcludedFromBackup(url)
        #else
        // Time Machine and iCloud backup exclusion are Apple-only concepts.
        return true
        #endif
    }

    /// Whether Time Machine and iCloud skip the item, itself or via its folder.
    static func isExcludedFromBackup(_ url: URL) -> Bool {
        #if canImport(Darwin)
        func excluded(_ url: URL) -> Bool {
            var url = url
            url.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
            return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        }
        return excluded(url) || excluded(url.deletingLastPathComponent())
        #else
        return true
        #endif
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
    /// Has to run *after* the write, not before: an atomic write (here
    /// `Data.write(options: .atomic)` or `HistoryFile.replace`) renames a
    /// temporary file over the destination, so any mode set on the old file
    /// is replaced by the temporary file's own.
    ///
    /// Returns whether both took, so a caller holding transcripts can say so
    /// rather than assume it.
    @discardableResult
    static func protectWrittenFile(_ url: URL) -> Bool {
        let restricted = restrictToOwner(url, isDirectory: false)
        let excluded = excludeFromBackup(url)
        return restricted && excluded
    }
}

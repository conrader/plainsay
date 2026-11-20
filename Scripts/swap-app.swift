// The candidate is staged on the destination filesystem. A successful swap
// leaves the previous bundle at the staging path for the caller to remove.
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: swap-app.swift <candidate> <destination>")
}
let candidate = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
var info = stat()
guard lstat(candidate, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
    fail("App candidate must be a real directory")
}

let flags: UInt32
if lstat(destination, &info) == 0 {
    guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
        fail("App destination must be a real directory")
    }
    flags = UInt32(RENAME_SWAP)
} else if errno == ENOENT {
    flags = UInt32(RENAME_EXCL)
} else {
    fail("Could not inspect app destination: \(String(cString: strerror(errno)))")
}

guard renamex_np(candidate, destination, flags) == 0 else {
    fail("Could not atomically place app: \(String(cString: strerror(errno)))")
}

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let signature = Data(base64Encoded: arguments[2]),
      let publicKey = Data(base64Encoded: arguments[3]) else {
    FileHandle.standardError.write(Data("Missing Sparkle signature or public key.\n".utf8))
    exit(1)
}

let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("The update signature does not match the app's Sparkle public key.\n".utf8))
    exit(1)
}

import Darwin
import Security

// Read the lock state directly so the preflight never asks to unlock a keychain.
var keychain: SecKeychain?
var status: SecKeychainStatus = 0
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess,
      SecKeychainCopyDefault(&keychain) == errSecSuccess,
      let keychain,
      SecKeychainGetStatus(keychain, &status) == errSecSuccess,
      status & UInt32(kSecUnlockStateStatus) != 0 else {
    exit(1)
}

import Foundation

/// A small, non-cryptographic hash used for filenames and identity fingerprints.
///
/// FNV-1a, not SHA-256: nothing here is a security boundary — it only needs to distinguish
/// values, never resist a determined attacker — and pulling in swift-crypto (and BoringSSL)
/// for that would be a poor trade on Windows, where this core must build cleanly.
enum FingerprintHash {
    static func of(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

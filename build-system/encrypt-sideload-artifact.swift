import Foundation
import CryptoKit

// Authenticated encryption for artifacts produced in a public repository.
guard CommandLine.arguments.count == 2,
      let password = ProcessInfo.processInfo.environment["TELEGRAM_ARTIFACT_PASSWORD"],
      password.utf8.count >= 32 else {
    fatalError("Artifact path and a strong TELEGRAM_ARTIFACT_PASSWORD are required")
}
let path = CommandLine.arguments[1]
let key = SymmetricKey(data: SHA256.hash(data: Data(password.utf8)))
let plaintext = try Data(contentsOf: URL(fileURLWithPath: path))
let sealed = try AES.GCM.seal(plaintext, using: key)
guard let combined = sealed.combined,
      try AES.GCM.open(sealed, using: key) == plaintext else {
    fatalError("Artifact encryption verification failed")
}
// Format: TGIPA1 (6 bytes), 12-byte nonce, ciphertext, 16-byte authentication tag.
var output = Data("TGIPA1".utf8)
output.append(combined)
try output.write(to: URL(fileURLWithPath: path + ".enc"), options: .atomic)
print("Artifact encrypted and round-trip verified")

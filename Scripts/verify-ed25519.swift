// Verify a Sparkle EdDSA signature against a public key, the way an installed
// Tintpad will: swift Scripts/verify-ed25519.swift PUBLIC_KEY_B64 SIGNATURE_B64 FILE
//
// release.sh runs it with SUPublicEDKey from Info.plist before anything is
// published, so a DMG signed with the wrong private key (a stale export, another
// keychain account) fails here instead of in every user's updater. It only ever
// sees the public key. Exit 0 valid, 1 invalid, 2 usage or input error.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-ed25519.swift PUBLIC_KEY_B64 SIGNATURE_B64 FILE\n".utf8))
    exit(2)
}
guard let publicKeyData = Data(base64Encoded: args[1]), publicKeyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    FileHandle.standardError.write(Data("verify-ed25519: the public key is not 32 bytes of base64\n".utf8))
    exit(2)
}
guard let signature = Data(base64Encoded: args[2]), signature.count == 64 else {
    FileHandle.standardError.write(Data("verify-ed25519: the signature is not 64 bytes of base64\n".utf8))
    exit(2)
}
guard let message = FileManager.default.contents(atPath: args[3]) else {
    FileHandle.standardError.write(Data("verify-ed25519: cannot read \(args[3])\n".utf8))
    exit(2)
}
exit(publicKey.isValidSignature(signature, for: message) ? 0 : 1)

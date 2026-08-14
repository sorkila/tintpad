#!/usr/bin/env swift
import Foundation
import CryptoKit

// Tintpad Supporter license signer (LOCAL, manual fulfillment).
//
//   swift Scripts/sign-license.swift <buyer-email> [plan=pro]
//
// Signs {email,plan,iat} with the Ed25519 private key and prints a license key
// that verifies offline against the public key embedded in the app. Reads the
// private key from $TINTPAD_LICENSE_PRIVATE_KEY_B64, else secrets/license-private-key.txt.
// The key is self-verified against the public key before it is printed, so a
// printed key is guaranteed to activate in the app. Nothing leaves this machine.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let email = args.first, email.contains("@") else {
    die("usage: swift Scripts/sign-license.swift <buyer-email> [plan=pro]")
}
let plan = args.count > 1 ? args[1] : "pro"

// Pull the first valid base64 line that appears after a named marker.
func base64AfterMarker(_ text: String, _ marker: String) -> String? {
    let lines = text.components(separatedBy: .newlines)
    guard let i = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
    for line in lines[(i + 1)...] {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.count >= 43, !t.contains(" "), Data(base64Encoded: t) != nil { return t }
    }
    return nil
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let secretsURL = scriptDir.deletingLastPathComponent()
    .appendingPathComponent("secrets/license-private-key.txt")

var privB64 = ProcessInfo.processInfo.environment["TINTPAD_LICENSE_PRIVATE_KEY_B64"]
var pubB64 = "AjteldnV1GgE4Z0h4wxsHCoQT+rwSJoXLL/CWfp7m04="   // mirrors LicenseManager.swift
if privB64 == nil, let text = try? String(contentsOf: secretsURL, encoding: .utf8) {
    privB64 = base64AfterMarker(text, "PRIVATE_KEY_B64")
    if let p = base64AfterMarker(text, "PUBLIC_KEY_B64") { pubB64 = p }
}

guard let privB64, let privData = Data(base64Encoded: privB64),
      let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
    die("could not load the private key (set TINTPAD_LICENSE_PRIVATE_KEY_B64 or keep secrets/license-private-key.txt)")
}

// Build + sign the payload.
func jsonEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}
let iat = Int(Date().timeIntervalSince1970)
let payload = "{\"email\":\"\(jsonEscape(email))\",\"plan\":\"\(plan)\",\"iat\":\(iat)}"
let payloadData = Data(payload.utf8)
guard let sig = try? priv.signature(for: payloadData) else { die("signing failed") }
let key = payloadData.base64EncodedString() + "." + sig.base64EncodedString()

// Self-verify against the public key, so a printed key is guaranteed to activate.
guard let pubData = Data(base64Encoded: pubB64),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
      pub.isValidSignature(sig, for: payloadData) else {
    die("self-verification failed: private and public keys do not match. Key NOT issued.")
}

print("""

✓ Supporter key for \(email)  (plan: \(plan), issued \(iat))

\(key)

---- ready-to-send email --------------------------------
Subject: Your Tintpad Supporter key

Thank you for supporting Tintpad. Paste this into Settings, About,
"Paste supporter key", then Activate, to unlock tinted chips, the
selected repo's chip in its own hue:

\(key)

It verifies offline, so it works forever with no account. Enjoy, and thanks again.
Erik
---------------------------------------------------------
""")

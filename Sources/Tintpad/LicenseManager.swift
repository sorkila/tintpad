import CryptoKit
import Foundation

/// Offline Pro-license verification.
///
/// A license key is `base64(payload).base64(signature)` where `payload` is JSON
/// `{ "email": …, "plan": "pro", "iat": … }` and `signature` is an Ed25519
/// signature of the payload bytes. We verify against an embedded public key, so
/// no network call and no phone-home — matching the local-only ethos. The
/// private key lives only on the license server (see `secrets/`).
enum LicenseManager {
    /// Ed25519 public key (raw representation, base64). The matching private key
    /// is NOT in the repo — it signs licenses server-side.
    private static let publicKeyB64 = "AjteldnV1GgE4Z0h4wxsHCoQT+rwSJoXLL/CWfp7m04="

    struct LicenseInfo: Equatable {
        let email: String
        let plan: String
    }

    /// Returns license info iff the key is well-formed, correctly signed, and Pro.
    static func verify(_ key: String?) -> LicenseInfo? {
        guard let key, !key.isEmpty else { return nil }
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: parts[0]),
              let sigData = Data(base64Encoded: parts[1]),
              let pubData = Data(base64Encoded: publicKeyB64),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData)
        else { return nil }

        guard pubKey.isValidSignature(sigData, for: payloadData) else { return nil }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.plan.lowercased() == "pro"
        else { return nil }

        return LicenseInfo(email: payload.email, plan: payload.plan)
    }

    private struct Payload: Codable {
        let email: String
        let plan: String
        let iat: Int?
    }
}

/// The complete set of things a Supporter tip unlocks, which is one cosmetic
/// thing. This enum used to carry a case per capability (yolo mode, worktrees,
/// dispatch, the prompt library) from a Pro-tier model that was never shipped,
/// and every one of those gates was dead code sitting on a functional path.
///
/// It stays a single-case enum on purpose. `AppStore.allows` switches over it
/// exhaustively, with no `default`, so adding a case here fails to compile
/// until someone decides what it means. That makes "don't add functional
/// gates" a rule the compiler enforces rather than a comment people read.
enum ProFeature {
    case customTint

    var blurb: String {
        switch self {
        case .customTint: return "Tinted chips are a Supporter perk, thanks for chipping in"
        }
    }
}

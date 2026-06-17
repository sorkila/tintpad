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

/// Capabilities gated behind Pro.
enum ProFeature {
    case yoloMode
    case unlimitedAgents
    case promptLibrary
    case customTint
    case perRepoPreset
    case worktree
    case dispatch

    /// Benefit-led upsell copy (lead with the payoff, not the gate).
    var blurb: String {
        switch self {
        case .yoloMode:        return "YOLO mode skips every permission prompt"
        case .unlimitedAgents: return "Add as many agents as you like"
        case .promptLibrary:   return "Pro: save prompts and attach them at launch"
        case .customTint:      return "Pro: pick your own accent tint"
        case .perRepoPreset:   return "Pro: pin a default agent + mode per repo"
        case .worktree:        return "Pro: launch each agent on its own git worktree"
        case .dispatch:        return "Pro: run agents in the background with a notification"
        }
    }
}

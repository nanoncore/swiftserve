import Crypto
import CryptoExtras
import Foundation

public enum WebhookSignatureResult: Sendable, Equatable {
    case valid
    case missing
    case malformed
    case invalid
}

public struct WebhookSignatureVerifier: Sendable {
    private let secrets: [Data]

    public init(secret: String, previousSecret: String? = nil) {
        self.secrets = [secret, previousSecret].compactMap { $0 }.map { Data($0.utf8) }
    }

    public func verify(header: String?, body: Data) -> WebhookSignatureResult {
        guard let header else { return .missing }
        guard header.hasPrefix("sha256="), header.count == 71,
              let supplied = Self.hexData(String(header.dropFirst(7))) else {
            return .malformed
        }
        var valid: UInt8 = 0
        for secret in secrets {
            let key = SymmetricKey(data: secret)
            let expected = Data(HMAC<SHA256>.authenticationCode(for: body, using: key))
            valid |= Self.constantTimeEqual(supplied, expected) ? 1 : 0
        }
        return valid == 1 ? .valid : .invalid
    }

    public static func signature(secret: String, body: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "sha256=" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Compares every byte whenever lengths match. Neither digest influences
    /// early exit, avoiding the timing leak of normal collection equality.
    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

public protocol AppJWTSigning: Sendable {
    func token(now: Date) throws -> String
}

public struct AppJWTSigner: Sendable, AppJWTSigning {
    private let appID: String
    private let key: _RSA.Signing.PrivateKey

    public init(appID: String, privateKeyPEM: String) throws {
        self.appID = appID
        self.key = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }

    public func token(now: Date = Date()) throws -> String {
        let issued = Int(now.timeIntervalSince1970) - 30
        let expires = issued + 9 * 60
        let header = try Self.base64JSON(["alg": "RS256", "typ": "JWT"])
        let payload = try Self.base64JSON(["iat": issued, "exp": expires, "iss": appID])
        let input = header + "." + payload
        let signature = try key.signature(
            for: Data(input.utf8), padding: .insecurePKCS1v1_5).rawRepresentation
        return input + "." + Self.base64URL(signature)
    }

    private static func base64JSON(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

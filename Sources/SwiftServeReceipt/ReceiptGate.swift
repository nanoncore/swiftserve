public enum ReceiptGateThreshold: String, Codable, Sendable, Equatable, CaseIterable {
    case review
    case block

    /// Whether a completed receipt must fail the configured gate.
    public func fails(_ verdict: ReceiptVerdict) -> Bool {
        switch self {
        case .review:
            verdict == .review || verdict == .block
        case .block:
            verdict == .block
        }
    }
}

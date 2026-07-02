import Foundation

/// Manages a user-defined vocabulary list injected into ASR prompts
/// to bias recognition toward domain-specific terms (proper nouns, abbreviations, etc.).
class DictionaryService {
    static let shared = DictionaryService()
    private init() {
        seedDefaultTermsIfNeeded()
    }

    private let key = "userDictionary"
    private let defaultsVersionKey = "userDictionaryDefaultsVersion"
    private let currentDefaultsVersion = 3
    private let priorityTerms = ["KYC", "REKYC", "COS", "Compliance", "Risk"]

    /// Seeded on first install, then lightly migrated for new built-in priority terms.
    private let defaultTerms: String = [
        "KYC",
        "REKYC",
        "KYB",
        "COS",
        "Compliance",
        "Risk",
        "AML",
        "PSP",
        "MCC",
        "BIN",
        "3DS",
        "3DS2",
        "SCA",
        "AVS",
        "CVV",
        "PCI DSS",
        "ISO 8583",
        "Visa",
        "Mastercard",
        "American Express",
        "JCB",
        "Discover",
        "UnionPay",
        "tokenization",
        "detokenization",
        "idempotency",
        "chargeback",
        "false positive",
        "false decline",
        "soft decline",
        "hard decline",
        "FX rate",
        "risk engine",
        "fraud detection",
        "anti-money laundering",
        "payment orchestration",
        "merchant acquiring",
        "acquirer",
        "issuer",
        "card scheme",
        "拒付",
        "拒付申诉",
        "风控策略",
        "支付路由",
        "清结算",
        "对账",
        "通道健康度",
        "成功率优化",
    ].joined(separator: "\n")

    var defaultRawTerms: String {
        defaultTerms
    }

    func resetToDefaultTerms() {
        rawTerms = defaultTerms
    }

    private func seedDefaultTermsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            defaults.set(defaultTerms, forKey: key)
            defaults.set(currentDefaultsVersion, forKey: defaultsVersionKey)
            return
        }

        let version = defaults.integer(forKey: defaultsVersionKey)
        guard version < currentDefaultsVersion else { return }

        if shouldReplaceWithCuratedDefaults() {
            rawTerms = defaultTerms
        } else {
            prependMissingPriorityTerms()
        }
        defaults.set(currentDefaultsVersion, forKey: defaultsVersionKey)
    }

    private func shouldReplaceWithCuratedDefaults() -> Bool {
        let currentSet = Set(terms.map { $0.lowercased() })
        let legacyV2Set = Set(Self.legacyDefaultTerms.map { $0.lowercased() })
        let legacyV1Set = legacyV2Set.subtracting(["rekyc", "cos", "compliance", "risk"])
        return currentSet == legacyV1Set || currentSet == legacyV2Set
    }

    private func prependMissingPriorityTerms() {
        var existingTerms = rawTerms.components(separatedBy: .newlines)
        let existingSet = Set(existingTerms.map { term in term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let missingPriorityTerms = priorityTerms.filter { term in !existingSet.contains(term.lowercased()) }
        guard !missingPriorityTerms.isEmpty else { return }
        existingTerms.insert(contentsOf: missingPriorityTerms, at: 0)
        rawTerms = existingTerms.joined(separator: "\n")
    }

    private static let legacyDefaultTerms = [
        "third-party payment",
        "payment gateway",
        "payment orchestration",
        "merchant acquiring",
        "acquirer",
        "issuer",
        "card scheme",
        "Visa",
        "Mastercard",
        "American Express",
        "JCB",
        "Discover",
        "UnionPay",
        "PSP",
        "MCC",
        "BIN",
        "3DS",
        "3DS2",
        "SCA",
        "AVS",
        "CVV",
        "KYC",
        "REKYC",
        "KYB",
        "COS",
        "Compliance",
        "Risk",
        "tokenization",
        "detokenization",
        "PCI DSS",
        "chargeback",
        "dispute",
        "refund",
        "settlement",
        "reconciliation",
        "webhook",
        "idempotency",
        "risk engine",
        "fraud detection",
        "anti-money laundering",
        "AML",
        "cross-border",
        "FX rate",
        "authorization rate",
        "decline rate",
        "false positive",
        "false decline",
        "soft decline",
        "hard decline",
        "ISO 8583",
        "电子钱包",
        "支付路由",
        "收单行",
        "发卡行",
        "拒付",
        "拒付申诉",
        "风控策略",
        "清结算",
        "对账",
        "分账",
        "渠道成本",
        "通道健康度",
        "成功率优化",
        "支付转化率",
    ]

    var rawTerms: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    var terms: [String] {
        rawTerms.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Builds the final ASR prompt by appending dictionary terms to the user's base prompt.
    /// Total result is capped at 600 characters to stay within prompt limits.
    func buildPrompt(basePrompt: String) -> String {
        let dictPart = terms.prefix(40).joined(separator: "、")
        if dictPart.isEmpty { return basePrompt }
        let combined = basePrompt.isEmpty ? dictPart : "\(basePrompt) \(dictPart)"
        return String(combined.prefix(600))
    }
}

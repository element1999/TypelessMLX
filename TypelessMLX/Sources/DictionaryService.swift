import Foundation

/// Manages a user-defined vocabulary list injected into ASR prompts
/// to bias recognition toward domain-specific terms (proper nouns, abbreviations, etc.).
class DictionaryService {
    static let shared = DictionaryService()
    private init() {
        seedDefaultTermsIfNeeded()
    }

    private let key = "userDictionary"

    /// Only seeded on first install / first run (when the key doesn't exist yet).
    private let defaultTerms: String = [
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
        "KYC",
        "KYB",
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
    ].joined(separator: "\n")

    var defaultRawTerms: String {
        defaultTerms
    }

    func resetToDefaultTerms() {
        rawTerms = defaultTerms
    }

    private func seedDefaultTermsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(defaultTerms, forKey: key)
    }

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

import Foundation

enum FillerCleaner {
    static func clean(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?<![\p{Han}A-Za-z0-9])嗯+[，,。.!！?？、\s]*"#,
            #"(?<![\p{Han}A-Za-z0-9])呃+[，,。.!！?？、\s]*"#,
            #"(?<![\p{Han}A-Za-z0-9])额+[，,。.!！?？、\s]*"#,
            #"(?<![\p{Han}A-Za-z0-9])啊+[，,。.!！?？、\s]*"#,
            #"(?i)\b(uh+|um+|erm+|hmm+)\b[，,。.!！?？、\s]*"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([，,。.!！?？])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

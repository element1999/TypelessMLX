import Foundation

func assertEqual(_ actual: String, _ expected: String, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
}

assertEqual(FillerCleaner.clean("嗯，我觉得可以。"), "我觉得可以。", "leading Mandarin filler")
assertEqual(FillerCleaner.clean("呃 现在开始。"), "现在开始。", "leading er filler")
assertEqual(FillerCleaner.clean("啊，这个可以。"), "这个可以。", "leading ah filler")
assertEqual(FillerCleaner.clean("我嗯觉得可以。"), "我嗯觉得可以。", "embedded character is preserved")
assertEqual(FillerCleaner.clean("那个方案可以。"), "那个方案可以。", "semantic filler-like word is preserved")
assertEqual(FillerCleaner.clean("um I think this works."), "I think this works.", "English filler")

print("FillerCleanerTests passed")

import Testing
@testable import USBVerifyCore

@Test func goodNamesHaveNoProblem() {
    for name in ["game.pkg", "Notes 2026.txt", "a", ".hidden", "name.with.dots.mp4", "café.txt", "文件.mov"] {
        #expect(FileNameRules.problem(with: name) == nil, "\(name) should be fine")
    }
}

@Test func emptyNameIsRejected() {
    #expect(FileNameRules.problem(with: "") == "The name is empty.")
}

@Test func dotNamesAreRejected() {
    #expect(FileNameRules.problem(with: ".") != nil)
    #expect(FileNameRules.problem(with: "..") != nil)
}

@Test func controlCharactersAreRejected() {
    #expect(FileNameRules.problem(with: "a\u{0}b") != nil)
    #expect(FileNameRules.problem(with: "a\u{1F}b") != nil)
    #expect(FileNameRules.problem(with: "a\tb") != nil)
    #expect(FileNameRules.problem(with: "a\u{7F}b") != nil)
    #expect(FileNameRules.problem(with: "a\u{20}b") == nil)
}

@Test func everyForbiddenCharacterIsRejected() {
    for character in ["\"", "*", "/", ":", "<", ">", "?", "\\", "|"] {
        let reason = FileNameRules.problem(with: "a\(character)b")
        #expect(reason != nil, "\(character) should be rejected")
        #expect(reason?.contains(character) == true)
    }
}

@Test func forbiddenCharactersAreNotRejectedWhenAbsent() {
    #expect(FileNameRules.problem(with: "a-b_c(d)[e]{f}#g&h'i!j@k%l+m=n,o;p") == nil)
}

@Test func tooLongNameIsRejectedAtExactLimit() {
    let atLimit = String(repeating: "a", count: Defaults.maxFileNameUTF16Units)
    let overLimit = atLimit + "a"
    #expect(FileNameRules.problem(with: atLimit) == nil)
    #expect(FileNameRules.problem(with: overLimit) != nil)
}

@Test func lengthIsCountedInUTF16Units() {
    // Each emoji is 2 UTF-16 units, so 128 emoji is 256 units.
    let emoji = String(repeating: "😀", count: 127)
    #expect(emoji.utf16.count == 254)
    #expect(FileNameRules.problem(with: emoji) == nil)
    #expect(FileNameRules.problem(with: emoji + "😀") != nil)
}

@Test func trailingSpaceIsRejected() {
    #expect(FileNameRules.problem(with: "name ") == "The name ends with a space.")
}

@Test func trailingDotIsRejected() {
    #expect(FileNameRules.problem(with: "name.") == "The name ends with a dot.")
}

@Test func leadingSpaceIsAllowed() {
    #expect(FileNameRules.problem(with: " name") == nil)
}

@Test func suggestedNameKeepsGoodNames() {
    #expect(FileNameRules.suggestedName(for: "game.pkg") == "game.pkg")
}

@Test func suggestedNameReplacesForbiddenCharacters() {
    #expect(FileNameRules.suggestedName(for: "a:b*c?.txt") == "a_b_c_.txt")
    #expect(FileNameRules.suggestedName(for: "x\\y/z|\"<>.bin") == "x_y_z____.bin")
}

@Test func suggestedNameReplacesControlCharacters() {
    #expect(FileNameRules.suggestedName(for: "a\u{0}b\tc\u{7F}.txt") == "a_b_c_.txt")
}

@Test func suggestedNameRemovesTrailingSpacesAndDots() {
    #expect(FileNameRules.suggestedName(for: "report. ") == "report")
    #expect(FileNameRules.suggestedName(for: "report...") == "report")
}

@Test func suggestedNameOfOnlyDotsIsFile() {
    #expect(FileNameRules.suggestedName(for: "...") == "file")
    #expect(FileNameRules.suggestedName(for: ".") == "file")
    #expect(FileNameRules.suggestedName(for: "..") == "file")
}

@Test func suggestedNameOfOnlySpacesIsFile() {
    #expect(FileNameRules.suggestedName(for: "   ") == "file")
}

@Test func suggestedEmptyNameIsFile() {
    #expect(FileNameRules.suggestedName(for: "") == "file")
}

@Test func suggestedNameCutsLongNameKeepingExtension() {
    let name = String(repeating: "b", count: 400) + ".mp4"
    let result = FileNameRules.suggestedName(for: name)
    #expect(result.utf16.count == Defaults.maxFileNameUTF16Units)
    #expect(result.hasSuffix(".mp4"))
    #expect(result.hasPrefix("bbb"))
    #expect(FileNameRules.problem(with: result) == nil)
}

@Test func suggestedNameCutsLongNameWithoutExtension() {
    let result = FileNameRules.suggestedName(for: String(repeating: "c", count: 300))
    #expect(result.utf16.count == Defaults.maxFileNameUTF16Units)
    #expect(FileNameRules.problem(with: result) == nil)
}

@Test func suggestedNameDoesNotSplitEmoji() {
    let name = String(repeating: "😀", count: 200) + ".txt"
    let result = FileNameRules.suggestedName(for: name)
    #expect(result.utf16.count <= Defaults.maxFileNameUTF16Units)
    #expect(result.hasSuffix(".txt"))
    #expect(FileNameRules.problem(with: result) == nil)
}

@Test func suggestedNameWithHugeExtensionStillFitsLimit() {
    let name = "a." + String(repeating: "x", count: 300)
    let result = FileNameRules.suggestedName(for: name)
    #expect(!result.isEmpty)
    #expect(result.utf16.count <= Defaults.maxFileNameUTF16Units)
    #expect(FileNameRules.problem(with: result) == nil)
}

@Test func suggestedNameAlwaysPassesProblemCheck() {
    let samples = ["", ".", "..", "...", " ", "a:b", "x.", "\u{0}", String(repeating: "q/", count: 200),
                   String(repeating: "😀", count: 300), "name. .", "a" + String(repeating: ".", count: 260)]
    for sample in samples {
        let result = FileNameRules.suggestedName(for: sample)
        #expect(!result.isEmpty)
        #expect(FileNameRules.problem(with: result) == nil, "suggestion \(result) for \(sample.prefix(20)) is still bad")
    }
}

import GameImport
import Testing

@Suite("Import path validation")
struct ImportPathValidatorTests {
    let validator = ImportPathValidator()

    @Test("Backslashes become slashes and `.` components collapse")
    func normalises() throws {
        #expect(try validator.validate("www\\js\\rpg_core.js") == "www/js/rpg_core.js")
        #expect(try validator.validate("./game/./script.rpy") == "game/script.rpy")
        #expect(try validator.validate("a//b") == "a/b")
    }

    @Test("Traversal and absolute paths are rejected")
    func rejectsEscapes() {
        #expect(throws: ImportPathError.traversal) { try validator.validate("../etc/passwd") }
        #expect(throws: ImportPathError.traversal) { try validator.validate("game/../../x") }
        #expect(throws: ImportPathError.absolute) { try validator.validate("/var/mobile") }
        #expect(throws: ImportPathError.absolute) { try validator.validate("\\Windows\\System32") }
    }

    @Test("Control characters are rejected")
    func rejectsControlCharacters() {
        #expect(throws: ImportPathError.controlCharacter) { try validator.validate("a\u{01}b") }
        #expect(throws: ImportPathError.controlCharacter) { try validator.validate("a\nb") }
    }

    @Test("Windows reserved names and trailing dots/spaces are sanitised, not rejected")
    func sanitisesWindowsNames() throws {
        #expect(try validator.validate("CON") == "_CON")
        #expect(try validator.validate("data/nul.txt") == "data/_nul.txt")
        #expect(try validator.validate("com1.dat") == "_com1.dat")
        #expect(try validator.validate("Graphics/Actor1.png. ") == "Graphics/Actor1.png")
        #expect(try validator.validate("Graphics/...") == "Graphics/_")
    }

    @Test("Length limits are enforced")
    func limits() {
        var tight = ImportLimits()
        tight.maxPathComponents = 2
        tight.maxPathBytes = 8
        let v = ImportPathValidator(limits: tight)
        #expect(throws: ImportPathError.tooManyComponents) { try v.validate("a/b/c") }
        #expect(throws: ImportPathError.tooLong) { try v.validate("abcdefghij") }
        #expect(throws: ImportPathError.empty) { try v.validate("") }
        #expect(throws: ImportPathError.empty) { try v.validate("./") }
    }

    @Test("Output is NFC")
    func nfc() throws {
        let decomposed = "e\u{0301}.txt" // e + combining acute
        #expect(try validator.validate(decomposed) == "\u{00E9}.txt")
    }

    @Test("Default limits match §13.3")
    func defaults() {
        let d = ImportLimits.default
        #expect(d.maxUncompressedBytes == 16 << 30)
        #expect(d.maxEntries == 500_000)
        #expect(d.maxNestedArchives == 2)
        #expect(d.maxPathBytes == 1024)
        #expect(d.maxPathComponents == 64)
    }
}

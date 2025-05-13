//
//  VT100ScreenTests.swift
//  iTerm2
//
//  Created by George Nachman on 5/10/25.
//

import XCTest
@testable import iTerm2SharedARC

class VT100ScreenTests: XCTestCase {
    private var session = FakeSession()
    private func fiveByFourScreenWithThreeLinesOneWrapped() -> VT100Screen {
        let screen = VT100Screen()
        session.screen = screen
        screen.delegate = session
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.terminalEnabled = true
            screen.destructivelySetScreenWidth(5, height: 4, mutableState: mutableState)
            mutableState!.appendString(atCursor: "abcdefgh")
            mutableState!.appendCarriageReturnLineFeed()
            mutableState!.appendString(atCursor: "ijkl")
            mutableState!.appendCarriageReturnLineFeed()
        })
        return screen
    }

    private func fiveByNineScreenWithEmptyLineAtTop() -> VT100Screen {
        let screen = VT100Screen()
        session.screen = screen
        screen.delegate = session
        screen.performBlock(joinedThreads: { terminal, mutableState, _ in
            mutableState!.terminalEnabled = true
            mutableState!.terminal!.termType = "xterm"
            screen.destructivelySetScreenWidth(5, height: 9, mutableState: mutableState)
            mutableState!.maxScrollbackLines = 10;
            for line in ["", "abcdefgh", "", "ijkl"] {
                mutableState!.appendString(atCursor: line)
                mutableState!.appendCarriageReturnLineFeed()
            }
        })
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       ".....\n" +
                       "abcde\n" +
                       "fgh..\n" +
                       ".....\n" +
                       "ijkl.\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....")
        return screen;
    }

    func testResizeNotes() {
        // Put a note on the primary grid, switch to alt, resize width, swap back to primary. Note should
        // still be there.
        let screen = fiveByFourScreenWithThreeLinesOneWrapped()
        XCTAssertEqual(screen.immutableState.currentGrid.compactLineDump(),
                       "abcde\n" +
                       "fgh..\n" +
                       "ijkl.\n" +
                       ".....");
        let note = PTYAnnotation()
        screen.addNote(note, in: VT100GridCoordRangeMake(0, 1, 2, 1), focus: false, visible: false)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState!.showAltBuffer()
        })
        screen.size = VT100GridSizeMake(4, 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState!.showPrimaryBuffer()
        })
        XCTAssertEqual(screen.immutableState.currentGrid.compactLineDump(),
                       "abcd\n" +
                       "efgh\n" +
                       "ijkl\n" +
                       "....");

        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 5, 3))!
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].progenitor === note)
        let range = screen.coordRange(ofAnnotation: note)
        XCTAssertEqual(range, VT100GridCoordRangeMake(1, 1, 3, 1))
    }

    private func screen(width: Int32, height: Int32) -> VT100Screen {
        let screen = VT100Screen()
        session.screen = screen
        screen.delegate = session
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.terminalEnabled = true
            mutableState!.terminal!.termType = "xterm"
            screen.destructivelySetScreenWidth(width, height: height, mutableState: mutableState)
        })
        return screen
    }

    private func setSelectionRange(_ selectionRange: VT100GridCoordRange, width: Int32) {
        session.selection.clear()
        let theRange = VT100GridWindowedRangeMake(selectionRange, 0, 0)
        let theSub =
        iTermSubSelection.init(absRange: VT100GridAbsWindowedRangeFromRelative(theRange, 0),
                               mode: .kiTermSelectionModeCharacter,
                               width: width)
        session.selection.add(theSub)
    }

    private func appendLinesNoNewline(_ lines: [String], screen: VT100Screen) {
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            for (i, line) in lines.enumerated() {
                mutableState?.appendString(atCursor: line)
                if i + 1 != lines.count {
                    mutableState?.appendCarriageReturnLineFeed()
                }
            }
        })
    }

    func testResizeNoteInPrimaryWhileInAltAndSomeHistory() {
        // Put a note on the primary grid, switch to alt, resize width, swap back to primary. Note should
        // still be there.
        let screen = fiveByFourScreenWithThreeLinesOneWrapped()
        appendLinesNoNewline([ "hello world" ], screen: screen)

        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abcde\n" +   // history
                       "fgh..\n" +   // history
                       "ijkl.\n" +
                       "hello\n" +
                       " worl\n" +
                       "d....")
        let note = PTYAnnotation()
        screen.addNote(note, in: VT100GridCoordRangeMake(0, 2, 2, 2), focus: true, visible: true)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showAltBuffer()
        })
        screen.size = VT100GridSizeMake(4, 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showPrimaryBuffer()
        })

        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abcd\n" +  // history
                       "efgh\n" +  // history
                       "ijkl\n" +
                       "hell\n" +
                       "o wo\n" +
                       "rld.")
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 5, 3))!
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].progenitor === note)
        let range = screen.coordRange(ofAnnotation: note)
        XCTAssertEqual(range, VT100GridCoordRangeMake(0, 2, 2, 2))
    }

    func testResizeNoteInPrimaryWhileInAltAndPushingSomePrimaryIncludingWholeNoteIntoHistory() {
        let screen = fiveByFourScreenWithThreeLinesOneWrapped()
        appendLinesNoNewline(["hello world"], screen: screen)

        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abcde\n" +   // history
                       "fgh..\n" +   // history
                       "ijkl.\n" +
                       "hello\n" +
                       " worl\n" +
                       "d....")
        let note = PTYAnnotation()
        screen.addNote(note, in: VT100GridCoordRangeMake(0, 2, 2, 2), focus: true, visible: true)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showAltBuffer()
        })
        screen.size = VT100GridSizeMake(3, 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showPrimaryBuffer()
        })
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abc\n" +
                       "def\n" +
                       "gh.\n" +
                       "ijk\n" +
                       "l..\n" +
                       "hel\n" +
                       "lo \n" +
                       "wor\n" +
                       "ld.")
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 8, 3))!
        XCTAssertEqual(notes.count, 1);
        XCTAssertTrue(notes[0].progenitor === note)
        let range = screen.coordRange(ofAnnotation: note)
        XCTAssertEqual(range, VT100GridCoordRangeMake(0, 3, 2, 3))
    }

    func testResizeNoteInPrimaryWhileInAltAndPushingSomePrimaryIncludingPartOfNoteIntoHistory() {
        let screen = fiveByFourScreenWithThreeLinesOneWrapped()
        appendLinesNoNewline(["hello world"], screen: screen)
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abcde\n" +
                       "fgh..\n" +
                       "ijkl.\n" +
                       "hello\n" +
                       " worl\n" +
                       "d....")
        let note = PTYAnnotation()
        screen.addNote(note, in: VT100GridCoordRangeMake(0, 2, 5, 3), focus: true, visible: true)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showAltBuffer()
        })
        screen.size = VT100GridSizeMake(3, 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState?.showPrimaryBuffer()
        })
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abc\n" +
                       "def\n" +
                       "gh.\n" +
                       "ijk\n" +
                       "l..\n" +
                       "hel\n" +
                       "lo \n" +
                       "wor\n" +
                       "ld.")
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 8, 3))!
        XCTAssertEqual(notes.count, 1);
        XCTAssertTrue(notes[0].progenitor === note)
        let range = screen.coordRange(ofAnnotation: note)
        XCTAssertEqual(range, VT100GridCoordRangeMake(0, 3, 2, 6))
    }

    private func showAltAndUppercase(_ screen: VT100Screen) {
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            let temp = mutableState?.currentGrid.copy()
            mutableState?.showAltBuffer()
            for y in 0..<screen.height() {
                let lineIn = temp!.screenChars(atLineNumber: y)!
                let lineOut = mutableState!.currentGrid.screenChars(atLineNumber: y)!
                for x in 0..<Int(screen.width()) {
                    lineOut[x] = lineIn[x]
                    var c = lineIn[x].code;
                    if isalpha(Int32(c)) != 0 {
                        c -= 32
                    }
                    lineOut[x].code = c
                }
                let w = Int(screen.width())
                lineOut[w] = lineIn[w]
            }
        })
    }

    func testResizeNoteInAlternateThatGetsTruncatedByShrinkage() {
        let screen = fiveByFourScreenWithThreeLinesOneWrapped()
        appendLinesNoNewline(["hello world"], screen: screen)
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abcde\n" +
                       "fgh..\n" +
                       "ijkl.\n" +
                       "hello\n" +
                       " worl\n" +
                       "d....")
        showAltAndUppercase(screen)
        let note = PTYAnnotation()
        screen.addNote(note,
                       in: VT100GridCoordRangeMake(0, 1, 5, 3),
                       focus: true,
                       visible: true)
        screen.size = VT100GridSizeMake(3, 4)
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       "abc\n" +
                       "def\n" +
                       "gh.\n" +
                       "ijk\n" +
                       "l..\n" +
                       "HEL\n" +
                       "LO \n" +
                       "WOR\n" +
                       "LD.")
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 3, 6))!
        XCTAssertEqual(notes.count, 1);
        XCTAssertTrue(notes[0].progenitor === note)
        let range = screen.coordRange(ofAnnotation: note)
        XCTAssertEqual(range, VT100GridCoordRangeMake(2, 1, 2, 6))
    }

    private func commonAnnotationRestoration(range: VT100GridCoordRange) {
        var screen = fiveByNineScreenWithEmptyLineAtTop()
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       ".....\n" +
                       "abcde\n" +
                       "fgh..\n" +
                       ".....\n" +
                       "ijkl.\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....")
        let note = PTYAnnotation()
        screen.addNote(note, in: range, focus: true, visible: true)
        let encoder = iTermMutableDictionaryEncoderAdapter.encoder()
        var linesDropped = Int32(0)
        screen.encodeContents(encoder, linesDropped: &linesDropped)
        let state = encoder.mutableDictionary

        screen = self.screen(width: 3, height: 4)
        screen.restore(from: state as? [AnyHashable : Any],
                       includeRestorationBanner: false,
                       reattached: false)
        XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                       ".....\n" +
                       "abcde\n" +
                       "fgh..\n" +
                       ".....\n" +
                       "ijkl.\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....\n" +
                       ".....")
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 5, 8))!
        XCTAssertEqual(notes.count, 1)
        let restoredNote = notes[0]
        let rangeAfterResize = screen.coordRange(for: restoredNote.entry?.interval)
        XCTAssertTrue(VT100GridCoordRangeEqualsCoordRange(rangeAfterResize, range))
    }

    func testResizeWithNoteFirstLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 0, 5, 0))
    }

    func testResizeWithNoteFirstLinePlusFirstCharacterOfSecondLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 0, 2, 1))
    }

    func testResizeWithNoteFirstTwoCharactersOfSecondLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 1, 3, 1))
    }

    func testResizeWithNoteSecondLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 1, 5, 1))
    }

    func testResizeWithNoteLastFourCharactersOfSecondLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(2, 1, 5, 1))
    }

    func testResizeWithNoteSecondCharacterOfSecondLineToSecondCharacterOfThirdLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(2, 1, 2, 2))
    }

    func testResizeWithNoteSecondAndThirdLines() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 1, 5, 2))
    }

    func testResizeWithNoteSecondThroughFourthLines() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 1, 5, 3))
    }

    func testResizeWithNoteSecondThroughFifthLines() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 1, 5, 4))
    }

    func testResizeWithNoteSecondCharacterOfSecondLineThroughFirstCharacterOfFifthLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(2, 1, 2, 4))
    }

    func testResizeWithNoteThirdLineThroughFifthLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 3, 5, 4))
    }

    func testResizeWithNoteThirdLineThroughMiddleOfFifthLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 3, 3, 4))
    }

    func testResizeWithNoteFifthLine() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 4, 5, 4))
    }

    func testResizeWithNoteAllLines() {
        commonAnnotationRestoration(range: VT100GridCoordRangeMake(0, 0, 5, 4))
    }

    private func appendLines(_ lines: [String], screen: VT100Screen) {
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            for line in lines {
                mutableState!.appendString(atCursor: line)
                mutableState!.appendCarriageReturnLineFeed()
            }
        })
    }

    func testResizeWithBlanksBeforeAnnotation() {
        let range1 = VT100GridCoordRangeMake(0, 4, 10, 4)
        let expected = range1
        let screen = self.screen(width: 142, height: 8)

        screen.performBlock(joinedThreads: { terminal, mutableState, _ in
            mutableState!.maxScrollbackLines = 1000
        })
        appendLines([
            "Last login: Mon Dec  9 23:22:07 on ttys011",
            "You have mail.",
            "Georges-iMac:/Users/gnachman% echo;echo xxxxxxxxxx",
            "",
            "xxxxxxxxxx",
            "Georges-iMac:/Users/gnachman%"
        ], screen: screen)
        let note = PTYAnnotation()
        screen.addNote(note, in: range1, focus: true, visible: true)
        screen.size = VT100GridSizeMake(141, 8)
        let notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 80, 8))!
        XCTAssertEqual(notes.count, 1)
        let restoredNote = notes[0]
        let rangeAfterResize = screen.coordRange(for: restoredNote.entry?.interval)
        XCTAssertTrue(VT100GridCoordRangeEqualsCoordRange(rangeAfterResize, expected))
    }

    private func commonNoteResizeRegressionTest(initialRange range1: VT100GridCoordRange,
                                                intermediateRange range2: VT100GridCoordRange) {
        var screen = self.screen(width: 80, height: 25)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState!.maxScrollbackLines = 1000
        })
        appendLines([
            "",
            "",
            "",
            "Georges-iMac:/Users/gnachman% xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        ], screen: screen)
        let note = PTYAnnotation()
        screen.addNote(note, in: range1, focus: true, visible: true)

        let encoder = iTermMutableDictionaryEncoderAdapter.encoder()
        var linesDropped: Int32 = 0
        screen.encodeContents(encoder, linesDropped: &linesDropped)
        let state = encoder.mutableDictionary

        screen = self.screen(width: 80, height: 25)
        screen.restore(from: state as? [AnyHashable: Any],
                       includeRestorationBanner: false,
                       reattached: true)

        screen.size = VT100GridSizeMake(77, 25)
        var notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 80, 25))!
        XCTAssertEqual(notes.count, 1)
        let restoredNote1 = notes[0]
        let rangeAfterResize1 = screen.coordRange(for: restoredNote1.entry!.interval)
        XCTAssertTrue(VT100GridCoordRangeEqualsCoordRange(rangeAfterResize1, range2))

        screen.size = VT100GridSizeMake(80, 25)
        notes = screen.annotations(in: VT100GridCoordRangeMake(0, 0, 80, 25))!
        let restoredNote2 = notes[0]
        let rangeAfterResize2 = screen.coordRange(for: restoredNote2.entry!.interval)
        XCTAssertTrue(VT100GridCoordRangeEqualsCoordRange(rangeAfterResize2, range1))
    }

    func testNoteResizeRegression1() {
        commonNoteResizeRegressionTest(
            initialRange: VT100GridCoordRangeMake(0, 0, 80, 0),
            intermediateRange: VT100GridCoordRangeMake(0, 0, 77, 0)
        )
    }

    func testNoteResizeRegression2() {
        commonNoteResizeRegressionTest(
            initialRange: VT100GridCoordRangeMake(0, 1, 80, 1),
            intermediateRange: VT100GridCoordRangeMake(0, 1, 77, 1)
        )
    }

    func testNoteResizeRegression3() {
        commonNoteResizeRegressionTest(
            initialRange: VT100GridCoordRangeMake(0, 2, 80, 2),
            intermediateRange: VT100GridCoordRangeMake(0, 2, 77, 2)
        )
    }

    func testNoteResizeRegression4() {
        commonNoteResizeRegressionTest(
            initialRange: VT100GridCoordRangeMake(20, 4, 80, 6),
            intermediateRange: VT100GridCoordRangeMake(23, 4, 77, 6)
        )
    }

    func testNoteResizeRegression5() {
        commonNoteResizeRegressionTest(
            initialRange: VT100GridCoordRangeMake(0, 12, 80, 12),
            intermediateRange: VT100GridCoordRangeMake(0, 12, 77, 12)
        )
    }

    // MARK: -

    private func makeMixedToken(_ string: String) -> VT100Token {
        let token = VT100Token()
        token.type = VT100_MIXED_ASCII_CR_LF;
        var data = string.data(using: .utf8)!
        data.withUnsafeMutableBytes { umrbp -> Void in
            let umbp = umrbp.assumingMemoryBound(to: CChar.self)
            token.setAsciiBytes(umbp.baseAddress!,
                                length: Int32(umbp.count))
            token.realizeCRLFs(withCapacity: 10)
            let crlfs = token.crlfs
            for i in 0..<umbp.count {
                if umbp[i] == 10 || umbp[i] == 13 {
                    token.appendCRLF(Int32(i))
                }
            }
        }
        return token
    }

    private func gangExpected(initialLines: [String], mixedTokens: [String]) -> String {
        let screen = self.screen(width: 10, height: 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState!.maxScrollbackLines = 1000
        })
        appendLines(initialLines, screen: screen)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            for token in mixedTokens {
                var i = token.startIndex
                while i < token.endIndex {
                    let nextNewline = token.range(of: "\r\n", range: i..<token.endIndex)
                    if let nextNewline {
                        let substring = token[i..<nextNewline.lowerBound]
                        mutableState!.appendString(atCursor: String(substring))
                        mutableState!.appendCarriageReturnLineFeed()
                        i = nextNewline.upperBound
                    } else {
                        let substring = token[i..<token.endIndex]
                        mutableState!.appendString(atCursor: String(substring))
                        i = token.endIndex
                    }
                }
            }
        })
        return screen.compactLineDumpWithDividedHistoryAndContinuationMarks()
    }

    @discardableResult
    private func gangTest(initialLines: [String], mixedTokens: [String]) -> Bool {
        let expected = gangExpected(initialLines: initialLines, mixedTokens: mixedTokens)

        let screen = self.screen(width: 10, height: 4)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            mutableState!.maxScrollbackLines = 1000
        })
        appendLines(initialLines, screen: screen)
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            let gang = mixedTokens.map {
                makeMixedToken($0)
            }
            mutableState!.terminalAppendMixedAsciiGang(gang)
        })
        let actual = screen.compactLineDumpWithDividedHistoryAndContinuationMarks()
        XCTAssertEqual(actual, expected)
        if actual != expected {
            print("Actual:\n\(actual!)\n\nExpected:\n\(expected)")
        }
        return actual == expected
    }

    func testGang_basic() {
        gangTest(
            initialLines: [
                "Now is the time for all good men to come to the aid of their party.",
                "",
                "Twas brillig and the slithy toves did gyre and gimbal in the wabe."],
            mixedTokens: [
                "One for the money\r\ntwo for the show\r\n",
                "Three to get ready\r\nFour let's",
                " go"
            ])
    }

    private func performRandomGangTest(prng: inout SeededGenerator) -> Bool {
        let numInitialLines = prng.next(in: 0..<8)
        let initialLines = (0..<numInitialLines).map { i in
            String(repeating: Character(UnicodeScalar(65 + i)!), count: prng.next(in: 0..<80))
        }
        var tokens = [String]()
        var letter = 65 + 32
        let numTokens = prng.next(in: 1..<8)
        for _ in 0..<numTokens {
            let numLines = prng.next(in: 0..<8)
            var token = ""
            for j in 0..<numLines {
                token.append(String(repeating: Character(UnicodeScalar(letter)!),
                                    count: prng.next(in: 0..<80)))
                letter += 1
                if letter == 65 + 32 + 26 {
                    letter = 65 + 32
                }
                if j < numLines - 1 || prng.coinflip(p: 0.5) {
                    token.append("\r\n")
                }
            }
            tokens.append(token)
        }
        return gangTest(initialLines: initialLines, mixedTokens: tokens)
    }

    func testGang_random() {
        var prng = SeededGenerator(seed: 0)
        let iterations = 1_000
        for i in 0..<iterations {
            var saved = prng
            if !performRandomGangTest(prng: &prng) {
                // Set a breakpoint here to debug test failures.
                NSLog("Random test failed on iteration \(i)")
                _ = performRandomGangTest(prng: &saved)
            } else if i % 100 == 0 {
                NSLog("Iteratrion \(i) passed")
            }
        }
    }

    func testDropFirstBlock() {
        let screen = self.screen(width: 8, height: 8)
        session.configuration.maxScrollbackLines = 6
        session.configuration.isDirty = true
        screen.performBlock(joinedThreads: { _, mutableState, _ in
            do {
                let gang = [String(repeating: "a", count: 10) + "\r\n",
                            String(repeating: "b", count: 10) + "\r\n",
                            String(repeating: "c", count: 10) + "\r\n",
                            String(repeating: "d", count: 10) + "\r\n",
                            String(repeating: "e", count: 10) + "\r\n",
                            String(repeating: "f", count: 10) + "\r\n",
                            String(repeating: "g", count: 10) + "\r\n",
                            String(repeating: "h", count: 10) + "\r\n",
                            String(repeating: "i", count: 10) + "\r\n",
                            String(repeating: "j", count: 10) + "\r\n"]
                mutableState?.terminalAppendMixedAsciiGang(gang.map { makeMixedToken($0) })
            }
            XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                           "dd......\n" +
                           "eeeeeeee\n" +
                           "ee......\n" +
                           "ffffffff\n" +
                           "ff......\n" +
                           "gggggggg\n" +
                           // grid
                           "gg......\n" +
                           "hhhhhhhh\n" +
                           "hh......\n" +
                           "iiiiiiii\n" +
                           "ii......\n" +
                           "jjjjjjjj\n" +
                           "jj......\n" +
                           "........")
            do {
                let gang = [String(repeating: "k", count: 10) + "\r\n",
                            String(repeating: "l", count: 10) + "\r\n",
                            String(repeating: "m", count: 10) + "\r\n",
                            String(repeating: "n", count: 10) + "\r\n",
                            String(repeating: "o", count: 10) + "\r\n"]
                mutableState?.terminalAppendMixedAsciiGang(gang.map { makeMixedToken($0) })
            }
            XCTAssertEqual(screen.compactLineDumpWithHistory()!,
                           "ii......\n" +
                           "jjjjjjjj\n" +
                           "jj......\n" +
                           "kkkkkkkk\n" +
                           "kk......\n" +
                           "llllllll\n" +
                           // grid
                           "ll......\n" +
                           "mmmmmmmm\n" +
                           "mm......\n" +
                           "nnnnnnnn\n" +
                           "nn......\n" +
                           "oooooooo\n" +
                           "oo......\n" +
                           "........")
        })
    }
}

// a very simple LCG-based RNG
struct SeededGenerator: RandomNumberGenerator {
    // pick any non‑zero seed
    init(seed: UInt64) { state = seed }
    private var state: UInt64
    mutating func next() -> UInt64 {
        // constants from Numerical Recipes
        state = 6364136223846793005 &* state &+ 1
        return state
    }
    mutating func next(in outputRange: Range<Int>) -> Int {
        let raw = next()
        let temp = Int128(outputRange.lowerBound) + Int128(raw)
        return Int(temp % Int128(outputRange.count))
    }
    mutating func coinflip(p: Double) -> Bool {
        let value = Double(next())
        let threshold = Double(UInt64.max) * p
        return value < threshold
    }
}

fileprivate class FakeSession: NSObject, VT100ScreenDelegate {
    var screen: VT100Screen?
    var configuration = VT100MutableScreenConfiguration()
    var selection = iTermSelection()

    func screenConvertAbsoluteRange(_ range: VT100GridAbsCoordRange, toTextDocumentOfType type: String?, filename: String?, forceWide: Bool) {

    }
    
    func screenDidHookSSHConductor(withToken token: String, uniqueID: String, boolArgs: String, sshargs: String, dcsID: String, savedState: [AnyHashable : Any]) {

    }
    
    func screenDidReadSSHConductorLine(_ string: String, depth: Int32) {

    }
    
    func screenDidUnhookSSHConductor() {

    }
    
    func screenDidBeginSSHConductorCommand(withIdentifier identifier: String, depth: Int32) {

    }
    
    func screenDidEndSSHConductorCommand(withIdentifier identifier: String, type: String, status: UInt8, depth: Int32) {

    }
    
    func screenHandleSSHSideChannelOutput(_ string: String, pid: Int32, channel: UInt8, depth: Int32) {

    }
    
    func screenDidReadRawSSHData(_ data: Data) {

    }
    
    func screenDidTerminateSSHProcess(_ pid: Int32, code: Int32, depth: Int32) {

    }
    
    func screenWillBeginSSHIntegration() {

    }
    
    func screenBeginSSHIntegration(withToken token: String, uniqueID: String, encodedBA: String, sshArgs: String) {

    }
    
    func screenEndSSH(_ uniqueID: String) -> Int {
        return 0
    }
    
    func screenSSHLocation() -> String {
        return "localhost"
    }
    
    func screenBeginFramerRecovery(_ parentDepth: Int32) {

    }
    
    func screenHandleFramerRecoveryString(_ string: String) -> iTerm2SharedARC.ConductorRecovery? {
        nil
    }
    
    func screenFramerRecoveryDidFinish() {

    }
    
    func screenDidResynchronizeSSH() {

    }
    
    func screenEnsureDefaultMode() {

    }
    
    func screenWillSynchronize() {

    }
    
    func screenDidSynchronize() {

    }
    
    func screenOpen(_ url: URL?, completion: @escaping () -> Void) {
        completion()
    }
    
    func screenReportIconTitle() {

    }
    
    func screenReportWindowTitle() {

    }
    
    func screenSetPointerShape(_ pointerShape: String) {

    }
    
    func screenFold(_ range: NSRange) {

    }
    
    func screenStatPath(_ path: String, queue: dispatch_queue_t, completion: @escaping (Int32, UnsafePointer<stat>) -> Void) {
        var s = stat()
        completion(0, &s)
    }
    
    func screenStartWrappedCommand(_ command: String, channel uid: String) {

    }
    
    func screenSync(_ mutableState: VT100ScreenMutableState) {

    }
    
    func screenUpdateCommandUse(withGuid screenmarkGuid: String, onHost lastRemoteHost: (any VT100RemoteHostReading)?, toReferToMark screenMark: any VT100ScreenMarkReading) {

    }
    
    func screenExecutorDidUpdate(_ update: VT100ScreenTokenExecutorUpdate) {

    }
    
    func screenSwitchToSharedState() -> VT100ScreenState {
        screen!.switchToSharedState()
    }
    
    func screenRestore(_ state: VT100ScreenState) {

    }
    
    func screenConfiguration() -> VT100MutableScreenConfiguration {
        configuration
    }
    
    func screenSyncExpect(_ mutableState: VT100ScreenMutableState) {

    }
    
    func screenOfferToDisableTriggersInInteractiveApps() {

    }
    
    func screenDidUpdateReturnCode(forMark mark: any VT100ScreenMarkReading, remoteHost: (any VT100RemoteHostReading)?) {

    }
    
    func screenCopyString(toPasteboard string: String) {

    }
    
    func screenReportPasteboard(_ pasteboard: String, completion: @escaping () -> Void) {
        completion()
    }
    
    func screenPostUserNotification(_ string: String, rich: Bool) {

    }
    
    func screenRestoreColors(from slot: SavedColorsSlot) {
    }
    
    func screenStringForKeypress(withCode keycode: UInt16, flags: NSEvent.ModifierFlags, characters: String, charactersIgnoringModifiers: String) -> String? {
        characters
    }
    
    func screenDidAppendImageData(_ data: Data) {

    }
    
    func screenAppend(_ array: ScreenCharArray, metadata: iTermImmutableMetadata, lineBufferGeneration: Int64) {

    }
    
    func screenApplicationKeypadModeDidChange(_ mode: Bool) {

    }
    
    func screenTerminalAttemptedPasteboardAccess() {

    }
    
    func screenReportFocusWillChange(to reportFocus: Bool) {

    }
    
    func screenReportPasteBracketingWillChange(to bracket: Bool) {

    }
    
    func screenDidReceiveLineFeed(atLineBufferGeneration lineBufferGeneration: Int64) {

    }
    
    func screenSoftAlternateScreenModeDidChange(to enabled: Bool, showingAltScreen showing: Bool) {

    }
    
    func screenReportKeyUpDidChange(_ reportKeyUp: Bool) {

    }
    
    func screenConfirmDownloadNamed(_ name: String, canExceedSize limit: Int) -> Bool {
        true
    }
    
    func screenConfirmDownloadAllowed(_ name: String, size: Int, displayInline: Bool, promptIfBig: UnsafeMutablePointer<ObjCBool>) -> Bool {
        true
    }
    
    func screenAskAboutClearingScrollback() {

    }
    
    func screenRangeOfVisibleLines() -> VT100GridRange {
        return VT100GridRangeMake(0, 25)

    }
    
    func screenDidResize() {

    }
    
    func screenSuggestShellIntegrationUpgrade() {

    }
    
    func screenDidDetectShell(_ shell: String) {

    }
    
    func screenSetBackgroundImageFile(_ filename: String) {

    }
    
    func screenSetBadgeFormat(_ theFormat: String) {

    }
    
    func screenSetUserVar(_ kvp: String) {

    }
    
    func screenShouldReduceFlicker() -> Bool {
        false
    }
    
    func screenUnicodeVersion() -> Int {
        9
    }
    
    func screenSetUnicodeVersion(_ unicodeVersion: Int) {

    }
    
    func screenSetLabel(_ label: String, forKey keyName: String) {

    }
    
    func screenPushKeyLabels(_ value: String) {

    }
    
    func screenPopKeyLabels(_ value: String) {

    }
    
    func screenSendModifiersDidChange() {

    }
    
    func screenKeyReportingFlagsDidChange() {

    }
    
    func screenReportVariableNamed(_ name: String) {

    }
    
    func screenReportCapabilities() {

    }
    
    func screenCommandDidChange(to command: String, atPrompt: Bool, hadCommand: Bool, haveCommand: Bool) {

    }
    
    func screenDidExecuteCommand(_ command: String?, range: VT100GridCoordRange, onHost host: (any VT100RemoteHostReading)?, inDirectory directory: String?, mark: (any VT100ScreenMarkReading)?) {

    }
    
    func screenCommandDidExit(withCode code: Int32, mark maybeMark: (any VT100ScreenMarkReading)?) {

    }
    
    func screenCommandDidAbort(onLine line: Int32, outputRange: VT100GridCoordRange, command: String, mark: any VT100ScreenMarkReading) {

    }
    
    func screenLogWorkingDirectory(onAbsoluteLine absLine: Int64, remoteHost: (any VT100RemoteHostReading)?, withDirectory directory: String?, pushType: VT100ScreenWorkingDirectoryPushType, accepted: Bool) {

    }
    
    func screenDidClearScrollbackBuffer() {

    }
    
    func screenMouseModeDidChange() {

    }
    
    func screenFlashImage(_ identifier: String) {

    }
    
    func screenRequestAttention(_ request: VT100AttentionRequestType) {

    }
    
    func screenDidTryToUseDECRQCRA() {

    }
    
    func screenDisinterSession() {

    }
    
    func screenGetWorkingDirectory(completion: @escaping (String?) -> Void) {
        completion(nil)
    }
    
    func screenSetCursorVisible(_ visible: Bool) {

    }
    
    func screenSetHighlightCursorLine(_ highlight: Bool) {

    }
    
    func screenClearCapturedOutput() {

    }
    
    func screenCursorDidMove(toLine line: Int32) {

    }
    
    func screenHasView() -> Bool {
        true
    }
    
    func screenSaveScrollPosition() {

    }
    
    func screenDidAdd(_ mark: any iTermMarkProtocol, alert: Bool, completion: @escaping () -> Void) {
        completion()
    }
    
    func screenPromptDidStart(atLine line: Int32) {

    }
    
    func screenPromptDidEnd(withMark mark: any VT100ScreenMarkReading) {

    }
    
    func screenStealFocus() {

    }
    
    func screenSetProfile(toProfileNamed value: String) {

    }
    
    func screenSetPasteboard(_ value: String) {

    }
    
    func screenDidAddNote(_ note: any PTYAnnotationReading, focus: Bool, visible: Bool) {

    }
    
    func screenDidAdd(_ porthole: any iTerm2SharedARC.ObjCPorthole) {

    }
    
    func screenCopyBufferToPasteboard() {

    }
    
    func screenAppendData(toPasteboard data: Data) {

    }
    
    func screenWillReceiveFileNamed(_ name: String, ofSize size: Int, preconfirmed: Bool) {

    }
    
    func screenDidFinishReceivingFile() {

    }
    
    func screenDidFinishReceivingInlineFile() {

    }
    
    func screenDidReceiveBase64FileData(_ data: String, confirm: (String, Int, Int) -> Void) {
        confirm("string", 0, 1)
    }
    
    func screenFileReceiptEndedUnexpectedly() {

    }

    func screenRequestUpload(_ args: String, completion: @escaping () -> Void) {
        completion()
    }

    func screenSetCurrentTabColor(_ color: NSColor?) {

    }
    
    func screenSetTabColorRedComponent(to color: CGFloat) {

    }
    
    func screenSetTabColorGreenComponent(to color: CGFloat) {

    }
    
    func screenSetTabColorBlueComponent(to color: CGFloat) {

    }
    
    func screenSetColor(_ color: NSColor?, profileKey: String?) -> Bool {
        true
    }
    
    func screenResetColor(withColorMapKey key: Int32, profileKey: String, dark: Bool) -> [NSNumber : Any] {
        [:]
    }
    
    func screenSelectColorPresetNamed(_ name: String) {

    }
    
    func screenCurrentHostDidChange(_ host: any VT100RemoteHostReading, pwd workingDirectory: String?, ssh: Bool) {

    }
    
    func screenCurrentDirectoryDidChange(to newPath: String?, remoteHost: (any VT100RemoteHostReading)?) {

    }
    
    func screenDidReceiveCustomEscapeSequence(withParameters parameters: [String : String], payload: String) {

    }
    
    func screenMiniaturizeWindow(_ flag: Bool) {

    }
    
    func screenRaise(_ flag: Bool) {

    }
    
    func screenSetPreferredProxyIcon(_ value: String?) {

    }
    
    func screenWindowIsMiniaturized() -> Bool {
        false
    }
    
    func screenSendReport(_ data: Data) {

    }
    
    func screenDidSendAllPendingReports() {

    }
    
    func screenWindowScreenFrame() -> NSRect {
        NSRect(x: 0, y: 0, width: 6000, height: 6000)
    }
    
    func screenWindowFrame() -> NSRect {
        NSRect(x: 0, y: 0, width: 1000, height: 1000)
    }
    
    func screenSize() -> NSSize {
        NSSize(width: 1000, height: 1000)
    }

    @objc(screenPushCurrentTitleForWindow:)
    func screenPushCurrentTitle(forWindow flag: Bool) {

    }

    @objc(screenPopCurrentTitleForWindow:completion:)
    func screenPopCurrentTitle(forWindow flag: Bool, completion: @escaping () -> Void) {
        completion()
    }
    
    func screenNumber() -> Int32 {
        0
    }
    
    func screenWindowIndex() -> Int32 {
        0
    }
    
    func screenTabIndex() -> Int32 {
        0
    }
    
    func screenViewIndex() -> Int32 {
        0
    }
    
    func screenStartTmuxMode(withDCSIdentifier dcsID: String) {

    }
    
    func screenHandleTmuxInput(_ token: VT100Token) {

    }
    
    func screenShouldTreatAmbiguousCharsAsDoubleWidth() -> Bool {
        false
    }
    
    func screenActivateBellAudibly(_ audibleBell: Bool, visibly flashBell: Bool, showIndicator showBellIndicator: Bool, quell: Bool) {

    }
    
    func screenPrintStringIfAllowed(_ printBuffer: String, completion: @escaping () -> Void) {
        completion()
    }
    
    func screenPrintVisibleAreaIfAllowed() {

    }
    
    func screenShouldSendContentsChangedNotification() -> Bool {
        false
    }
    
    func screenRemoveSelection() {

    }
    
    func screenMoveSelectionUp(by n: Int32, inRegion region: VT100GridRect) {

    }
    
    func screenResetTailFind() {

    }
    
    func screenSelection() -> iTermSelection {
        selection
    }
    
    func screenCellSize() -> NSSize {
        NSSize(width: 10, height: 10)
    }
    
    func screenClearHighlights() {

    }
    
    func screenNeedsRedraw() {

    }
    
    func screenScheduleRedrawSoon() {

    }
    
    func screenUpdateDisplay(_ redraw: Bool) {

    }
    
    func screenRefreshFindOnPageView() {

    }
    
    func screenSizeDidChangeWithNewTopLine(at newTop: Int32) {

    }
    
    func screenDidReset() {

    }
    
    func screenAllowTitleSetting() -> Bool {
        false
    }
    
    func screenDidAppendString(toCurrentLine string: String, isPlainText plainText: Bool, foreground fg: screen_char_t, background bg: screen_char_t, atPrompt: Bool) {

    }
    
    func screenDidAppendAsciiData(toCurrentLine asciiData: Data, foreground fg: screen_char_t, background bg: screen_char_t, atPrompt: Bool) {

    }
    
    func screenRevealComposer(withPrompt prompt: [ScreenCharArray]) {

    }
    
    func screenDismissComposer() {

    }
    
    func screenAppendString(toComposer string: String) {

    }
    
    func screenSetCursorBlinking(_ blink: Bool) {

    }
    
    func screenCursorIsBlinking() -> Bool {
        false
    }
    
    func screenSetCursorType(_ type: ITermCursorType) {

    }
    
    func screenGet(_ cursorTypeOut: UnsafeMutablePointer<ITermCursorType>, blinking: UnsafeMutablePointer<ObjCBool>) {

    }
    
    func screenResetCursorTypeAndBlink() {

    }
    
    func screenShouldInitiateWindowResize() -> Bool {
        false
    }
    
    func screenResize(toWidth width: Int32, height: Int32) {

    }
    
    func screenSetSize(_ proposedSize: VT100GridSize) {

    }
    
    func screenSetPointSize(_ proposedSize: NSSize) {

    }
    
    func screenSetWindowTitle(_ title: String) {

    }
    
    func screenWindowTitle() -> String? {
        "Window Title"
    }
    
    func screenIconTitle() -> String {
        "Icon Title"
    }
    
    func screenSetIconName(_ name: String) {

    }
    
    func screenSetSubtitle(_ subtitle: String) {

    }
    
    func screenName() -> String {
        return "Name"
    }
    
    func screenWindowIsFullscreen() -> Bool {
        false
    }
    
    func screenMoveWindowTopLeftPoint(to point: NSPoint) {

    }
    
    let scope = iTermVariableScope()
    func triggerSideEffectVariableScope() -> iTermVariableScope {
        return scope
    }
    
    func triggerSideEffectSetTitle(_ newName: String) {
    }
    
    func triggerSideEffectInvokeFunctionCall(_ invocation: String, withVariables temporaryVariables: [AnyHashable : Any], captures captureStringArray: [String], trigger: Trigger) {
    }
    
    func triggerSideEffectSetValue(_ value: Any?, forVariableNamed name: String) {
    }
    
    func triggerSideEffectCurrentDirectoryDidChange(_ newPath: String) {
    }
    
    func triggerSideEffectShowCapturedOutputTool() {
    }
    
    func triggerWriteTextWithoutBroadcasting(_ text: String) {
    }
    
    func triggerSideEffectShowAlert(withMessage message: String, rateLimit: iTermRateLimitedUpdate, disable: @escaping () -> Void) {
    }
    
    func triggerSideEffectRunBackgroundCommand(_ command: String, pool: iTermBackgroundCommandRunnerPool) {
    }
    
    func triggerSideEffectOpenPasswordManager(toAccountName accountName: String?) {
    }
    
    func triggerSideEffectShowCapturedOutputToolNotVisibleAnnouncementIfNeeded() {

    }

    func triggerSideEffectShowShellIntegrationRequiredAnnouncement() {

    }

    func triggerSideEffectDidCaptureOutput() {

    }

    func triggerSideEffectLaunchCoprocess(withCommand command: String, identifier: String?, silent: Bool, triggerTitle: String) {

    }

    func triggerSideEffectPostUserNotification(withMessage message: String) {

    }

    func triggerSideEffectStopScrolling(atLine absLine: Int64) {

    }

    private let colorMap = iTermColorMap()

    func immutableColorMap(_ colorMap: (any iTermColorMapReading)!, didChangeColorForKey theKey: iTermColorMapKey, from before: NSColor!, to after: NSColor!) {
    }
    
    func immutableColorMap(_ colorMap: (any iTermColorMapReading)!, dimmingAmountDidChangeTo dimmingAmount: Double) {
    }
    
    func immutableColorMap(_ colorMap: (any iTermColorMapReading)!, mutingAmountDidChangeTo mutingAmount: Double) {
    }
    
    func objectMethodRegistry() -> iTermBuiltInFunctions? {
        return nil
    }
    
    func objectScope() -> iTermVariableScope? {
        return nil
    }
    
}

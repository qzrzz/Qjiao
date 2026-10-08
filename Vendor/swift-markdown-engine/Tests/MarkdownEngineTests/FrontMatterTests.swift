//
//  FrontMatterTests.swift
//  MarkdownEngineTests
//
//  Qjiao patch: the leading `---` … `---` front matter is one opaque fenced
//  block so its `#` / `:` lines are not misread as headings and paragraphs.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Qjiao — front matter")
struct FrontMatterTests {

    private func kinds(_ text: String, isDocumentStart: Bool = true) -> [BlockKind] {
        BlockParser.computeBlocks(text, isDocumentStart: isDocumentStart).map(\.kind)
    }

    @Test("leading front matter is a single fenced block")
    func leadingFrontMatterIsOneBlock() {
        let text = """
        ---
        title: Moonvy
        # a comment line
        date: 2022-07-14
        subtype: [figma]
        ---
        # Body heading
        """
        let result = kinds(text)
        // One fenced block for the front matter, then only the real body heading —
        // the `# a comment` inside the front matter must not become a heading.
        #expect(result == [.fencedCode, .heading])
    }

    @Test("a blank line before the closing fence is not front matter")
    func blankLineBreaksFrontMatter() {
        let text = """
        ---

        title: Moonvy
        ---
        """
        #expect(!kinds(text).contains(.fencedCode))
    }

    @Test("a mid-document `---` run is not front matter")
    func windowNeverClaimsMidDocumentRun() {
        let text = """
        ---
        a: 1
        ---
        """
        let result = kinds(text, isDocumentStart: false)
        #expect(!result.contains(.fencedCode))
    }

    @Test("a lone leading `---` stays a thematic break")
    func loneLeadingBreakIsNotFrontMatter() {
        let text = """
        ---
        hello
        """
        #expect(kinds(text) == [.thematicBreak, .paragraph])
    }
}

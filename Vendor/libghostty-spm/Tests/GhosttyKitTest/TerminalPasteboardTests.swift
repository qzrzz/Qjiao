#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// 验证 Finder 文件和普通文本不会在终端粘贴转换中互相覆盖。
    @Suite(.serialized)
    @MainActor
    struct TerminalPasteboardTests {
        @Test
        func finderFilesBecomeShellSafePaths() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let plain = URL(fileURLWithPath: "/tmp/plain.png")
            let spaced = URL(fileURLWithPath: "/tmp/image with space.png")
            let quoted = URL(fileURLWithPath: "/tmp/user's image.png")

            #expect(pasteboard.writeObjects([plain as NSURL, spaced as NSURL, quoted as NSURL]))
            #expect(
                TerminalPasteboard.terminalText(from: pasteboard)
                    == "/tmp/plain.png '/tmp/image with space.png' '/tmp/user'\\''s image.png'"
            )
        }

        @Test
        func ordinaryTextRemainsUnchanged() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            #expect(pasteboard.setString("hello\nworld", forType: .string))

            #expect(TerminalPasteboard.terminalText(from: pasteboard) == "hello\nworld")
            #expect(!TerminalPasteboard.containsImage(pasteboard))
        }

        @Test
        func imageOnlyPasteboardIsDetected() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let image = NSImage(size: NSSize(width: 1, height: 1))

            #expect(pasteboard.writeObjects([image]))
            #expect(TerminalPasteboard.containsImage(pasteboard))
            #expect(TerminalPasteboard.terminalText(from: pasteboard) == nil)
        }
    }
#endif

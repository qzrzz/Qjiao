import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// 覆盖剪贴板确认的安全约束：没有明确批准时不得把内容交给终端。
/// Hooks are injectable so these tests do not need a live Ghostty surface.
@Suite(.serialized)
@MainActor
struct TerminalClipboardCallbackTests {
    @Test
    func escalatedOSC52ReadWithoutDelegateIsDenied() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (String, Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "secret", request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
        }

        #expect(recorded?.0 == "")
        #expect(recorded?.1 == true)
    }

    @Test
    func unsafePasteIsDeniedWithoutDelegate() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (String, Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "rm -rf /\n", request: GHOSTTY_CLIPBOARD_REQUEST_PASTE,
                state: state
            )
        }

        #expect(recorded?.0 == "")
        #expect(recorded?.1 == true)
    }

    @Test
    func escalatedOSC52WriteIsDropped() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completed = false
        TerminalClipboardIO.complete = { _, _, _, _ in completed = true }

        let bridge = makeBridge()
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "attacker", request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                state: state
            )
        }
        #expect(!completed)
    }

    @Test
    func delegateCanApproveOSC52Read() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (String, Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "approved", request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            #expect(recorder.requests.first?.kind == .osc52Read)
            recorder.requests.first?.approve()
        }
        #expect(recorded?.0 == "approved")
        #expect(recorded?.1 == true)
    }

    @Test
    func delegateCanDenyOSC52Read() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var recorded: (String, Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "secret", request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            recorder.requests.first?.deny()
        }
        #expect(recorded?.0 == "")
        #expect(recorded?.1 == true)
    }

    @Test
    func requestResolvesAtMostOnce() {
        let original = TerminalClipboardIO.complete
        defer { TerminalClipboardIO.complete = original }
        var completions = 0
        TerminalClipboardIO.complete = { _, _, _, _ in completions += 1 }

        let recorder = ClipboardConfirmationRecorder()
        let bridge = makeBridge(delegate: recorder)
        withTestState { state in
            invokeConfirmCallback(
                bridge: bridge, contents: "text", request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                state: state
            )
            recorder.requests.first?.approve()
            recorder.requests.first?.deny()
            recorder.requests.first?.approve()
        }
        #expect(completions == 1)
    }

    @Test
    func writeRequiringConfirmationNeverReachesPasteboard() {
        let original = TerminalClipboardIO.writeString
        defer { TerminalClipboardIO.writeString = original }
        var written: String?
        TerminalClipboardIO.writeString = { written = $0 }
        invokeWriteCallback("attacker", confirm: true)
        #expect(written == nil)
    }

    @Test
    func unconfirmedWriteReachesPasteboard() {
        let original = TerminalClipboardIO.writeString
        defer { TerminalClipboardIO.writeString = original }
        var written: String?
        TerminalClipboardIO.writeString = { written = $0 }
        invokeWriteCallback("copied", confirm: false)
        #expect(written == "copied")
    }

    @Test
    func pasteReadCompletesUnconfirmed() {
        let originalRead = TerminalClipboardIO.readString
        let originalComplete = TerminalClipboardIO.complete
        defer {
            TerminalClipboardIO.readString = originalRead
            TerminalClipboardIO.complete = originalComplete
        }
        TerminalClipboardIO.readString = { "line one\nline two" }
        var recorded: (String, Bool)?
        TerminalClipboardIO.complete = { _, string, _, confirmed in
            recorded = (String(cString: string), confirmed)
        }

        let bridge = makeBridge()
        var state = 0
        let handled = withUnsafeMutablePointer(to: &state) { statePtr in
            terminalControllerReadClipboardCallback(
                userdata: Unmanaged.passUnretained(bridge).toOpaque(),
                clipboard: GHOSTTY_CLIPBOARD_STANDARD,
                opaquePtr: UnsafeMutableRawPointer(statePtr)
            )
        }
        #expect(handled)
        #expect(recorded?.0 == "line one\nline two")
        #expect(recorded?.1 == false)
    }

    private func makeBridge(
        delegate: (any TerminalSurfaceViewDelegate)? = nil
    ) -> TerminalCallbackBridge {
        let bridge = TerminalCallbackBridge(delegate: delegate)
        bridge.rawSurface = UnsafeMutableRawPointer(bitPattern: 1)
        return bridge
    }

    private func withTestState(_ body: (UnsafeMutableRawPointer) -> Void) {
        let state = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { state.deallocate() }
        body(state)
    }

    private func invokeConfirmCallback(
        bridge: TerminalCallbackBridge,
        contents: String,
        request: ghostty_clipboard_request_e,
        state: UnsafeMutableRawPointer
    ) {
        contents.withCString { cString in
            terminalControllerConfirmReadClipboardCallback(
                userdata: Unmanaged.passUnretained(bridge).toOpaque(),
                string: cString,
                opaquePtr: state,
                request: request
            )
        }
    }

    private func invokeWriteCallback(_ text: String, confirm: Bool) {
        text.withCString { data in
            "text/plain".withCString { mime in
                let content = ghostty_clipboard_content_s(mime: mime, data: data)
                withUnsafePointer(to: content) { contentsPtr in
                    terminalControllerWriteClipboardCallback(
                        userdata: nil,
                        clipboard: GHOSTTY_CLIPBOARD_STANDARD,
                        contents: contentsPtr,
                        contentsLen: 1,
                        confirm: confirm
                    )
                }
            }
        }
    }
}

@MainActor
private final class ClipboardConfirmationRecorder:
    TerminalSurfaceClipboardConfirmationDelegate {
    private(set) var requests: [TerminalClipboardConfirmationRequest] = []

    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        requests.append(request)
    }
}

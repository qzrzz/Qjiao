//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Injectable pasteboard operations used by terminal clipboard callbacks.
enum TerminalClipboardIO {
    nonisolated(unsafe) static var readString: () -> String? = {
        #if canImport(UIKit)
            UIPasteboard.general.string
        #elseif canImport(AppKit)
            TerminalPasteboard.terminalText(from: .general)
        #endif
    }

    nonisolated(unsafe) static var writeString: (String) -> Void = { string in
        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    nonisolated(unsafe) static var complete: (
        _ surface: ghostty_surface_t,
        _ string: String,
        _ state: UnsafeMutableRawPointer,
        _ confirmed: Bool
    ) -> Void = { surface, string, state, confirmed in
        completePlainText(surface, string, state, confirmed: confirmed)
    }

    nonisolated(unsafe) static var deny: (
        _ surface: ghostty_surface_t,
        _ state: UnsafeMutableRawPointer
    ) -> Void = { surface, state in
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    static func completePlainText(
        _ surface: ghostty_surface_t,
        _ string: String,
        _ state: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        string.withCString { cString in
            "text/plain".withCString { mime in
                var content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: cString,
                    len: string.utf8.count
                )
                withUnsafePointer(to: &content) { contentsPtr in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsPtr,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: confirmed,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
    }
}

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        return terminalRunOnMainSync {
            bridge.handleAction(action)
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        guard !confirm else {
            TerminalDebugLog.log(.input, "clipboard write denied: confirmation required")
            return
        }
        guard contentsLen > 0 else { return }
        guard let content = contents?.pointee else { return }
        guard let data = content.data else { return }
        let bytes = UnsafeRawBufferPointer(start: data, count: content.len)
        guard let string = String(bytes: bytes, encoding: .utf8) else { return }
        TerminalClipboardIO.writeString(string)
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes _: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen _: Int,
        list _: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        guard let string = TerminalClipboardIO.readString() else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
        )
        TerminalClipboardIO.complete(surface, string, opaquePtr, false)
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return }

        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            return
        default:
            break
        }

        let kind: TerminalClipboardConfirmationRequest.Kind
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            kind = .unsafePaste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
            kind = .osc52Read
        default:
            TerminalClipboardIO.deny(surface, opaquePtr)
            return
        }

        let contents = Self.plainText(from: confirm)
        let stateBits = UInt(bitPattern: opaquePtr)
        terminalRunOnMain {
            guard let state = UnsafeMutableRawPointer(bitPattern: stateBits) else { return }
            bridge.handleClipboardConfirmation(contents: contents, kind: kind, state: state)
        }
    }

    static func plainText(from confirm: UnsafePointer<ghostty_clipboard_confirm_s>?) -> String {
        guard let confirm else { return "" }
        let payload = confirm.pointee
        guard let contents = payload.contents, payload.contents_len > 0 else { return "" }
        for index in 0 ..< payload.contents_len {
            let content = contents[index]
            let mime = content.mime.map { String(cString: $0) } ?? ""
            guard mime.isEmpty || mime == "text/plain" else { continue }
            guard let data = content.data, content.len > 0 else { return "" }
            let bytes = UnsafeRawBufferPointer(start: data, count: content.len)
            return String(decoding: bytes, as: UTF8.self)
        }
        return ""
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        list: list
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirm: confirm,
        opaquePtr: opaquePtr,
        request: request
    )
}

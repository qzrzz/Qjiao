//
//  TerminalClipboardConfirmationRequest.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

/// A clipboard request awaiting an explicit host decision.
@MainActor
public final class TerminalClipboardConfirmationRequest {
    public enum Kind: Sendable {
        case unsafePaste
        case osc52Read
    }

    public let kind: Kind
    public let contents: String

    private weak var bridge: TerminalCallbackBridge?
    private let state: UnsafeMutableRawPointer
    private var resolved = false

    init(
        bridge: TerminalCallbackBridge,
        kind: Kind,
        contents: String,
        state: UnsafeMutableRawPointer
    ) {
        self.bridge = bridge
        self.kind = kind
        self.contents = contents
        self.state = state
    }

    /// Approves the pending paste or OSC 52 response.
    public func approve() { resolve(text: contents) }

    /// Denies the request without handing clipboard contents to the terminal.
    public func deny() {
        guard !resolved else { return }
        resolved = true
        guard let surface = bridge?.rawSurface else { return }
        TerminalClipboardIO.deny(surface, state)
    }

    private func resolve(text: String) {
        guard !resolved else { return }
        resolved = true
        guard let surface = bridge?.rawSurface else { return }
        TerminalClipboardIO.complete(surface, text, state, true)
    }
}

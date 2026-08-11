//
//  QjiaoAutomationCommandLine.swift
//  kero
//

import Darwin
import Foundation

enum QjiaoCLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

/// `qjiao +pane` / `qjiao +agent` 的轻量客户端。实际权限由 App 端 socket
/// 再次校验；CLI 只读取当前终端继承到的 capability。
enum QjiaoAutomationCommandLine {
    static func run(namespace: String, arguments: [String]) throws {
        let connection = try AppConnection()
        switch namespace {
        case "+pane": try runPane(arguments, connection: connection)
        case "+agent": try runAgent(arguments, connection: connection)
        default: throw QjiaoCLIError.message("Unknown automation namespace \(namespace).")
        }
    }

    private static func runPane(
        _ arguments: [String],
        connection: AppConnection
    ) throws {
        guard let command = arguments.first else {
            printPaneHelp()
            return
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "current":
            try requireNoArguments(tail, command: "+pane current")
            printJSON(try connection.request(method: "pane.current"))
        case "list":
            try requireNoArguments(tail, command: "+pane list")
            printJSON(try connection.request(method: "pane.list"))
        case "get":
            let target = try parsePaneTarget(tail, command: "+pane get")
            printJSON(try connection.request(method: "pane.get", params: target))
        case "split":
            var params: [String: QjiaoJSONValue] = [:]
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--pane":
                    params["pane_id"] = .string(try value(after: &index, in: tail, option: "--pane"))
                case "--current": break
                case "--left": params["edge"] = .string("left")
                case "--right": params["edge"] = .string("right")
                case "--up": params["edge"] = .string("top")
                case "--down": params["edge"] = .string("bottom")
                case "--cwd":
                    params["cwd"] = .string(try value(after: &index, in: tail, option: "--cwd"))
                case "--focus": params["focus"] = .bool(true)
                case "--help", "-h": printPaneHelp(); return
                default: throw unknownOption(tail[index], command: "+pane split")
                }
                index += 1
            }
            guard params["edge"] != nil else {
                throw QjiaoCLIError.message("+pane split requires --left, --right, --up, or --down.")
            }
            printJSON(try connection.request(method: "pane.split", params: params))
        case "run":
            let (params, argv) = try parseRawCommand(tail, command: "+pane run")
            var request = params
            request["argv"] = .array(argv.map(QjiaoJSONValue.string))
            printJSON(try connection.request(method: "pane.run", params: request))
        case "send":
            var params = try parsePaneTarget(tail, command: "+pane send", allowMissing: true)
            var text: String?
            var enter = false
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--pane":
                    params["pane_id"] = .string(try value(after: &index, in: tail, option: "--pane"))
                case "--current": break
                case "--text": text = try value(after: &index, in: tail, option: "--text")
                case "--enter": enter = true
                default: throw unknownOption(tail[index], command: "+pane send")
                }
                index += 1
            }
            guard let text, !text.isEmpty else {
                throw QjiaoCLIError.message("+pane send requires --text.")
            }
            params["text"] = .string(text)
            params["enter"] = .bool(enter)
            printJSON(try connection.request(method: "pane.send", params: params))
        case "read":
            var params = try parsePaneTarget(tail, command: "+pane read", allowMissing: true)
            parseReadOptions(tail, into: &params)
            printJSON(try connection.request(method: "pane.read", params: params))
        case "wait-output":
            var params = try parsePaneTarget(tail, command: "+pane wait-output", allowMissing: true)
            var needle: String?
            var timeout = 30.0
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--pane": params["pane_id"] = .string(try value(after: &index, in: tail, option: "--pane"))
                case "--current": break
                case "--contains": needle = try value(after: &index, in: tail, option: "--contains")
                case "--timeout": timeout = try seconds(after: &index, in: tail, option: "--timeout")
                default: throw unknownOption(tail[index], command: "+pane wait-output")
                }
                index += 1
            }
            guard let needle, !needle.isEmpty else {
                throw QjiaoCLIError.message("+pane wait-output requires --contains.")
            }
            try waitForOutput(connection, params: params, needle: needle, timeout: timeout)
        case "protocol":
            try requireNoArguments(tail, command: "+pane protocol")
            printJSON(try connection.request(method: "protocol.info"))
        case "--help", "-h": printPaneHelp()
        default: throw QjiaoCLIError.message("Unknown +pane command \(command). Run `qjiao +pane --help`.")
        }
    }

    private static func runAgent(
        _ arguments: [String],
        connection: AppConnection
    ) throws {
        guard let command = arguments.first else {
            printAgentHelp()
            return
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "list":
            try requireNoArguments(tail, command: "+agent list")
            printJSON(try connection.request(method: "agent.list"))
        case "get":
            let target = try parseAgentTarget(tail, command: "+agent get")
            printJSON(try connection.request(method: "agent.get", params: target))
        case "start":
            guard let alias = arguments.dropFirst().first, !alias.hasPrefix("-") else {
                throw QjiaoCLIError.message("+agent start requires ALIAS.")
            }
            var params: [String: QjiaoJSONValue] = ["alias": .string(alias)]
            // `tail` still contains the positional alias at index 0.
            var index = 1
            while index < tail.count {
                switch tail[index] {
                case "--kind": params["kind"] = .string(try value(after: &index, in: tail, option: "--kind"))
                case "--pane": params["pane_id"] = .string(try value(after: &index, in: tail, option: "--pane"))
                case "--focus": params["focus"] = .bool(true)
                case "--":
                    let argv = Array(tail.dropFirst(index + 1))
                    params["argv"] = .array(argv.map(QjiaoJSONValue.string))
                    index = tail.count
                    continue
                default: throw unknownOption(tail[index], command: "+agent start")
                }
                index += 1
            }
            guard params["kind"] != nil else {
                throw QjiaoCLIError.message("+agent start requires --kind KIND.")
            }
            printJSON(try connection.request(method: "agent.start", params: params))
        case "prompt":
            var params = try parseAgentTarget(tail, command: "+agent prompt", allowMissing: true)
            var prompt: String?
            var wait = false
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--alias": params["alias"] = .string(try value(after: &index, in: tail, option: "--alias"))
                case "--pane": params["pane_id"] = .string(try value(after: &index, in: tail, option: "--pane"))
                case "--current": break
                case "--text": prompt = try value(after: &index, in: tail, option: "--text")
                case "--wait": wait = true
                default: throw unknownOption(tail[index], command: "+agent prompt")
                }
                index += 1
            }
            guard let prompt, !prompt.isEmpty else {
                throw QjiaoCLIError.message("+agent prompt requires --text.")
            }
            params["text"] = .string(prompt)
            printJSON(try connection.request(method: "agent.prompt", params: params))
            if wait { try waitForAgent(connection, target: params, states: ["done", "blocked"], timeout: 300) }
        case "read":
            let target = try parseAgentTarget(tail, command: "+agent read", allowMissing: true)
            let result = try connection.request(method: "agent.get", params: target)
            guard let object = result.objectValue,
                  let paneID = object["pane_id"]?.stringValue else {
                throw QjiaoCLIError.message("Qjiao returned an Agent without a pane ID.")
            }
            var read: [String: QjiaoJSONValue] = ["pane_id": .string(paneID)]
            parseReadOptions(tail, into: &read)
            printJSON(try connection.request(method: "pane.read", params: read))
        case "wait":
            let target = try parseAgentTarget(tail, command: "+agent wait", allowMissing: true)
            var states = ["done", "blocked"]
            var timeout = 300.0
            var index = 0
            while index < tail.count {
                switch tail[index] {
                case "--alias", "--pane":
                    _ = try value(after: &index, in: tail, option: tail[index])
                case "--current": break
                case "--state": states = try value(after: &index, in: tail, option: "--state").split(separator: ",").map(String.init)
                case "--timeout": timeout = try seconds(after: &index, in: tail, option: "--timeout")
                default: throw unknownOption(tail[index], command: "+agent wait")
                }
                index += 1
            }
            try waitForAgent(connection, target: target, states: states, timeout: timeout)
        case "explain":
            print("""
            Qjiao Agent automation

            +pane reads and operates terminal panes in the current project.
            +agent prompt sends input only to a recognized live Agent. Prompts
            are rejected while the Agent is blocked and waiting for approval;
            use +pane send only when raw terminal input is intentional.
            """)
        case "--help", "-h": printAgentHelp()
        default: throw QjiaoCLIError.message("Unknown +agent command \(command). Run `qjiao +agent --help`.")
        }
    }

    private static func waitForOutput(
        _ connection: AppConnection,
        params: [String: QjiaoJSONValue],
        needle: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try connection.request(method: "pane.read", params: params)
            if result.objectValue?["text"]?.stringValue?.contains(needle) == true {
                printJSON(result)
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw QjiaoCLIError.message("Timed out waiting for terminal output containing \(needle).")
    }

    private static func waitForAgent(
        _ connection: AppConnection,
        target: [String: QjiaoJSONValue],
        states: [String],
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try connection.request(method: "agent.get", params: target)
            if let state = result.objectValue?["agent"]?.objectValue?["state"]?.stringValue,
               states.contains(state) {
                printJSON(result)
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw QjiaoCLIError.message("Timed out waiting for Agent state.")
    }

    private static func parsePaneTarget(
        _ arguments: [String],
        command: String,
        allowMissing: Bool = false
    ) throws -> [String: QjiaoJSONValue] {
        var result: [String: QjiaoJSONValue] = [:]
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--pane": result["pane_id"] = .string(try value(after: &index, in: arguments, option: "--pane"))
            case "--current": break
            default:
                if allowMissing { break }
                throw unknownOption(arguments[index], command: command)
            }
            index += 1
        }
        return result
    }

    private static func parseAgentTarget(
        _ arguments: [String],
        command: String,
        allowMissing: Bool = false
    ) throws -> [String: QjiaoJSONValue] {
        var result: [String: QjiaoJSONValue] = [:]
        var current = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--alias": result["alias"] = .string(try value(after: &index, in: arguments, option: "--alias"))
            case "--pane": result["pane_id"] = .string(try value(after: &index, in: arguments, option: "--pane"))
            case "--current": current = true
            default:
                if allowMissing { break }
                throw unknownOption(arguments[index], command: command)
            }
            index += 1
        }
        guard allowMissing || !result.isEmpty || current else {
            throw QjiaoCLIError.message("\(command) requires --alias, --pane, or --current.")
        }
        return result
    }

    private static func parseRawCommand(
        _ arguments: [String],
        command: String
    ) throws -> ([String: QjiaoJSONValue], [String]) {
        var params: [String: QjiaoJSONValue] = [:]
        guard let separator = arguments.firstIndex(of: "--") else {
            throw QjiaoCLIError.message("\(command) requires `-- command [arguments...]`.")
        }
        let prefix = Array(arguments[..<separator])
        params = try parsePaneTarget(prefix, command: command, allowMissing: true)
        let argv = Array(arguments[(separator + 1)...])
        guard !argv.isEmpty else { throw QjiaoCLIError.message("\(command) requires a command.") }
        return (params, argv)
    }

    private static func parseReadOptions(
        _ arguments: [String],
        into params: inout [String: QjiaoJSONValue]
    ) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--lines": if let value = Int(arguments[safe: index + 1] ?? "") { params["lines"] = .number(Double(value)); index += 1 }
            case "--columns": if let value = Int(arguments[safe: index + 1] ?? "") { params["columns"] = .number(Double(value)); index += 1 }
            case "--require-idle": params["require_idle_agent"] = .bool(true)
            default: break
            }
            index += 1
        }
    }

    private static func value(after index: inout Int, in arguments: [String], option: String) throws -> String {
        let next = index + 1
        guard arguments.indices.contains(next) else {
            throw QjiaoCLIError.message("\(option) requires a value.")
        }
        index = next
        return arguments[next]
    }

    private static func seconds(after index: inout Int, in arguments: [String], option: String) throws -> TimeInterval {
        guard let value = Double(try value(after: &index, in: arguments, option: option)), value > 0 else {
            throw QjiaoCLIError.message("\(option) requires a positive number of seconds.")
        }
        return value
    }

    private static func requireNoArguments(_ arguments: [String], command: String) throws {
        guard arguments.isEmpty else { throw unknownOption(arguments[0], command: command) }
    }

    private static func unknownOption(_ value: String, command: String) -> QjiaoCLIError {
        .message("Unknown option \(value) for \(command).")
    }

    private static func printJSON(_ value: QjiaoJSONValue) {
        if let data = try? JSONEncoder.qjiaoAutomation.encode(value),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func printPaneHelp() {
        print("""
        Usage:
          qjiao +pane current | list | get [--pane ID]
          qjiao +pane split [--pane ID] [--left|--right|--up|--down] [--cwd PATH] [--focus]
          qjiao +pane run [--pane ID] -- command [arguments...]
          qjiao +pane send [--pane ID] --text TEXT [--enter]
          qjiao +pane read [--pane ID] [--lines N] [--columns N]
          qjiao +pane wait-output [--pane ID] --contains TEXT [--timeout SECONDS]
          qjiao +pane protocol
        """)
    }

    private static func printAgentHelp() {
        print("""
        Usage:
          qjiao +agent list
          qjiao +agent get --alias ALIAS | --pane ID | --current
          qjiao +agent start ALIAS --kind KIND [--pane ID] [--focus] [-- agent-arguments...]
          qjiao +agent prompt [--alias ALIAS | --pane ID | --current] --text TEXT [--wait]
          qjiao +agent read [--alias ALIAS | --pane ID | --current]
          qjiao +agent wait [--alias ALIAS | --pane ID | --current] [--state done,blocked]
          qjiao +agent explain
        """)
    }

    private final class AppConnection {
        private let socketPath: String
        private let token: String
        private let terminalID: String

        init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
            guard let socket = environment["QJIAO_AUTOMATION_SOCKET"],
                  let token = environment["QJIAO_AUTOMATION_TOKEN"],
                  let terminalID = environment["QJIAO_TERMINAL_ID"],
                  !socket.isEmpty, !token.isEmpty, !terminalID.isEmpty else {
                throw QjiaoCLIError.message("`qjiao +pane/+agent` must be run inside a Qjiao terminal.")
            }
            socketPath = socket
            self.token = token
            self.terminalID = terminalID
        }

        func request(
            method: String,
            params: [String: QjiaoJSONValue] = [:],
            timeout: TimeInterval = 5
        ) throws -> QjiaoJSONValue {
            let request = QjiaoAutomationRequest(
                version: 1,
                id: UUID().uuidString,
                method: method,
                token: token,
                terminalID: terminalID,
                params: params
            )
            let response = try QjiaoAutomationSocketServer.exchange(
                path: socketPath,
                request: request,
                timeout: timeout
            )
            guard response.version == 1, response.id == request.id else {
                throw QjiaoCLIError.message("Qjiao returned a mismatched automation response.")
            }
            guard response.ok, let result = response.result else {
                let code = response.error?.code ?? "automation_error"
                let message = response.error?.message ?? "Qjiao rejected the automation request."
                throw QjiaoCLIError.message("\(code): \(message)")
            }
            return result
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

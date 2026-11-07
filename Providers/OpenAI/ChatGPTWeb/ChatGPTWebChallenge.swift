import Foundation

/// Bounded interpreter for the data-only dx instruction format in
/// basketikun/chatgpt2api@92dd80e91543157d36a4ddad60e765c5293760e9/utils/turnstile.py.
/// No JavaScript, dynamic evaluation, network, filesystem or actual browser objects.
enum ChatGPTWebChallenge {
    /// Only local enum labels and counters are exposed; never remote operands,
    /// challenge strings, tokens, URLs or account data.
    struct Failure: Error {
        enum Stage: String { case missing = "MISSING", encoding = "ENCODING", program = "PROGRAM", budget = "BUDGET", result = "RESULT", unexpected = "INTERNAL" }
        let stage: Stage
        var instruction: Int? = nil
        var skipped: Int = 0
        var code: String {
            let location = instruction.map { "-I\($0)" } ?? ""
            return "WEB-DX-\(stage.rawValue)\(location)-S\(skipped)"
        }
    }

    enum ChallengeError: Error, LocalizedError {
        case malformed, unsupported, limitExceeded, noResult
        var errorDescription: String? {
            switch self {
            case .malformed: return "网页验证指令格式错误。"
            case .unsupported: return "网页验证使用了尚未识别的指令。"
            case .limitExceeded: return "网页验证超过本地执行限制。"
            case .noResult: return "网页验证未生成有效结果。"
            }
        }
    }

    static func token(dx: String, source: String) async throws -> String {
        let worker = Task.detached(priority: .utility) { try evaluate(dx: dx, source: source) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    /// Synchronous production entry also exercised by deterministic fixtures.
    static func evaluate(dx: String, source: String, maxSteps: Int = 20_000,
                         timeBudget: TimeInterval = 1) throws -> String {
        guard dx.utf8.count <= 512_000, source.utf8.count <= 32_768,
              let bytes = Data(base64Encoded: dx), bytes.count <= 384_000,
              let decoded = String(data: bytes, encoding: .utf8) else { throw Failure(stage: .encoding) }
        let machine = Machine(maxSteps: min(max(0, maxSteps), 20_000), timeBudget: min(max(0, timeBudget), 2))
        let program: Value
        do {
            try machine.tick()
            let plain = try machine.xor(decoded, source)
            program = try machine.parse(plain)
        } catch is CancellationError { throw CancellationError() }
        catch ChallengeError.limitExceeded { throw Failure(stage: .budget) }
        catch { throw Failure(stage: .program) }
        guard case .array(let instructions) = program, instructions.count <= 4096 else { throw Failure(stage: .program) }
        for opcode in [1, 2, 3, 5, 6, 7, 8, 14, 15, 17, 18, 19, 20, 21, 23, 24] {
            machine.registers[String(opcode)] = .operation(opcode)
        }
        machine.registers["9"] = program
        machine.registers["10"] = .string("window")
        machine.registers["16"] = .string(source)
        var skipped = 0
        var lastSkipped: Int?
        for (index, instruction) in instructions.enumerated() {
            do {
                try machine.tick()
                guard case .array(let fields) = instruction, !fields.isEmpty, fields.count <= 65 else { throw ChallengeError.malformed }
                let operation = try machine.read(fields[0])
                guard case .operation(let opcode) = operation else { throw ChallengeError.unsupported }
                _ = try machine.invoke(opcode, Array(fields.dropFirst()), depth: 0)
            } catch is CancellationError { throw CancellationError() }
            catch ChallengeError.limitExceeded {
                // Local execution limits are not recoverable protocol exceptions.
                throw Failure(stage: .budget, instruction: index, skipped: skipped)
            } catch {
                // The pinned protocol catches errors per instruction. A missing
                // browser property or unsupported call must not discard a later
                // valid result. No arbitrary code is executed by this interpreter.
                skipped += 1
                lastSkipped = index
            }
        }
        do { try machine.tick() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure(stage: .budget, skipped: skipped) }
        guard let result = machine.result, !result.isEmpty else {
            throw Failure(stage: .result, instruction: lastSkipped, skipped: skipped)
        }
        return result
    }

    private indirect enum Value {
        case null, bool(Bool), integer(Int64), number(Double), string(String), array([Value])
        case object(OrderedObject), operation(Int)
    }

    private final class OrderedObject {
        var keys: [String] = []
        var values: [String: Value] = [:]
        let isBrowserObject: Bool
        init(browser: Bool = false) { isBrowserObject = browser }
        func set(_ key: String, _ value: Value) {
            if values[key] == nil { keys.append(key) }
            values[key] = value
        }
    }

    private final class Machine {
        var registers: [String: Value] = [:]
        var result: String?
        let maxSteps: Int
        let deadline: TimeInterval
        let started = ProcessInfo.processInfo.systemUptime
        var steps = 0
        var allocated = 0
        init(maxSteps: Int, timeBudget: TimeInterval) {
            self.maxSteps = maxSteps
            deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        }
        func tick() throws {
            try Task.checkCancellation()
            steps += 1
            guard steps <= maxSteps, ProcessInfo.processInfo.systemUptime < deadline else { throw ChallengeError.limitExceeded }
        }
        func charge(_ size: Int) throws {
            allocated += size
            guard size <= 384_000, allocated <= 4_000_000 else { throw ChallengeError.limitExceeded }
        }
        func key(_ value: Value) throws -> String {
            switch value {
            case .integer(let n): return String(n)
            case .number(let n):
                guard n.isFinite, n >= -9_007_199_254_740_991, n <= 9_007_199_254_740_991 else { throw ChallengeError.malformed }
                return n.rounded() == n ? String(Int64(n)) : String(n)
            case .string(let text): guard text.utf8.count <= 1024 else { throw ChallengeError.limitExceeded }; return "s:" + text
            case .bool(let value): return value ? "1" : "0"
            case .null: return "null"
            default: throw ChallengeError.malformed
            }
        }
        func read(_ address: Value) throws -> Value {
            guard let value = registers[try key(address)] else { throw ChallengeError.malformed }
            return value
        }
        func store(_ address: Value, _ value: Value) throws {
            guard registers.count < 8192 else { throw ChallengeError.limitExceeded }
            registers[try key(address)] = value
        }
        func string(_ value: Value, depth: Int = 0) throws -> String {
            guard depth < 32 else { throw ChallengeError.limitExceeded }
            let result: String
            switch value {
            case .null: result = "undefined"
            case .bool(let v): result = v ? "True" : "False"
            case .integer(let v): result = String(v)
            case .number(let v): result = String(v)
            case .string(let v):
                let special = ["window.Math": "[object Math]", "window.Reflect": "[object Reflect]",
                    "window.performance": "[object Performance]", "window.localStorage": "[object Storage]",
                    "window.Object": "function Object() { [native code] }", "window.Reflect.set": "function set() { [native code] }",
                    "window.performance.now": "function () { [native code] }", "window.Object.create": "function create() { [native code] }",
                    "window.Object.keys": "function keys() { [native code] }", "window.Math.random": "function random() { [native code] }"]
                result = special[v] ?? v
            case .array(let values):
                // Reference joins raw list strings; it does not apply special-object coercion to each element.
                if values.allSatisfy({ if case .string = $0 { return true }; return false }) {
                    result = values.map { if case .string(let s) = $0 { return s }; return "" }.joined(separator: ",")
                } else { result = try pythonRepr(value, depth: depth + 1) }
            case .object: result = try pythonRepr(value, depth: depth + 1)
            case .operation: throw ChallengeError.unsupported
            }
            try charge(result.utf8.count)
            return result
        }
        func pythonRepr(_ value: Value, depth: Int) throws -> String {
            try tick(); guard depth < 32 else { throw ChallengeError.limitExceeded }
            let text: String
            switch value {
            case .null: text = "None"
            case .string(let value):
                let delimiter = value.contains("'") && !value.contains("\"") ? "\"" : "'"
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: delimiter, with: "\\" + delimiter)
                    .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\t", with: "\\t")
                guard !value.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { throw ChallengeError.unsupported }
                text = delimiter + escaped + delimiter
            case .array(let values): text = "[" + (try values.map { try pythonRepr($0, depth: depth + 1) }).joined(separator: ", ") + "]"
            case .object(let object):
                guard !object.isBrowserObject else { throw ChallengeError.unsupported }
                text = "{" + (try object.keys.map { try pythonRepr(.string($0), depth: depth + 1) + ": " + pythonRepr(object.values[$0]!, depth: depth + 1) }).joined(separator: ", ") + "}"
            case .operation: throw ChallengeError.unsupported
            default: text = try string(value, depth: depth + 1)
            }
            try charge(text.utf8.count); return text
        }
        func xor(_ text: String, _ key: String) throws -> String {
            try tick()
            guard !key.isEmpty else { return text }
            let keyScalars = Array(key.unicodeScalars)
            var output = String.UnicodeScalarView()
            for (index, scalar) in text.unicodeScalars.enumerated() {
                if index.isMultiple(of: 1024) { try tick() }
                guard let value = UnicodeScalar(scalar.value ^ keyScalars[index % keyScalars.count].value) else { throw ChallengeError.malformed }
                output.append(value)
            }
            let result = String(output)
            try charge(result.utf8.count)
            return result
        }
        func arity(_ args: [Value], _ expected: Int) throws {
            guard args.count == expected else { throw ChallengeError.malformed }
        }
        func invoke(_ opcode: Int, _ args: [Value], depth: Int) throws -> Value {
            try tick()
            guard depth < 24, args.count <= 64 else { throw ChallengeError.limitExceeded }
            switch opcode {
            case 1:
                try arity(args, 2)
                let text = try xor(string(read(args[0])), string(read(args[1])))
                try store(args[0], .string(text))
            case 2:
                try arity(args, 2); try store(args[0], args[1])
            case 3:
                try arity(args, 1)
                guard case .string(let text) = args[0] else { throw ChallengeError.malformed }
                result = Data(text.utf8).base64EncodedString(); try charge(result!.utf8.count)
            case 5:
                try arity(args, 2)
                let current = try read(args[0]), incoming = try read(args[1])
                if case .array(var list) = current {
                    guard list.count < 8192 else { throw ChallengeError.limitExceeded }
                    list.append(incoming); try charge(list.count * 8); try store(args[0], .array(list))
                } else {
                    func concatenates(_ v: Value) -> Bool { switch v { case .string, .number: return true; default: return false } }
                    let value: String
                    if concatenates(current) || concatenates(incoming) { value = try string(current) + string(incoming) }
                    else { value = "NaN" }
                    try charge(value.utf8.count); try store(args[0], .string(value))
                }
            case 6, 24:
                try arity(args, 3)
                guard case .string(let a) = try read(args[1]), case .string(let b) = try read(args[2]) else { throw ChallengeError.malformed }
                let joined = a + "." + b
                try charge(joined.utf8.count)
                try store(args[0], .string(opcode == 6 && joined == "window.document.location" ? "https://chatgpt.com/" : joined))
            case 7:
                guard !args.isEmpty else { throw ChallengeError.malformed }
                let target = try read(args[0]), values = try args.dropFirst().map { try read($0) }
                if case .string("window.Reflect.set") = target {
                    try arity(values, 3)
                    guard case .object(let object) = values[0], object.isBrowserObject, object.keys.count < 8192 else { throw ChallengeError.malformed }
                    let keyName: String
                    if case .string(let raw) = values[1] { keyName = raw }
                    else if case .null = values[1] { keyName = "None" }
                    else { keyName = try pythonRepr(values[1], depth: 0) }
                    object.set(keyName, values[2])
                } else { _ = try call(target, values, depth: depth + 1) }
            case 8:
                try arity(args, 2); try store(args[0], read(args[1]))
            case 14:
                try arity(args, 2)
                guard case .string(let text) = try read(args[1]) else { throw ChallengeError.malformed }
                try store(args[0], parse(text))
            case 15:
                try arity(args, 2); try store(args[0], .string(json(read(args[1]), depth: 0)))
            case 17:
                guard args.count >= 2 else { throw ChallengeError.malformed }
                let target = try read(args[1]), values = try args.dropFirst(2).map { try read($0) }
                let value: Value
                switch target {
                case .string("window.performance.now"):
                    value = .number((ProcessInfo.processInfo.systemUptime - started) * 1000 + Double.random(in: 0..<1) / 1_000_000)
                case .string("window.Math.random"): value = .number(Double.random(in: 0..<1))
                case .string("window.Object.create"): value = .object(OrderedObject(browser: true))
                case .string("window.Object.keys"):
                    guard values.count == 1, case .string("window.localStorage") = values[0] else { throw ChallengeError.unsupported }
                    value = .array(["STATSIG_LOCAL_STORAGE_INTERNAL_STORE_V4", "STATSIG_LOCAL_STORAGE_STABLE_ID", "client-correlated-secret",
                        "oai/apps/capExpiresAt", "oai-did", "STATSIG_LOCAL_STORAGE_LOGGING_REQUEST", "UiState.isNavigationCollapsed.1"].map(Value.string))
                default: value = try call(target, values, depth: depth + 1)
                }
                try store(args[0], value)
            case 18, 19:
                try arity(args, 1)
                let text = try string(read(args[0]))
                let converted: String
                if opcode == 18 {
                    guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else { throw ChallengeError.malformed }
                    converted = decoded
                } else { converted = Data(text.utf8).base64EncodedString() }
                try charge(converted.utf8.count); try store(args[0], .string(converted))
            case 20:
                guard args.count >= 3 else { throw ChallengeError.malformed }
                if try equal(read(args[0]), read(args[1]), depth: 0) {
                    let target = try read(args[2])
                    guard case .operation = target else { throw ChallengeError.unsupported }
                    _ = try call(target, args.dropFirst(3).map { try read($0) }, depth: depth + 1)
                }
            case 21: break
            case 23:
                guard args.count >= 2 else { throw ChallengeError.malformed }
                if case .null = try read(args[0]) { break }
                _ = try call(read(args[1]), Array(args.dropFirst(2)), depth: depth + 1)
            default: throw ChallengeError.unsupported
            }
            return .null // All Python instruction functions return None.
        }
        func call(_ target: Value, _ args: [Value], depth: Int) throws -> Value {
            guard case .operation(let opcode) = target else { throw ChallengeError.unsupported }
            return try invoke(opcode, args, depth: depth)
        }
        func equal(_ lhs: Value, _ rhs: Value, depth: Int) throws -> Bool {
            try tick(); guard depth < 32 else { throw ChallengeError.limitExceeded }
            func number(_ v: Value) -> Double? { switch v { case .integer(let n): return Double(n); case .number(let n): return n; case .bool(let b): return b ? 1 : 0; default: return nil } }
            if let a = number(lhs), let b = number(rhs) { return a == b }
            switch (lhs, rhs) {
            case (.null, .null): return true
            case (.string(let a), .string(let b)): return a == b
            case (.operation(let a), .operation(let b)): return a == b
            case (.object(let a), .object(let b)):
                if a.isBrowserObject || b.isBrowserObject { return a === b }
                guard Set(a.keys) == Set(b.keys) else { return false }
                for key in a.keys { if try !equal(a.values[key]!, b.values[key]!, depth: depth + 1) { return false } }
                return true
            case (.array(let a), .array(let b)):
                guard a.count == b.count else { return false }
                for i in a.indices { if try !equal(a[i], b[i], depth: depth + 1) { return false } }; return true
            default: return false
            }
        }

        func json(_ value: Value, depth: Int) throws -> String {
            try tick(); guard depth < 32 else { throw ChallengeError.limitExceeded }
            let text: String
            switch value {
            case .null: text = "null"
            case .bool(let b): text = b ? "true" : "false"
            case .integer(let n): text = String(n)
            case .number(let n): guard n.isFinite else { throw ChallengeError.malformed }; text = String(n)
            case .string(let s): text = quote(s)
            case .array(let a): text = "[" + (try a.map { try json($0, depth: depth + 1) }).joined(separator: ", ") + "]"
            case .object(let o):
                guard !o.isBrowserObject else { throw ChallengeError.unsupported }
                text = "{" + (try o.keys.map { try quote($0) + ": " + json(o.values[$0]!, depth: depth + 1) }).joined(separator: ", ") + "}"
            case .operation: throw ChallengeError.unsupported
            }
            try charge(text.utf8.count); return text
        }
        func quote(_ text: String) -> String {
            var result = "\""
            for unit in text.utf16 {
                switch unit {
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 8: result += "\\b"
                case 9: result += "\\t"
                case 10: result += "\\n"
                case 12: result += "\\f"
                case 13: result += "\\r"
                case 0..<32, 127...UInt16.max: result += String(format: "\\u%04x", unit)
                default: result.unicodeScalars.append(UnicodeScalar(unit)!)
                }
            }
            return result + "\""
        }

        /// JSON scanner preserves object insertion order for Python json.dumps parity.
        func parse(_ text: String) throws -> Value {
            try charge(text.utf8.count)
            let bytes = Array(text.utf8)
            var index = 0
            func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
            func take(_ expected: UInt8) throws { space(); guard index < bytes.count, bytes[index] == expected else { throw ChallengeError.malformed }; index += 1 }
            func quoted() throws -> String {
                try take(34); let start = index - 1; var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]; index += 1
                    if byte == 34 && !escaped {
                        // Foundation decodes only this isolated string, not object order.
                        guard let result = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw ChallengeError.malformed }
                        return result
                    }
                    if byte == 92 && !escaped { escaped = true } else { escaped = false }
                }
                throw ChallengeError.malformed
            }
            func value(_ depth: Int) throws -> Value {
                try tick(); guard depth < 32 else { throw ChallengeError.limitExceeded }; space()
                guard index < bytes.count else { throw ChallengeError.malformed }
                switch bytes[index] {
                case 34: return .string(try quoted())
                case 91:
                    index += 1; space(); var values: [Value] = []
                    if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
                    while true {
                        guard values.count < 8192 else { throw ChallengeError.limitExceeded }
                        values.append(try value(depth + 1)); space()
                        if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
                        try take(44)
                    }
                case 123:
                    index += 1; space(); let object = OrderedObject()
                    if index < bytes.count && bytes[index] == 125 { index += 1; return .object(object) }
                    while true {
                        guard object.keys.count < 8192 else { throw ChallengeError.limitExceeded }
                        let key = try quoted(); try take(58); object.set(key, try value(depth + 1)); space()
                        if index < bytes.count && bytes[index] == 125 { index += 1; return .object(object) }
                        try take(44)
                    }
                default:
                    let start = index
                    while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                    guard index > start else { throw ChallengeError.malformed }
                    let token = String(decoding: bytes[start..<index], as: UTF8.self)
                    switch token {
                    case "null": return .null
                    case "true": return .bool(true)
                    case "false": return .bool(false)
                    default:
                        guard token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw ChallengeError.malformed }
                        if !token.contains("."), !token.lowercased().contains("e"), let integer = Int64(token) { return .integer(integer) }
                        guard let number = Double(token), number.isFinite else { throw ChallengeError.malformed }; return .number(number)
                    }
                }
            }
            let output = try value(0); space(); guard index == bytes.count else { throw ChallengeError.malformed }; return output
        }
    }
}

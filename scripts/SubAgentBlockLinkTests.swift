import Foundation

@main
struct SubAgentBlockLinkTests {
    static func main() {
        let a = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let b = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        func check(_ action: String, _ input: String?, _ output: String, _ expected: [String]) {
            let actual = ZeSubAgentBlockLink.ids(action: action, input: input, output: output)
            precondition(actual == expected, "\(action): expected \(expected), got \(actual)")
        }
        check("spawn_agent", "{\"message\":\"id=\(b)\"}", "子代理已排队：id=\(a)，名称=研究，层级=1。", [a])
        check("spawn_agent", nil, "{\"id\":\"\(a)\",\"status\":\"completed\"}", [a])
        check("wait_agent", "{\"ids\":\" \(a.lowercased()), \(b),\(a)\"}", "", [a, b])
        check("wait_agent", nil, "[{\"id\":\"\(a)\"},{\"id\":\"\(b)\"}]", [a, b])
        check("send_input", "{\"id\":\"\(a)\"}", "The child wrote id=\(b)", [a])
        check("close_agent", "{\"id\":\"\(a)\"}", "已关闭子代理", [a])
        check("resume_agent", "{\"id\":\"\(a)\"}", "正在运行", [a])
        check("spawn_agent", nil, "failed to start; unrelated id=\(b)", [])
        check("spawn_agent", nil, "子代理已排队：id=not-an-id，名称=研究", [])
        check("wait_agent", "{bad JSON", "[]", [])
        check("send_input", "{\"id\":\" \"}", "", [])
        print("SubAgentBlockLinkTests: 11 identity and persistence cases passed")
    }
}

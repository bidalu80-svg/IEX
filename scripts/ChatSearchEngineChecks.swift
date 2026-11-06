// Runtime assertions derived from the pinned source standalone tests.

import Foundation

func result(_ label: String, _ cond: Bool) { precondition(cond, label); print("PASS \(label)") }
func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
func unit(_ n: Int, _ text: String, block: Int? = nil) -> ChatSearchUnit {
    ChatSearchUnit(key: ChatSearchUnitKey(messageId: uuid(n), blockId: block.map(uuid), field: .body), text: text)
}

// [1] matcher
let M = ChatSearchMatcher.self
result("case insensitive", M.count(of: "hello", in: "Hello HELLO hello", limit: 99) == 3)
result("diacritic insensitive both ways", M.count(of: "cafe", in: "Café café CAFE", limit: 99) == 3
       && M.count(of: "café", in: "cafe", limit: 99) == 1)
result("Chinese substring", M.count(of: "搜索", in: "会话内搜索，全局搜索", limit: 99) == 2)
result("CJK and Latin mixed", M.count(of: "iOS 版", in: "这是 iOS 版本", limit: 99) == 1)
result("non-overlapping", M.count(of: "aa", in: "aaaaa", limit: 99) == 2)
result("whole string is one phrase, not OR of words",
       M.count(of: "apple pie", in: "apple tart and pie", limit: 99) == 0
       && M.count(of: "apple pie", in: "Apple Pie!", limit: 99) == 1)
result("query is trimmed, inner space kept", M.normalizedQuery("  a b \n") == "a b")
result("empty query finds nothing", M.ranges(of: "", in: "abc").isEmpty)
result("limit respected", M.count(of: "a", in: String(repeating: "a", count: 50), limit: 7) == 7)
result("NSRange is UTF-16 (emoji before match)", M.nsRanges(of: "x", in: "😀x") == [NSRange(location: 2, length: 1)])

// [2] engine
let units = [unit(1, "foo bar foo"), unit(2, "nothing"), unit(3, "FOO", block: 30)]
let r = ChatSearchEngine.search(units: units, query: "foo")!
result("matches in display order then ordinal",
       r.matches == [ChatSearchMatch(key: units[0].key, ordinal: 0), ChatSearchMatch(key: units[0].key, ordinal: 1),
                     ChatSearchMatch(key: units[2].key, ordinal: 0)])
result("per-unit counts", r.countByUnit[units[0].key] == 2 && r.countByUnit[units[2].key] == 1 && r.countByUnit[units[1].key] == nil)
result("blank query = no results", ChatSearchEngine.search(units: units, query: "   ")! == .empty)
let big = [unit(1, String(repeating: "ab ", count: 300))]
let capped = ChatSearchEngine.search(units: big, query: "ab")!
result("per-unit cap 200", capped.matches.count == 200 && capped.countByUnit[big[0].key] == 200 && !capped.truncated)
let many = (0..<15).map { unit($0, String(repeating: "q ", count: 150)) }
let total = ChatSearchEngine.search(units: many, query: "q")!
result("total cap 2000 and truncated", total.matches.count == 2000 && total.truncated)
let exact = (0..<10).map { unit($0, String(repeating: "q ", count: 200)) }
let exactR = ChatSearchEngine.search(units: exact, query: "q")!
result("exactly 2000 is not truncated", exactR.matches.count == 2000 && !exactR.truncated)
result("cancel returns nil", ChatSearchEngine.search(units: many, query: "q", isCancelled: { true }) == nil)
let stable1 = ChatSearchEngine.search(units: units, query: "o")!
let stable2 = ChatSearchEngine.search(units: units, query: "o")!
result("same input, same order", stable1 == stable2)

// [3] navigation
let N = ChatSearchNavigation.self
result("lands on newest", N.initialIndex(count: 12) == 11 && N.initialIndex(count: 0) == nil)
result("next from last wraps to first", N.step(from: 11, count: 12, forward: true)! == (0, true))
result("previous from first wraps to last", N.step(from: 0, count: 12, forward: false)! == (11, true))
result("plain step", N.step(from: 4, count: 12, forward: false)! == (3, false) && N.step(from: 4, count: 12, forward: true)! == (5, false))
result("single result never reports a wrap", N.step(from: 0, count: 1, forward: true)! == (0, false))
result("no results, no step", N.step(from: nil, count: 0, forward: true) == nil)
let a = ChatSearchMatch(key: units[0].key, ordinal: 1)
let list = [ChatSearchMatch(key: units[0].key, ordinal: 0), a, ChatSearchMatch(key: units[2].key, ordinal: 0)]
result("relocate keeps the same match after inserts",
       N.relocate(previous: a, previousIndex: 1, in: [ChatSearchMatch(key: units[1].key, ordinal: 0)] + list) == 2)
result("relocate clamps when the match is gone",
       N.relocate(previous: ChatSearchMatch(key: units[1].key, ordinal: 9), previousIndex: 7, in: list) == 2)
result("counter", N.counterText(index: 2, count: 12, truncated: false) == "3/12"
       && N.counterText(index: 0, count: 2000, truncated: true) == "1/2000+")

// [4] markdown text
let T = ChatSearchMarkdownText.self
let para: [BlockNode] = [.paragraph(content: [.text("A "), .strong(children: [.text("bold")]), .text(" and "),
                                              .link(destination: "https://x.io", children: [.text("link")]),
                                              .text(" with "), .code("a_b")])]
let pt = T.text(blocks: para)
result("strong / link / code render as their text", pt == "A bold and link with a_b")
result("markdown symbols do not match", M.count(of: "**", in: pt, limit: 9) == 0
       && M.count(of: "x.io", in: pt, limit: 9) == 0 && M.count(of: "`", in: pt, limit: 9) == 0)
let listMd: [BlockNode] = [.bulletedList(isTight: true, items: [
    RawListItem(children: [.paragraph(content: [.text("one")])]),
    RawListItem(children: [.paragraph(content: [.text("two")]),
                           .bulletedList(isTight: true, items: [RawListItem(children: [.paragraph(content: [.text("deep")])])])]),
])]
result("bullets as drawn, by depth", T.text(blocks: listMd) == "\u{2022}  one\n\u{2022}  two\n\u{25E6}  deep")
result("numbered and task lists", T.text(blocks: [.numberedList(isTight: true, start: 3, items: [
    RawListItem(children: [.paragraph(content: [.text("x")])])])]) == "3. x"
       && T.text(blocks: [.taskList(isTight: true, items: [RawTaskListItem(isCompleted: true, children: [.paragraph(content: [.text("t")])])])]) == "\u{2611} t")
let table: [BlockNode] = [.paragraph(content: [.text("before")]),
                          .table(columnAlignments: [.none, .none], rows: [
                            RawTableRow(cells: [RawTableCell(content: [.text("h1")]), RawTableCell(content: [.strong(children: [.text("h2")])])]),
                            RawTableRow(cells: [RawTableCell(content: [.text("a")]), RawTableCell(content: [.code("b")])])]),
                          .paragraph(content: [.text("after")])]
result("table cells searchable, separated", T.text(blocks: table) == "before\n\nh1\th2\na\tb\n\nafter")
result("code block content, final newline trimmed", T.text(blocks: [.codeBlock(fenceInfo: "swift", content: "let x = 1\n")]) == "let x = 1")
result("images, math and rules contribute nothing",
       T.text(blocks: [.paragraph(content: [.text("a"), .image(source: "p.png", children: [.text("alt")]), .inlineMath("x^2"), .text("b")]),
                       .thematicBreak, .mathBlock(content: "y")]) == "ab\n\n")
result("soft break beside an image is a line break",
       T.text(blocks: [.paragraph(content: [.text("cap"), .softBreak, .image(source: "p.png", children: [])])]) == "cap\n")
result("soft break between words is a space", T.text(blocks: [.paragraph(content: [.text("a"), .softBreak, .text("b")])]) == "a b")
result("zero-width / hair spaces dropped, line separator is a newline",
       T.text(blocks: [.paragraph(content: [.text("a\u{200B}b\u{200A}c\u{2028}d")])]) == "abc\nd")
result("heading and quote", T.text(blocks: [.heading(level: 2, content: [.text("Title")]),
                                            .blockquote(children: [.paragraph(content: [.text("q")])])]) == "Title\nq")
result("streaming tail appended as plain text", T.text(blocks: para, plainSuffix: "| x |") == pt + "| x |")

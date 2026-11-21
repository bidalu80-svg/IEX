"""Extract shipping search presentation dependencies for production card harnesses."""
from pathlib import Path


def search_support(root: Path, *, question: bool = False) -> str:
    source = (root / "Views/Chat/ChatSearch.swift").read_text(encoding="utf-8")
    parser = (root / "Agent/Markdown/ZeMarkdownParser.swift").read_text(encoding="utf-8")
    names = ["chat-search-engine", "chat-search-highlights"]
    if question:
        names.append("chat-search-question-text")
    parts = ["import Foundation\nimport SwiftUI\nimport UIKit\nimport Combine\n"]
    start = parser.index("struct SimpleSegmentID:")
    end = parser.index("// MARK: - MarkdownContent", start)
    parts.append(parser[start:end])
    for name in names:
        start = source.index("// BEGIN " + name)
        end = source.index("// END " + name, start)
        parts.append(source[start:end])
    return "\n".join(parts)

import Foundation

func check(_ name: String, content: CGFloat, viewport: CGFloat = 600,
           top: CGFloat = 60, bottom: CGFloat = 120, base: CGFloat = 80,
           safe: CGFloat = 0, current: CGFloat = 0, follow: Bool = true,
           expected: CGFloat) {
    let target = ChatListScrollTarget.resolve(contentHeight: content, viewportHeight: viewport,
        adjustedTop: top, adjustedBottom: bottom, baseBottom: base, safeAreaBottom: safe,
        current: current, followsBottom: follow)
    precondition(abs(target - expected) < 0.0001, "\(name): \(target) != \(expected)")
    let repeated = ChatListScrollTarget.resolve(contentHeight: content, viewportHeight: viewport,
        adjustedTop: top, adjustedBottom: bottom, baseBottom: base, safeAreaBottom: safe,
        current: target, followsBottom: follow)
    precondition(repeated == target, "\(name): repeated geometry must be idempotent")
    print("PASS: \(name)")
}

check("short content with a negative top limit", content: 100, expected: -60)
check("long content follows the base inset", content: 1000, expected: 480)
check("safe-area bottom", content: 1000, bottom: 114, safe: 34, expected: 514)
check("inflation does not become the visual target", content: 1000, bottom: 250, expected: 480)
check("browsing preserves a legal negative offset", content: 1000, current: -50, follow: false, expected: -50)
check("browsing clamps at the top", content: 1000, current: -100, follow: false, expected: -60)
check("browsing clamps at the bottom", content: 1000, current: 900, follow: false, expected: 520)
check("browsing a short list", content: 100, current: 50, follow: false, expected: -60)
check("safe area is clamped to the actual scroll range", content: 1000, bottom: 100, safe: 34, expected: 500)
check("short content with a header overlay", content: 100, top: 180, expected: -180)

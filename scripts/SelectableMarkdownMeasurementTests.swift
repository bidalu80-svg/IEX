import CoreGraphics

@main
struct SelectableMarkdownMeasurementTests {
    static func main() {
        func expect(_ actual: CGFloat, _ expected: CGFloat, _ label: String) {
            guard actual == expected else { fatalError("FAIL: \(label): \(actual) != \(expected)") }
            print("PASS: \(label)")
        }
        typealias Policy = SelectableMarkdownMeasurementPolicy
        expect(Policy.finiteWidth(proposed: .infinity, fallback: 390), 390, "positive infinity falls back before rounded cache key")
        expect(Policy.finiteWidth(proposed: -.infinity, fallback: 390), 390, "negative infinity falls back")
        expect(Policy.finiteWidth(proposed: .nan, fallback: 390), 390, "NaN falls back")
        expect(Policy.finiteWidth(proposed: 0, fallback: 390), 390, "zero-width proposal falls back")
        expect(Policy.finiteWidth(proposed: 320, fallback: 390), 320, "finite proposal is preserved")
        expect(Policy.finiteWidth(proposed: 20000, fallback: 390), 16384, "finite extreme is bounded before Int conversion")
        expect(Policy.finiteWidth(proposed: .infinity, fallback: .nan), 393, "invalid fallback uses safe phone-width default")
    }
}

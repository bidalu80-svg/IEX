// Compiled with the exact SessionShareSelection declaration extracted from production.
// No reimplementation of the algorithm under test and no source-text assertions.
import Foundation

@main
struct SessionShareSelectionTests {
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) {
        checks += 1
        guard value else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }

    static func main() {
        // Deliberately non-sorted order: dragging follows visible row order.
        let rows = ["last", "first", "middle", "other"]
        expect(SessionShareSelection.below("first", ordered: rows) == Set(["first", "middle", "other"]), "Select below includes anchor and uses presentation order")
        expect(SessionShareSelection.below("other", ordered: rows) == Set(["other"]), "Last row includes itself")
        expect(SessionShareSelection.below("missing", ordered: rows).isEmpty, "Missing below anchor is harmless")
        expect(SessionShareSelection.below("first", ordered: [String]()).isEmpty, "Empty transcript has no suffix")
        let initial: Set<String> = ["other"]
        let forward = SessionShareSelection.dragging(from: "last", to: "middle", ordered: rows, initial: initial, selecting: true)
        expect(forward == Set(rows), "Drag selects inclusive range and preserves outside selection")
        expect(SessionShareSelection.dragging(from: "middle", to: "last", ordered: rows, initial: initial, selecting: true) == forward, "Reverse drag has identical inclusive range")
        expect(SessionShareSelection.dragging(from: "first", to: "middle", ordered: rows, initial: Set(rows), selecting: false) == Set(["last", "other"]), "Deselect drag removes only touched rows")
        expect(SessionShareSelection.dragging(from: "first", to: "first", ordered: rows, initial: [], selecting: true) == Set(["first"]), "Single-row drag selects anchor")
        expect(SessionShareSelection.dragging(from: "missing", to: "middle", ordered: rows, initial: initial, selecting: true) == initial, "Missing drag anchor preserves initial state")
        expect(SessionShareSelection.dragging(from: "first", to: "missing", ordered: rows, initial: initial, selecting: false) == initial, "Missing drag endpoint preserves initial state")
        // The gesture recalculates against the start-of-drag snapshot. Moving
        // backwards must undo transient range selection, not accumulate it.
        let contracted = SessionShareSelection.dragging(from: "last", to: "first", ordered: rows, initial: initial, selecting: true)
        expect(contracted == Set(["last", "first", "other"]), "Drag contraction does not leave old endpoint selected")
        // Exhaust all endpoints, initial subsets, and modes using an independent
        // per-row predicate as the oracle rather than a second range algorithm.
        for mask in 0..<(1 << rows.count) {
            let before = Set(rows.enumerated().compactMap { (mask & (1 << $0.offset)) != 0 ? $0.element : nil })
            for a in rows.indices {
                for b in rows.indices {
                    for selecting in [true, false] {
                        let expected = Set(rows.enumerated().compactMap { index, id -> String? in
                            let touched = index >= min(a, b) && index <= max(a, b)
                            return (touched ? selecting : before.contains(id)) ? id : nil
                        })
                        let actual = SessionShareSelection.dragging(from: rows[a], to: rows[b], ordered: rows, initial: before, selecting: selecting)
                        expect(actual == expected, "Range invariant mask=\(mask) from=\(a) to=\(b) selecting=\(selecting)")
                    }
                }
            }
        }
        print("ALL PASS (\(checks) production selection behavior checks)")
    }
}

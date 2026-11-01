import Foundation

@main
struct SessionShareRenderPolicyTests {
    static func main() {
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL: \(name)")
            print("PASS: \(name)")
        }
        typealias P = SessionShareRenderPolicy
        check(P.pageCount(height: 1000, contentHeight: 500) == 2, "Exact page boundary creates no trailing blank page")
        check(P.pageCount(height: 1001, contentHeight: 500) == 3, "One extra point creates the next page")
        for invalid: CGFloat in [0, -1, .nan, .infinity] {
            check(P.pageCount(height: invalid, contentHeight: 500) == 0, "Invalid document height rejected")
            check(P.pageCount(height: 1000, contentHeight: invalid) == 0, "Invalid page height rejected")
            check(!P.fitsImageBudget(width: 393, height: invalid), "Invalid image height rejected")
        }
        check(!P.overlaps(start: 0, height: 500, pageTop: 500, pageHeight: 500), "Ended row does not repeat on next page")
        check(!P.overlaps(start: 1000, height: 100, pageTop: 500, pageHeight: 500), "Next row does not appear on previous page")
        check(P.overlaps(start: 499, height: 2, pageTop: 500, pageHeight: 500), "Cross-page row appears on both pages")
        check(P.fitsImageBudget(width: 393, height: 2700), "Normal conversation fits one long image")
        check(!P.fitsImageBudget(width: 393, height: P.sliceHeight + 1), "Over-height conversation requires PDF")
        check(!P.fitsImageBudget(width: 100000, height: 1000), "Oversized pixel allocation is rejected")
        check(P.nextSliceHeight(total: 2700, offset: 0) == 2700, "Normal image is not split into old 2048pt chunks")
        check(P.nextSliceHeight(total: 2700, offset: 2700) == 0, "No empty tail image")
        check(P.tableCanvasWidth(base: 393, contentWidth: 600, viewportWidth: 300) == 693, "Table canvas includes horizontal overflow")
        check(P.tableCanvasWidth(base: 393, contentWidth: 9000, viewportWidth: 300) == P.maxCanvasWidth, "Table width capped at production maximum")
        check(P.tableScale(contentWidth: 1000, viewportWidth: 500) == 0.5, "Wide table scales down to fit")
        check(P.tableScale(contentWidth: 100, viewportWidth: 500) == 1, "Narrow table is never enlarged")
        print("ALL PASS: production render policy behavior")
    }
}

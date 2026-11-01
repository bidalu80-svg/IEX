#!/usr/bin/env python3
"""Prepare exact production Swift declarations with one explicit UI fixture seam.

Native renderer algorithms (measurement, host, pagination, bitmap budgeting,
image drawing, vector drawing, metadata) are NOT reimplemented. Only its
makeRowViews content factory is replaced, avoiding the complete app VM/dependency
 graph. UILabel/TextKit 1 rendering is real; MarkdownRenderView/TableScrollView
are type fixtures and not exercised. Missing boundaries fail closed.
"""
from pathlib import Path
import sys


def prepare(output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    models = Path("Views/Chat/SessionExport/SessionExportModels.swift").read_text(encoding="utf-8")
    start = models.index("enum SessionShareSelection {")
    end = models.index("\n}\n", start) + len("\n}\n")
    (output / "SessionShareSelection.swift").write_text("import Foundation\n" + models[start:end], encoding="utf-8")

    renderer = Path("Views/Chat/SessionExport/SessionExportNativeRenderer.swift").read_text(encoding="utf-8")
    policy_start = renderer.index("// BEGIN SESSION_SHARE_RENDER_POLICY")
    policy_end = renderer.index("// END SESSION_SHARE_RENDER_POLICY", policy_start)
    (output / "SessionShareRenderPolicy.swift").write_text("import Foundation\n" + renderer[policy_start:policy_end], encoding="utf-8")
    start = renderer.index("    private func makeRowViews() -> [AnyView] {")
    end = renderer.index("    /// Builds the copy that gets rendered.", start)
    # Only replace the content factory; retain every output algorithm verbatim.
    renderer = renderer[:start] + "    private func makeRowViews() -> [AnyView] { vm.fixtureRows }\n\n" + renderer[end:]
    (output / "SessionExportNativeRenderer.swift").write_text(renderer, encoding="utf-8")
    print("Prepared production selection and native renderer (fixture row factory only)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: prepare-session-share-tests.py OUTPUT_DIRECTORY")
    prepare(Path(sys.argv[1]))

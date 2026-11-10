"""Compile the real provider detail quota section and its exact helpers in UI fixtures."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = root / "Views/Providers/ProviderInstanceDetailView.swift"
text = source.read_text(encoding="utf-8")
start = text.index("    // MARK: - API Key Quota")
end = text.index("    // MARK: - Manual OAuth Token", start)
section = text[start:end]
assert "private func apiKeyQuotaSection" in section
assert "private func formatQuotaAmount" in section
output = pathlib.Path(sys.argv[1])
output.write_text("""import SwiftUI
struct ProductionDetailQuota: View {
    let instance: ProviderInstance
    @ObservedObject var quotaStore: ProviderAPIQuotaStore
    var body: some View { Form { apiKeyQuotaSection(instance) } }
""" + section + "\n}\n", encoding="utf-8")
manifest = {
    "source": str(source.relative_to(root)),
    "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "extractedSectionSHA256": hashlib.sha256(section.encode()).hexdigest(),
    "extractedWithoutModification": True,
    "container": "Real Form in UIHostingController; production section and all formatting helpers unchanged",
}
output.with_suffix(".sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

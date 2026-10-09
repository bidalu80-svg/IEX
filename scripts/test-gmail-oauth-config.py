"""Isolated build configuration tests; never touch local OAuth credentials."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/configure-gmail-oauth.py"
CLIENT = "123456789-testclient.apps.googleusercontent.com"
CALLBACK = ".".join(reversed(CLIENT.split(".")))
count = 0

def check(condition, label):
    global count
    assert condition, label
    count += 1
    print("PASS:", label)

with tempfile.TemporaryDirectory(prefix="ze-gmail-config-") as directory:
    config = Path(directory) / "ProviderCustomization.xcconfig"
    config.write_text("OTHER_SETTING = keep\nGOOGLE_GMAIL_CLIENT_ID = old\n", encoding="utf-8")
    def run(client="", *args):
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_STEP_SUMMARY", "REQUIRE_GMAIL_OAUTH", "GITHUB_ACTIONS")}
        env["GOOGLE_GMAIL_CLIENT_ID"] = client
        return subprocess.run([sys.executable, str(SCRIPT), "--config", str(config), *args], env=env, capture_output=True, text=True)
    result = run()
    check(result.returncode == 0 and "NOT configured" in result.stdout, "missing client is explicit, not a fake login")
    check("GOOGLE_GMAIL_CALLBACK_SCHEME = com.ze.gmail.unconfigured" in config.read_text(), "missing-client callback is deterministic")
    before = config.read_bytes()
    check(run("", "--require").returncode != 0 and config.read_bytes() == before, "required configuration fails without modifying file")
    for invalid in ("placeholder", "123.apps.googleusercontent.com", CLIENT + "\nEVIL=1", "client-secret"):
        check(run(invalid).returncode != 0 and config.read_bytes() == before, "reject malformed ID and preserve configuration")
    check(run(CLIENT).returncode == 0, "valid developer client accepted")
    text = config.read_text()
    check(CALLBACK in text and "OTHER_SETTING = keep" in text, "reverse-domain callback and unrelated settings preserved")
    check(run(CLIENT).returncode == 0 and config.read_text() == text, "configuration is idempotent")
    check(text.count("GOOGLE_GMAIL_CLIENT_ID =") == 1, "stale client IDs are replaced, not appended")
    plist = Path(directory) / "Info.plist"
    payload = {"GmailOAuthClientID": CLIENT, "GmailOAuthCallbackScheme": CALLBACK, "CFBundleURLTypes": [{"CFBundleURLSchemes": [CALLBACK]}]}
    plist.write_bytes(plistlib.dumps(payload))
    check(run(CLIENT, "--audit-plist", str(plist)).returncode == 0, "actual packaged plist matches the configured client")
    payload["CFBundleURLTypes"] = []
    plist.write_bytes(plistlib.dumps(payload))
    check(run(CLIENT, "--audit-plist", str(plist)).returncode != 0, "missing packaged callback fails audit")
    check(run().returncode == 0 and CLIENT not in config.read_text(), "clearing configuration removes stale IDs")
    payload = {"GmailOAuthClientID": "", "GmailOAuthCallbackScheme": "com.ze.gmail.unconfigured", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["com.ze.gmail.unconfigured"]}]}
    plist.write_bytes(plistlib.dumps(payload))
    check(run("", "--audit-plist", str(plist)).returncode == 0, "unconfigured builds are audited honestly")
print(f"Gmail OAuth configuration tests passed: {count}")

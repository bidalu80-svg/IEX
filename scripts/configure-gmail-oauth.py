"""Configure only a developer-owned Google iOS OAuth client. No client secret."""
import argparse
import os
import plistlib
import re
from pathlib import Path


def validated_client(value):
    client = value.strip()
    if client and not re.fullmatch(r"[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com", client):
        raise ValueError("Expected a Google iOS OAuth client ID, not a secret or placeholder")
    return client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("Configs/ProviderCustomization.xcconfig"))
    parser.add_argument("--require", action="store_true", help="Fail a Gmail-enabled release if the client is missing")
    parser.add_argument("--audit-plist", type=Path, help="Check the actual packaged app configuration")
    args = parser.parse_args()
    client = validated_client(os.environ.get("GOOGLE_GMAIL_CLIENT_ID", ""))
    if (args.require or os.environ.get("REQUIRE_GMAIL_OAUTH") == "1") and not client:
        raise ValueError("Gmail-enabled release requires GOOGLE_GMAIL_CLIENT_ID")
    callback = ".".join(reversed(client.split("."))) if client else "com.ze.gmail.unconfigured"
    if args.audit_plist:
        plist = plistlib.loads(args.audit_plist.read_bytes())
        schemes = [scheme for row in plist.get("CFBundleURLTypes", []) for scheme in row.get("CFBundleURLSchemes", [])]
        if (plist.get("GmailOAuthClientID", "") != client or plist.get("GmailOAuthCallbackScheme") != callback or callback not in schemes):
            raise ValueError("Packaged Gmail client/callback does not match this build configuration")
        print("Packaged Gmail OAuth configuration audited: " + ("configured" if client else "explicitly unconfigured"))
        return
    original = args.config.read_text(encoding="utf-8-sig")
    lines = [line for line in original.splitlines() if not re.match(r"^\s*GOOGLE_GMAIL_(CLIENT_ID|CALLBACK_SCHEME)\s*=", line)]
    text = "\n".join(lines).rstrip() + "\n\nGOOGLE_GMAIL_CLIENT_ID = " + client + "\nGOOGLE_GMAIL_CALLBACK_SCHEME = " + callback + "\n"
    args.config.write_text(text, encoding="utf-8", newline="\n")
    status = ("Google iOS OAuth client and callback configured; real account acceptance is still required." if client else
              "Gmail OAuth is NOT configured: Google login remains disabled. QQ/IMAP is available. Set GOOGLE_GMAIL_CLIENT_ID and rebuild.")
    print(status)
    if not client and os.environ.get("GITHUB_ACTIONS") == "true":
        print("::warning title=Gmail login not enabled::" + status)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("\n### Gmail OAuth configuration\n" + status + "\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))

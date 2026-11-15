#!/usr/bin/env python3
"""Publish the review IPA only after this exact run passes both full-app runtimes."""
import json, os, time, urllib.request
required = {"soul-header-review", "soul-header-legacy-review"}
url = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}/jobs?per_page=100"
request = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
while True:
    with urllib.request.urlopen(request, timeout=60) as response:
        jobs = [job for job in json.load(response)["jobs"] if job["name"] in required]
    assert {job["name"] for job in jobs} == required, "Both header verification jobs must exist"
    failures = [(job["name"], job["conclusion"]) for job in jobs if job["status"] == "completed" and job["conclusion"] != "success"]
    assert not failures, f"IPA publication blocked by runtime failure: {failures}"
    if all(job["conclusion"] == "success" for job in jobs):
        print("Both complete-app runtimes passed at", os.environ["GITHUB_SHA"], flush=True)
        break
    print("Waiting for both full-app header verifications before uploading IPA", flush=True)
    time.sleep(20)

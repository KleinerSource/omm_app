#!/usr/bin/env python3
"""Find a public FFmpegKit release built from the requested component commits."""

import json
import os
import sys
from urllib.request import Request, urlopen


RELEASES_URL = "https://api.github.com/repos/KleinerSource/FFmpegKit/releases?per_page=100"


def fetch_json(url):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "KleinerSource-omm-app-ci",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("COMPONENTS_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(url, headers=headers)
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def find_matching_release(ksplayer_revision, ffmpegkit_revision, load_json=None):
    if load_json is None:
        load_json = fetch_json
    releases = load_json(RELEASES_URL)
    if not isinstance(releases, list):
        raise ValueError("FFmpegKit releases API 返回格式无效")
    for release in releases:
        if not isinstance(release, dict):
            continue
        tag = release.get("tag_name", "")
        if release.get("draft") or release.get("prerelease") or not tag.startswith("ios-native-"):
            continue
        asset = next((item for item in release.get("assets", [])
                      if item.get("name") == "release-manifest.json"), None)
        if asset is None or not asset.get("browser_download_url"):
            continue
        try:
            manifest = load_json(asset["browser_download_url"])
        except (OSError, ValueError):
            continue
        if not isinstance(manifest, dict):
            continue
        fingerprint = manifest.get("fingerprint", {})
        sources = manifest.get("sources", {})
        if (manifest.get("tag") == tag
                and fingerprint.get("ksplayer_revision") == ksplayer_revision
                and fingerprint.get("ffmpegkit_revision") == ffmpegkit_revision
                and sources.get("KSPlayer") == ksplayer_revision
                and sources.get("DisplayCriteria") == ksplayer_revision
                and sources.get("FFmpegKit") == ffmpegkit_revision
                and sources.get("Libass") == ffmpegkit_revision):
            return tag
    return ""


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: find_ios_native_release.py KSPLAYER_SHA FFMPEGKIT_SHA")
    print(find_matching_release(sys.argv[1], sys.argv[2]))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f"无法查询 iOS 原生组件 Release: {error}") from error

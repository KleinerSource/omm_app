import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "find_ios_native_release", Path(__file__).with_name("find_ios_native_release.py")
)
find_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(find_release)


class ReleaseLookupTests(unittest.TestCase):
    def setUp(self):
        self.ksplayer = "a" * 40
        self.ffmpegkit = "f" * 40
        self.tag = "ios-native-" + "1" * 64
        self.releases = [
            {"tag_name": "ios-native-draft", "draft": True, "assets": []},
            {"tag_name": "ios-native-stale", "assets": [
                {"name": "release-manifest.json", "browser_download_url": "https://example.test/stale"}
            ]},
            {"tag_name": self.tag, "assets": [
                {"name": "release-manifest.json", "browser_download_url": "https://example.test/match"}
            ]},
        ]
        self.manifest = {
            "tag": self.tag,
            "fingerprint": {
                "ksplayer_revision": self.ksplayer,
                "ffmpegkit_revision": self.ffmpegkit,
                "native_cache_key": "b" * 64,
            },
            "sources": {
                "KSPlayer": self.ksplayer,
                "DisplayCriteria": self.ksplayer,
                "FFmpegKit": self.ffmpegkit,
                "Libass": self.ffmpegkit,
            },
        }

    def test_reuses_release_matching_source_commits(self):
        responses = {
            find_release.RELEASES_URL: self.releases,
            "https://example.test/stale": {"sources": {}},
            "https://example.test/match": self.manifest,
        }
        with patch.object(find_release, "fetch_json", side_effect=lambda url: responses[url]):
            self.assertEqual(
                find_release.find_matching_release(self.ksplayer, self.ffmpegkit), self.tag
            )

    def test_returns_empty_when_no_release_matches_sources(self):
        responses = {
            find_release.RELEASES_URL: self.releases[:2],
            "https://example.test/stale": {"sources": {}},
        }
        with patch.object(find_release, "fetch_json", side_effect=lambda url: responses[url]):
            self.assertEqual(find_release.find_matching_release(self.ksplayer, self.ffmpegkit), "")


if __name__ == "__main__":
    unittest.main()

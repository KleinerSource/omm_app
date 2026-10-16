import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location(
    "verify_ios_native_release", Path(__file__).with_name("verify_ios_native_release.py")
)
verify_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_release)


class ReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ios-native-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identity = {
            "tag": "ios-native-" + "1" * 64,
            "ffmpegkit_revision": "f" * 40,
            "ksplayer_revision": "a" * 40,
            "native_cache_key": "b" * 64,
        }
        self.sources = {
            "KSPlayer": self.identity["ksplayer_revision"],
            "DisplayCriteria": self.identity["ksplayer_revision"],
            "FFmpegKit": self.identity["ffmpegkit_revision"],
            "Libass": self.identity["ffmpegkit_revision"],
        }
        self.manifest = {
            "schema": 1,
            "tag": self.identity["tag"],
            "fingerprint": json.loads(json.dumps(self.identity)),
            "sources": self.sources,
            "ffmpeg_version": "n8.1",
            "libav_versions": {"libavcodec": "62.28.100"},
        }
        self.archive_path = self.root / "ios-native-pods.zip"
        self.manifest_path = self.root / "release-manifest.json"
        self.write_archive()

    def write_archive(self, overrides=None):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        info = {
            "AvailableLibraries": [
                {"SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]},
                {"SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator",
                 "SupportedArchitectures": ["arm64", "x86_64"]},
            ]
        }
        with zipfile.ZipFile(self.archive_path, "w") as archive:
            archive.writestr("release-manifest.json", json.dumps(self.manifest))
            archive.writestr("pods/FFmpegKit/native-versions.json", json.dumps({"components": self.sources}))
            for name, path in verify_release.FRAMEWORKS.items():
                archive.writestr(path, plistlib.dumps((overrides or {}).get(name, info)))

    def test_accepts_matching_source_and_all_required_slices(self):
        verify_release.verify(self.archive_path, self.manifest_path, self.identity,
                              self.identity["ksplayer_revision"], self.identity["ffmpegkit_revision"])

    def test_rejects_stale_component_fingerprint(self):
        self.manifest["fingerprint"]["ksplayer_revision"] = "c" * 40
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "指纹"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity,
                                  self.identity["ksplayer_revision"], self.identity["ffmpegkit_revision"])

    def test_rejects_missing_simulator_architecture(self):
        bad_info = {"AvailableLibraries": [
            {"SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]},
            {"SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator",
             "SupportedArchitectures": ["arm64"]},
        ]}
        self.write_archive({"KSPlayer": bad_info})
        with self.assertRaisesRegex(ValueError, "KSPlayer 缺少模拟器"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity,
                                  self.identity["ksplayer_revision"], self.identity["ffmpegkit_revision"])


if __name__ == "__main__":
    unittest.main()

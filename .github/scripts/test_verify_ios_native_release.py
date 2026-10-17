import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
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
            "tag": "ios-native-latest",
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
            for path in ("pods/KSPlayer/KSPlayer.podspec", "pods/KSPlayer/DisplayCriteria.podspec",
                         "pods/KSPlayer/Resources/Metal/Shaders.metal", "pods/FFmpegKit/FFmpegKit.podspec",
                         "pods/FFmpegKit/Libass.podspec"):
                archive.writestr(path, "fixture")

    def test_accepts_latest_release_without_resolving_remote_main(self):
        verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_accepts_release_with_a_different_build_cache_key(self):
        self.manifest["fingerprint"]["native_cache_key"] = "c" * 64
        self.write_archive()
        verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_rejects_inconsistent_component_fingerprint(self):
        self.manifest["fingerprint"]["ksplayer_revision"] = "c" * 40
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "源码提交不匹配: KSPlayer"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_rejects_a_nonrolling_manifest_tag(self):
        with self.assertRaisesRegex(ValueError, "标签"):
            verify_release.verify(self.archive_path, self.manifest_path, "ios-native-old")

    def test_rejects_an_invalid_source_revision(self):
        self.manifest["fingerprint"]["ksplayer_revision"] = "main"
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "提交格式"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_rejects_mixed_assets_during_a_rolling_update(self):
        self.manifest["fingerprint"]["ksplayer_revision"] = "b" * 40
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "外部清单"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_rejects_missing_simulator_architecture(self):
        bad_info = {"AvailableLibraries": [
            {"SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]},
            {"SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator",
             "SupportedArchitectures": ["arm64"]},
        ]}
        self.write_archive({"KSPlayer": bad_info})
        with self.assertRaisesRegex(ValueError, "KSPlayer 缺少模拟器"):
            verify_release.verify(self.archive_path, self.manifest_path, self.identity["tag"])

    def test_download_script_uses_latest_without_component_credentials(self):
        result, workspace = self.run_download_script("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((workspace / "source/build/ios-native/pods/KSPlayer/KSPlayer.podspec").is_file())
        self.assertIn("release_tag=ios-native-latest", (self.root / "github-output").read_text(encoding="utf-8"))

    def test_download_script_retries_a_partially_updated_release(self):
        result, workspace = self.run_download_script("retry")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        requests = (self.root / "requests").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(requests), 6)
        self.assertTrue(all("/ios-native-latest/" in url for url in requests))

    def test_missing_release_keeps_existing_pods_and_reports_the_required_action(self):
        result, workspace = self.run_download_script("missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("请先在 FFmpegKit 仓库成功发布", result.stderr)
        sentinel = workspace / "source/build/ios-native/pods/existing.txt"
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "previous components")
        self.assertEqual(len((self.root / "requests").read_text(encoding="utf-8").splitlines()), 3)

    def run_download_script(self, mode):
        bash = shutil.which("bash") or "C:/Program Files/Git/bin/bash.exe"
        if not Path(bash).is_file():
            self.skipTest("Bash is required to execute the download script")
        checksum = hashlib.sha256(self.archive_path.read_bytes()).hexdigest()
        (self.root / "ios-native-pods.zip.sha256").write_text(
            f"{checksum}  ios-native-pods.zip\n", encoding="ascii")
        commands = self.root / "commands"
        commands.mkdir()
        mock = self.root / "mock_commands.py"
        mock.write_text('''import hashlib, os, pathlib, shutil, sys
root = pathlib.Path(os.environ["NATIVE_TEST_ROOT"])
command, *args = sys.argv[1:]
if command == "python3":
    os.execv(sys.executable, [sys.executable, *args])
elif command == "curl":
    url = next(arg for arg in args if arg.startswith("https://"))
    with (root / "requests").open("a", encoding="utf-8") as log:
        log.write(url + "\\n")
    if os.environ["NATIVE_TEST_MODE"] == "missing":
        sys.exit(22)
    name = url.rsplit("/", 1)[-1]
    output = pathlib.Path(args[args.index("--output") + 1])
    if os.environ["NATIVE_TEST_MODE"] == "retry" and name.endswith(".zip") and not (root / "retried").exists():
        output.write_bytes(b"partial release")
        (root / "retried").touch()
    else:
        shutil.copyfile(root / name, output)
elif command == "shasum":
    expected, name = pathlib.Path(args[-1]).read_text(encoding="ascii").split()
    sys.exit(0 if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == expected else 1)
elif command != "sleep":
    raise RuntimeError("Unexpected source checkout or cross-repository operation: " + command)
''', encoding="utf-8")
        for command in ("python3", "curl", "shasum", "sleep", "git", "gh"):
            wrapper = commands / command
            wrapper.write_text('#!/usr/bin/env bash\nexec "$NATIVE_TEST_PYTHON" "$NATIVE_TEST_MOCK" '
                               f'{command} "$@"\n', encoding="utf-8", newline="\n")
            wrapper.chmod(0o755)
        workspace = (self.root / "workspace").resolve()
        sentinel = workspace / "source/build/ios-native/pods/existing.txt"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("previous components", encoding="utf-8")
        runner = self.root / "runner"
        runner.mkdir()
        env = {key: value for key, value in os.environ.items()
               if key not in ("COMPONENTS_TOKEN", "KSPLAYER_REVISION", "FFMPEGKIT_REVISION", "GH_TOKEN")}
        env.update({"PATH": str(commands) + os.pathsep + env["PATH"],
                    "NATIVE_TEST_ROOT": self.root.as_posix(), "NATIVE_TEST_MODE": mode,
                    "NATIVE_TEST_BIN": commands.as_posix(),
                    "NATIVE_TEST_PYTHON": Path(sys.executable).as_posix(), "NATIVE_TEST_MOCK": mock.as_posix(),
                    "RUNNER_TEMP": runner.as_posix(), "GITHUB_WORKSPACE": workspace.as_posix(),
                    "GITHUB_ENV": (self.root / "github-env").as_posix(),
                    "GITHUB_OUTPUT": (self.root / "github-output").as_posix()})
        test_path = '$(cygpath -u "$NATIVE_TEST_BIN")' if os.name == "nt" else '$NATIVE_TEST_BIN'
        command = f'export PATH="{test_path}:$PATH"; exec bash .github/scripts/build_ios_native.sh release'
        result = subprocess.run([bash, "-c", command],
                                cwd=Path(__file__).resolve().parents[2], env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        return result, workspace


if __name__ == "__main__":
    unittest.main()

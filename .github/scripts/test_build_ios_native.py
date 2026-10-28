import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class NativeDownloadIntegrationTest(unittest.TestCase):
    def run_script(self, mode):
        bash = shutil.which("bash") or "C:/Program Files/Git/bin/bash.exe"
        if not Path(bash).is_file():
            self.skipTest("Bash is required")
        temporary = tempfile.TemporaryDirectory(prefix="official-native-")
        self.addCleanup(temporary.cleanup)
        workspace = Path(temporary.name).resolve()
        source = workspace / "source"
        (source / "tool").mkdir(parents=True)
        (source / "packages").mkdir()
        (source / "packages/ffmpegkit-next.lock.json").write_text(json.dumps({"ksplayer_revision": "a" * 40}), encoding="utf-8")
        (source / "tool/fetch_ffmpegkit_next.py").write_text('''import argparse,json,os,pathlib,sys
p=argparse.ArgumentParser();p.add_argument('--output');o=pathlib.Path(p.parse_args().output)
if os.environ['TEST_NATIVE_MODE']=='failure':sys.exit(19)
for name in ('KSPlayer/KSPlayer.podspec','KSPlayer/DisplayCriteria.podspec','KSPlayer/KSFFmpegBridge.podspec',
             'FFmpegKitNext/FFmpegKitNext.podspec','FFmpegKitNext/native-versions.json',
             'FFmpegKitNext/Frameworks/ffmpegkit.xcframework/Info.plist'):
 if os.environ['TEST_NATIVE_MODE']=='missing' and 'KSFFmpegBridge' in name:continue
 f=o/'pods'/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text('verified')
(o/'release-manifest.json').write_text(json.dumps({'release':'ffmpegkit-next-9.0.2-ios-r1'}))
(o/'ffmpegkit-next-ios.zip.sha256').write_text('b'*64+'  ffmpegkit-next-ios.zip')
''', encoding="utf-8")
        sentinel = source / "build/ios-native/pods/old"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text("keep", encoding="utf-8")
        runner = workspace / "runner"
        runner.mkdir()
        env = dict(os.environ, GITHUB_WORKSPACE=workspace.as_posix(), RUNNER_TEMP=runner.as_posix(),
                   GITHUB_ENV=(workspace / "github-env").as_posix(),
                   GITHUB_OUTPUT=(workspace / "github-output").as_posix(), TEST_NATIVE_MODE=mode,
                   NATIVE_TEST_PYTHON=Path(sys.executable).as_posix())
        script = Path(__file__).with_name("build_ios_native.sh")
        command = 'python3() { "$NATIVE_TEST_PYTHON" "$@"; }; export -f python3; exec bash "$1" release'
        result = subprocess.run([bash, "-c", command, "test", script.as_posix()], env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        return result, workspace

    def test_verified_download_exports_versioned_identity(self):
        result, workspace = self.run_script("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((workspace / "source/build/ios-native/pods/old").exists())
        output = (workspace / "github-output").read_text(encoding="utf-8")
        self.assertIn("release_tag=ffmpegkit-next-9.0.2-ios-r1", output)
        self.assertIn("ksplayer_revision=" + "a" * 40, output)

    def test_download_failure_preserves_installed_dependencies(self):
        result, workspace = self.run_script("failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((workspace / "source/build/ios-native/pods/old").read_text(), "keep")

    def test_missing_bridge_preserves_installed_dependencies(self):
        result, workspace = self.run_script("missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((workspace / "source/build/ios-native/pods/old").read_text(), "keep")

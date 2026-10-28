#!/usr/bin/env bash
set -euo pipefail
mode="${1:-release}"
if [[ "$mode" != release ]]; then
  printf 'usage: %s [release]\n' "$0" >&2
  exit 2
fi
native_output="${GITHUB_WORKSPACE}/source/build/ios-native"
staging_dir="$(mktemp -d "${RUNNER_TEMP}/omm-official-native.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
python3 "$GITHUB_WORKSPACE/source/tool/fetch_ffmpegkit_next.py" --output "$staging_dir"
for artifact in \
  pods/KSPlayer/KSPlayer.podspec \
  pods/KSPlayer/DisplayCriteria.podspec \
  pods/KSPlayer/KSFFmpegBridge.podspec \
  pods/FFmpegKitNext/FFmpegKitNext.podspec \
  pods/FFmpegKitNext/Frameworks/ffmpegkit.xcframework/Info.plist \
  pods/FFmpegKitNext/native-versions.json; do
  [[ -f "$staging_dir/$artifact" ]] || { echo "Missing verified native artifact: $artifact" >&2; exit 1; }
done
[[ "$native_output" == "$GITHUB_WORKSPACE/source/build/ios-native" ]]
mkdir -p "$native_output"
rm -rf "$native_output/pods"
mv "$staging_dir/pods" "$native_output/pods"
cp "$staging_dir/release-manifest.json" "$native_output/release-manifest.json"
cp "$staging_dir/ffmpegkit-next-ios.zip.sha256" "$native_output/ffmpegkit-next-ios.zip.sha256"
printf 'IOS_NATIVE_PODS=%s\n' "$native_output/pods" >> "$GITHUB_ENV"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  python3 - "$native_output" "$GITHUB_WORKSPACE/source/packages/ffmpegkit-next.lock.json" >> "$GITHUB_OUTPUT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'release-manifest.json').read_text(encoding='utf-8'))
lock = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8'))
print('release_tag=' + manifest['release'])
print('ksplayer_revision=' + lock['ksplayer_revision'])
print('native_checksum=' + (root / 'ffmpegkit-next-ios.zip.sha256').read_text(encoding='utf-8').split()[0])
PY
fi

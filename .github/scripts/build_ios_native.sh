#!/usr/bin/env bash
set -euo pipefail

mode="${1:-release}"
if [[ "$mode" != release ]]; then
  printf 'usage: %s [release]\n' "$0" >&2
  exit 2
fi

RELEASE_TAG="ios-native-latest"
native_output="${GITHUB_WORKSPACE}/source/build/ios-native"
download_dir="$(mktemp -d "${RUNNER_TEMP}/omm-ios-release.XXXXXX")"
staging_dir="$(mktemp -d "${RUNNER_TEMP}/omm-ios-pods.XXXXXX")"
release_url="https://github.com/KleinerSource/FFmpegKit/releases/download/$RELEASE_TAG"
for attempt in 1 2 3; do
  downloaded=true
  for asset in ios-native-pods.zip ios-native-pods.zip.sha256 release-manifest.json; do
    curl --fail --silent --show-error --location --max-time 600 \
      "$release_url/$asset" --output "$download_dir/$asset" || { downloaded=false; break; }
  done
  if [[ "$downloaded" == true ]] && \
      (cd "$download_dir" && shasum -a 256 -c ios-native-pods.zip.sha256) && \
      python3 .github/scripts/verify_ios_native_release.py \
        "$download_dir/ios-native-pods.zip" "$download_dir/release-manifest.json" "$RELEASE_TAG"; then
    break
  fi
  if [[ "$attempt" == 3 ]]; then
    echo '无法取得完整的 ios-native-latest 制品，请先在 FFmpegKit 仓库成功发布最新 Release 后重试。' >&2
    exit 1
  fi
  sleep 5
done

# 迁移期间也可复用旧组合包中的底层库，忽略其中的播放器二进制。
python3 - "$download_dir/ios-native-pods.zip" "$staging_dir" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    members = [name for name in archive.namelist() if name.startswith('pods/FFmpegKit/')]
    archive.extractall(sys.argv[2], members=members)
PY
git clone --quiet --depth=1 --branch main \
  https://github.com/KleinerSource/KSPlayer.git "$staging_dir/pods/KSPlayer"
ksplayer_revision="$(git -C "$staging_dir/pods/KSPlayer" rev-parse HEAD)"
native_checksum="$(awk 'NR == 1 { print $1 }' "$download_dir/ios-native-pods.zip.sha256")"
[[ "$ksplayer_revision" =~ ^[0-9a-f]{40}$ && "$native_checksum" =~ ^[0-9a-f]{64}$ ]]
printf 'KSPlayer 源码提交: %s\n底层库归档 SHA-256: %s\n' "$ksplayer_revision" "$native_checksum"
for artifact in \
  "$staging_dir/pods/KSPlayer/KSPlayer.podspec" \
  "$staging_dir/pods/KSPlayer/DisplayCriteria.podspec" \
  "$staging_dir/pods/KSPlayer/Sources/KSPlayer/MEPlayer/KSMEPlayer.swift" \
  "$staging_dir/pods/KSPlayer/Sources/DisplayCriteria" \
  "$staging_dir/pods/KSPlayer/Sources/KSPlayer/Metal/Shaders.metal" \
  "$staging_dir/pods/FFmpegKit/FFmpegKit.podspec" \
  "$staging_dir/pods/FFmpegKit/Libass.podspec" \
  "$staging_dir/pods/FFmpegKit/Frameworks/FFmpegKit.xcframework/Info.plist" \
  "$staging_dir/pods/FFmpegKit/native-versions.json"; do
  [[ -e "$artifact" ]] || { echo "Release 制品缺失: $artifact" >&2; exit 1; }
done

[[ "$native_output" == "$GITHUB_WORKSPACE/source/build/ios-native" ]]
mkdir -p "$native_output"
[[ "$native_output/pods" == "$GITHUB_WORKSPACE/source/build/ios-native/pods" ]]
rm -rf "$native_output/pods"
mv "$staging_dir/pods" "$native_output/pods"
cp "$download_dir/release-manifest.json" "$native_output/release-manifest.json"
cp "$download_dir/ios-native-pods.zip.sha256" "$native_output/ios-native-pods.zip.sha256"
printf 'IOS_NATIVE_PODS=%s\n' "$native_output/pods" >> "$GITHUB_ENV"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'release_tag=%s\n' "$RELEASE_TAG" >> "$GITHUB_OUTPUT"
  printf 'ksplayer_revision=%s\nnative_checksum=%s\n' "$ksplayer_revision" "$native_checksum" >> "$GITHUB_OUTPUT"
fi

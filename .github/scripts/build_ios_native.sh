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

unzip -q "$download_dir/ios-native-pods.zip" -d "$staging_dir"
for artifact in \
  "$staging_dir/pods/KSPlayer/KSPlayer.podspec" \
  "$staging_dir/pods/KSPlayer/DisplayCriteria.podspec" \
  "$staging_dir/pods/KSPlayer/Frameworks/KSPlayer.xcframework/Info.plist" \
  "$staging_dir/pods/KSPlayer/Frameworks/DisplayCriteria.xcframework/Info.plist" \
  "$staging_dir/pods/KSPlayer/Resources/Metal/Shaders.metal" \
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
fi

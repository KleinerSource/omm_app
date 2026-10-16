#!/usr/bin/env bash
set -euo pipefail

mode="${1:-release}"
: "${KSPLAYER_REPOSITORY:?KSPLAYER_REPOSITORY is required}"
: "${FFMPEGKIT_REPOSITORY:?FFMPEGKIT_REPOSITORY is required}"
KSPLAYER_BRANCH="${KSPLAYER_BRANCH:-main}"
FFMPEGKIT_BRANCH="${FFMPEGKIT_BRANCH:-main}"

components_root="${RUNNER_TEMP}/omm-ios-components"
native_output="${GITHUB_WORKSPACE}/source/build/ios-native"
mkdir -p "$components_root"

if [[ -n "${COMPONENTS_TOKEN:-}" ]]; then
  auth="$(printf 'x-access-token:%s' "$COMPONENTS_TOKEN" | base64 | tr -d '\r\n')"
  export GH_TOKEN="$COMPONENTS_TOKEN"
fi

git_with_components_auth() {
  if [[ -n "${COMPONENTS_TOKEN:-}" ]]; then
    command git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" "$@"
  else
    command git "$@"
  fi
}

latest_revision() {
  local repository="$1" branch="$2" revision
  revision="$(git_with_components_auth ls-remote --exit-code "$repository" "refs/heads/$branch" | awk 'NR == 1 { print $1 }')"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]]
  printf '%s' "$revision"
}

checkout_component() {
  local name="$1" repository="$2" branch="$3" revision="$4" destination="$components_root/$name"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]]
  if [[ ! -d "$destination/.git" ]]; then
    git_with_components_auth clone --depth=1 --filter=blob:none --no-checkout --quiet \
      --branch "$branch" --single-branch "$repository" "$destination"
  fi
  if [[ "$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
    git_with_components_auth -C "$destination" fetch --quiet origin "$revision"
    git -C "$destination" checkout --quiet --detach "$revision"
  fi
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]]
}

if [[ "$mode" == plan ]]; then
  KSPLAYER_REVISION="$(latest_revision "$KSPLAYER_REPOSITORY" "$KSPLAYER_BRANCH")"
  FFMPEGKIT_REVISION="$(latest_revision "$FFMPEGKIT_REPOSITORY" "$FFMPEGKIT_BRANCH")"
  checkout_component KSPlayer "$KSPLAYER_REPOSITORY" "$KSPLAYER_BRANCH" "$KSPLAYER_REVISION"
  checkout_component FFmpegKit "$FFMPEGKIT_REPOSITORY" "$FFMPEGKIT_BRANCH" "$FFMPEGKIT_REVISION"
  identity="$(python3 "$components_root/FFmpegKit/iOSNative/build.py" release-key \
    --components-dir "$components_root")"
  RELEASE_TAG="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])' <<< "$identity")"
  [[ "$RELEASE_TAG" =~ ^ios-native-[0-9a-f]{64}$ ]]
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'ksplayer_revision=%s\n' "$KSPLAYER_REVISION"
      printf 'ffmpegkit_revision=%s\n' "$FFMPEGKIT_REVISION"
      printf 'release_tag=%s\n' "$RELEASE_TAG"
    } >> "$GITHUB_OUTPUT"
  else
    printf 'KSPLAYER_REVISION=%s\nFFMPEGKIT_REVISION=%s\nRELEASE_TAG=%s\n' \
      "$KSPLAYER_REVISION" "$FFMPEGKIT_REVISION" "$RELEASE_TAG"
  fi
  exit 0
fi

if [[ "$mode" != release ]]; then
  printf 'usage: %s [plan|release]\n' "$0" >&2
  exit 2
fi

: "${KSPLAYER_REVISION:?KSPLAYER_REVISION is required}"
: "${FFMPEGKIT_REVISION:?FFMPEGKIT_REVISION is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${COMPONENTS_TOKEN:?COMPONENTS_TOKEN is required to read and dispatch component Releases}"
checkout_component KSPlayer "$KSPLAYER_REPOSITORY" "$KSPLAYER_BRANCH" "$KSPLAYER_REVISION"
checkout_component FFmpegKit "$FFMPEGKIT_REPOSITORY" "$FFMPEGKIT_BRANCH" "$FFMPEGKIT_REVISION"

identity="$(python3 "$components_root/FFmpegKit/iOSNative/build.py" release-key \
  --components-dir "$components_root")"
[[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])' <<< "$identity")" == "$RELEASE_TAG" ]]

if ! gh release view "$RELEASE_TAG" --repo KleinerSource/FFmpegKit >/dev/null 2>&1; then
  dispatch_epoch="$(date -u +%s)"
  gh workflow run ios-native.yml --repo KleinerSource/FFmpegKit --ref main \
    -f "ffmpegkit_revision=$FFMPEGKIT_REVISION" \
    -f "ksplayer_revision=$KSPLAYER_REVISION" \
    -f "expected_release_tag=$RELEASE_TAG"

  run_id=""
  for attempt in {1..60}; do
    run_id="$(gh run list --repo KleinerSource/FFmpegKit --workflow ios-native.yml \
      --event workflow_dispatch --limit 10 --json databaseId,createdAt | python3 -c \
      'import datetime,json,sys; rows=json.load(sys.stdin); cutoff=int(sys.argv[1])-5; print(next((str(row["databaseId"]) for row in rows if int(datetime.datetime.fromisoformat(row["createdAt"].replace("Z", "+00:00")).timestamp()) >= cutoff), ""))' \
      "$dispatch_epoch")"
    [[ -n "$run_id" ]] && break
    sleep 2
  done
  [[ -n "$run_id" ]] || { echo '无法定位触发的 FFmpegKit Release 构建' >&2; exit 1; }

  deadline=$((SECONDS + 5400))
  until gh release view "$RELEASE_TAG" --repo KleinerSource/FFmpegKit >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "等待组件 Release 超时: $RELEASE_TAG" >&2
      gh run view "$run_id" --repo KleinerSource/FFmpegKit --json status,conclusion,url >&2 || true
      exit 1
    fi
    state="$(gh run view "$run_id" --repo KleinerSource/FFmpegKit --json status,conclusion --jq '[.status,.conclusion] | @tsv')"
    status="${state%%$'\t'*}"
    conclusion="${state#*$'\t'}"
    if [[ "$status" == completed && "$conclusion" != success ]]; then
      gh run view "$run_id" --repo KleinerSource/FFmpegKit --json status,conclusion,url >&2
      exit 1
    fi
    sleep 15
  done
fi

download_dir="$(mktemp -d "${RUNNER_TEMP}/omm-ios-release.XXXXXX")"
staging_dir="$(mktemp -d "${RUNNER_TEMP}/omm-ios-pods.XXXXXX")"
gh release download "$RELEASE_TAG" --repo KleinerSource/FFmpegKit \
  --pattern ios-native-pods.zip --pattern ios-native-pods.zip.sha256 \
  --pattern release-manifest.json --dir "$download_dir"
(cd "$download_dir" && shasum -a 256 -c ios-native-pods.zip.sha256)

python3 .github/scripts/verify_ios_native_release.py \
  "$download_dir/ios-native-pods.zip" "$download_dir/release-manifest.json" \
  "$identity" "$KSPLAYER_REVISION" "$FFMPEGKIT_REVISION"

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

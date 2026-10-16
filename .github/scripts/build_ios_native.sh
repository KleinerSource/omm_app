#!/usr/bin/env bash
set -euo pipefail

mode="${1:-build}"
: "${KSPLAYER_REPOSITORY:?KSPLAYER_REPOSITORY is required}"
: "${FFMPEGKIT_REPOSITORY:?FFMPEGKIT_REPOSITORY is required}"
KSPLAYER_BRANCH="${KSPLAYER_BRANCH:-main}"
FFMPEGKIT_BRANCH="${FFMPEGKIT_BRANCH:-main}"

components_root="${RUNNER_TEMP}/omm-ios-components"
native_output="${GITHUB_WORKSPACE}/source/build/ios-native"
mkdir -p "$components_root"

if [[ -n "${COMPONENTS_TOKEN:-}" ]]; then
  auth="$(printf 'x-access-token:%s' "$COMPONENTS_TOKEN" | base64 | tr -d '\r\n')"
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
  native_cache_key="$(python3 "$components_root/FFmpegKit/iOSNative/build.py" cache-key \
    --components-dir "$components_root" --output "$native_output")"
  [[ "$native_cache_key" =~ ^[0-9a-f]{64}$ ]]
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'ksplayer_revision=%s\n' "$KSPLAYER_REVISION"
      printf 'ffmpegkit_revision=%s\n' "$FFMPEGKIT_REVISION"
      printf 'cache_key=%s\n' "$native_cache_key"
    } >> "$GITHUB_OUTPUT"
  else
    printf 'KSPLAYER_REVISION=%s\nFFMPEGKIT_REVISION=%s\nNATIVE_CACHE_KEY=%s\n' \
      "$KSPLAYER_REVISION" "$FFMPEGKIT_REVISION" "$native_cache_key"
  fi
  exit 0
fi

if [[ "$mode" != build ]]; then
  printf 'usage: %s [plan|build]\n' "$0" >&2
  exit 2
fi

: "${KSPLAYER_REVISION:?KSPLAYER_REVISION is required}"
: "${FFMPEGKIT_REVISION:?FFMPEGKIT_REVISION is required}"
checkout_component KSPlayer "$KSPLAYER_REPOSITORY" "$KSPLAYER_BRANCH" "$KSPLAYER_REVISION"
checkout_component FFmpegKit "$FFMPEGKIT_REPOSITORY" "$FFMPEGKIT_BRANCH" "$FFMPEGKIT_REVISION"

for formula in autoconf automake libtool pkg-config cmake meson ninja nasm texinfo; do
  brew list --formula "$formula" >/dev/null 2>&1 || brew install "$formula"
done
export PATH="$(brew --prefix texinfo)/bin:$PATH"

python3 "$components_root/FFmpegKit/iOSNative/build.py" plan \
  --components-dir "$components_root" --output "$native_output"
python3 "$components_root/FFmpegKit/iOSNative/build.py" prepare \
  --components-dir "$components_root" --output "$native_output"
python3 "$components_root/FFmpegKit/iOSNative/build.py" build --jobs 3 \
  --components-dir "$components_root" --output "$native_output"

test -f "$native_output/pods/FFmpegKit/native-versions.json"
test -f "$native_output/pods/KSPlayer/KSPlayer.podspec"
printf 'IOS_NATIVE_PODS=%s\n' "$native_output/pods" >> "$GITHUB_ENV"

#!/usr/bin/env bash
set -euo pipefail

: "${KSPLAYER_REPOSITORY:?KSPLAYER_REPOSITORY is required}"
: "${KSPLAYER_COMMIT:?KSPLAYER_COMMIT is required}"
: "${FFMPEG_REPOSITORY:?FFMPEG_REPOSITORY is required}"
: "${FFMPEG_COMMIT:?FFMPEG_COMMIT is required}"
: "${FFMPEGKIT_REPOSITORY:?FFMPEGKIT_REPOSITORY is required}"
: "${FFMPEGKIT_COMMIT:?FFMPEGKIT_COMMIT is required}"

components_root="${RUNNER_TEMP}/omm-ios-components"
native_output="${GITHUB_WORKSPACE}/source/build/ios-native"
rm -rf "$components_root"
mkdir -p "$components_root"

git_args=()
if [[ -n "${COMPONENTS_TOKEN:-}" ]]; then
  auth="$(printf 'x-access-token:%s' "$COMPONENTS_TOKEN" | base64 | tr -d '\r\n')"
  git_args=(-c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth")
fi

checkout_component() {
  local name="$1" repository="$2" commit="$3"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
  git "${git_args[@]}" clone --filter=blob:none --no-checkout --quiet "$repository" "$components_root/$name"
  git "${git_args[@]}" -C "$components_root/$name" fetch --quiet origin "$commit"
  git -C "$components_root/$name" checkout --quiet --detach "$commit"
  [[ "$(git -C "$components_root/$name" rev-parse HEAD)" == "$commit" ]]
}

checkout_component KSPlayer "$KSPLAYER_REPOSITORY" "$KSPLAYER_COMMIT"
checkout_component FFmpeg "$FFMPEG_REPOSITORY" "$FFMPEG_COMMIT"
checkout_component FFmpegKit "$FFMPEGKIT_REPOSITORY" "$FFMPEGKIT_COMMIT"

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

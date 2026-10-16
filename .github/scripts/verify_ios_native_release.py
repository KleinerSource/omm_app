#!/usr/bin/env python3
"""Verify a downloaded iOS component Release against resolved source revisions."""

import json
import plistlib
from pathlib import Path
import sys
import zipfile


FRAMEWORKS = {
    "KSPlayer": "pods/KSPlayer/Frameworks/KSPlayer.xcframework/Info.plist",
    "DisplayCriteria": "pods/KSPlayer/Frameworks/DisplayCriteria.xcframework/Info.plist",
    "FFmpegKit": "pods/FFmpegKit/Frameworks/FFmpegKit.xcframework/Info.plist",
    "Libass": "pods/FFmpegKit/Frameworks/libass.xcframework/Info.plist",
    "libfreetype": "pods/FFmpegKit/Frameworks/libfreetype.xcframework/Info.plist",
    "libfribidi": "pods/FFmpegKit/Frameworks/libfribidi.xcframework/Info.plist",
    "libharfbuzz": "pods/FFmpegKit/Frameworks/libharfbuzz.xcframework/Info.plist",
}
for name in (
    "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil",
    "Libswresample", "Libswscale", "libdav1d", "libsrt", "gmp", "nettle",
    "hogweed", "gnutls",
):
    FRAMEWORKS[name] = f"pods/FFmpegKit/Frameworks/{name}.xcframework/Info.plist"


def verify(archive_path, manifest_path, identity, ksplayer_revision, ffmpegkit_revision):
    with zipfile.ZipFile(archive_path) as archive:
        manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
        embedded_manifest = json.loads(archive.read("release-manifest.json"))
        if embedded_manifest != manifest:
            raise ValueError("Release 外部清单与归档内清单不一致")
        if manifest.get("tag") != identity.get("tag"):
            raise ValueError("Release 标签与当前源码指纹不匹配")
        fingerprint = manifest.get("fingerprint", {})
        for key in ("ffmpegkit_revision", "ksplayer_revision", "native_cache_key"):
            if fingerprint.get(key) != identity.get(key):
                raise ValueError(f"Release 指纹字段不匹配: {key}")
        if fingerprint.get("ksplayer_revision") != ksplayer_revision:
            raise ValueError("Release 中的 KSPlayer 提交与当前 main 不匹配")
        if fingerprint.get("ffmpegkit_revision") != ffmpegkit_revision:
            raise ValueError("Release 中的 FFmpegKit 提交与当前 main 不匹配")
        if manifest.get("ffmpeg_version") != "n8.1":
            raise ValueError("Release FFmpeg 版本不是 n8.1")
        if manifest.get("libav_versions", {}).get("libavcodec") != "62.28.100":
            raise ValueError("Release libavcodec ABI 版本不匹配")
        versions = json.loads(archive.read("pods/FFmpegKit/native-versions.json"))
        if versions.get("components") != manifest.get("sources"):
            raise ValueError("Release 清单的组件提交与 Pod 元数据不一致")

        for name, path in FRAMEWORKS.items():
            try:
                info = plistlib.loads(archive.read(path))
            except KeyError as error:
                raise ValueError(f"Release 缺少 XCFramework 元数据: {name}") from error
            libraries = info.get("AvailableLibraries", [])
            has_device = any(
                row.get("SupportedPlatform") == "ios"
                and "arm64" in row.get("SupportedArchitectures", [])
                for row in libraries
            )
            has_simulator = any(
                row.get("SupportedPlatform") == "ios"
                and row.get("SupportedPlatformVariant") == "simulator"
                and {"arm64", "x86_64"}.issubset(set(row.get("SupportedArchitectures", [])))
                for row in libraries
            )
            if not has_device:
                raise ValueError(f"{name} 缺少真机 arm64 slice")
            if not has_simulator:
                raise ValueError(f"{name} 缺少模拟器 arm64/x86_64 slice")


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: verify_ios_native_release.py ZIP MANIFEST IDENTITY_JSON KSPLAYER_SHA FFMPEGKIT_SHA")
    verify(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4], sys.argv[5])


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, json.JSONDecodeError, zipfile.BadZipFile, ValueError) as error:
        raise SystemExit(str(error)) from error

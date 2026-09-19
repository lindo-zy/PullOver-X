#!/usr/bin/env bash
#
# PullOver X roothide 版打包脚本(参考 TypeX 的 build-roothide-ios.sh)。
#
# 走 Theos(方案 roothide)构建,依次产出 iOS 16 / iOS 17 两个 deb:
#   ios16 -> iPhoneOS16.5.sdk + deployment target 16.0
#   ios17 -> iPhoneOS16.5.sdk + deployment target 15.0(与 TypeX 相同,
#            用 iOS 16 SDK 构建以保持 15+ ABI 兼容)
#
# 包标识与版本读自 PullOverX/Package/DEBIAN/control;两次构建都成功后把
# 版本号自增写回(PATCH 0-10,满 10 向 MINOR 进位)。
#
# Usage:
#   ./build_roothide.sh          # ios16 + ios17
#   THEOS=/path/to/theos ./build_roothide.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL="$ROOT_DIR/PullOverX/Package/DEBIAN/control"

if [[ -z "${THEOS:-}" || ! -d "${THEOS:-}" ]]; then
    THEOS="/Users/xiao/dev/theos-roothide"
fi
export THEOS

MAKE_BIN="$(command -v gmake || command -v make || true)"
if [[ -z "$MAKE_BIN" ]]; then
    echo "error: make or gmake is required" >&2
    exit 1
fi

if [[ ! -d "$THEOS" ]]; then
    echo "error: Theos not found at $THEOS" >&2
    echo "Set THEOS to your local Theos directory before running this script." >&2
    exit 1
fi

PACKAGE_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$CONTROL")"
PACKAGE_VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$CONTROL")"
if [[ -z "$PACKAGE_ID" || -z "$PACKAGE_VERSION" ]]; then
    echo "error: Package or Version is missing from $CONTROL" >&2
    exit 1
fi

# 兼容 MAJOR.MINOR 与 MAJOR.MINOR.PATCH,发布统一使用三段式。
if [[ ! "$PACKAGE_VERSION" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    echo "error: Version must use MAJOR.MINOR[.PATCH] format: $PACKAGE_VERSION" >&2
    exit 1
fi

# PATCH counts 0-10; past 10 it carries into MINOR (1.6.10 -> 1.7.0), MINOR likewise into MAJOR.
CUR_MAJOR="${BASH_REMATCH[1]}"
CUR_MINOR="${BASH_REMATCH[2]}"
CUR_PATCH="${BASH_REMATCH[4]:-0}"
CUR_VERSION="${CUR_MAJOR}.${CUR_MINOR}.${CUR_PATCH}"

NEXT_MAJOR="$CUR_MAJOR"
NEXT_MINOR="$CUR_MINOR"
NEXT_PATCH="$((10#$CUR_PATCH + 1))"
if (( NEXT_PATCH > 10 )); then
    NEXT_PATCH=0
    NEXT_MINOR="$((10#$CUR_MINOR + 1))"
fi
if (( NEXT_MINOR > 10 )); then
    NEXT_MINOR=0
    NEXT_MAJOR="$((10#$CUR_MAJOR + 1))"
fi
NEXT_VERSION="${NEXT_MAJOR}.${NEXT_MINOR}.${NEXT_PATCH}"

build_one() {
    local label="$1"
    local sdk_version="$2"
    local deployment_version="$3"
    local sdk_path="$THEOS/sdks/iPhoneOS${sdk_version}.sdk"
    local output_dir="$ROOT_DIR/packages/$label"
    local output_path="$output_dir/${PACKAGE_ID}_${NEXT_VERSION}_${label}_iphoneos-arm64e.deb"

    if [[ ! -d "$sdk_path" ]]; then
        echo "error: required SDK not found: $sdk_path" >&2
        exit 1
    fi

    echo "==> Building $label with iPhoneOS${sdk_version}.sdk (deployment ${deployment_version})"

    # Keep the package root clean so the result can be identified unambiguously.
    find "$ROOT_DIR/packages" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    "$MAKE_BIN" -C "$ROOT_DIR" clean >/dev/null

    (
        cd "$ROOT_DIR"
        THEOS_PACKAGE_SCHEME=roothide \
            TARGET="iphone:clang:${sdk_version}:${deployment_version}" \
            "$MAKE_BIN" package FINALPACKAGE=1 PACKAGE_VERSION="$NEXT_VERSION"
    )

    mkdir -p "$output_dir"
    find "$output_dir" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true

    local package_path
    package_path="$(find "$ROOT_DIR/packages" -maxdepth 1 -type f -name "${PACKAGE_ID}_${NEXT_VERSION}_*.deb" -print -quit)"
    if [[ -z "$package_path" ]]; then
        echo "error: package was not produced for $label" >&2
        exit 1
    fi

    mv "$package_path" "$output_path"
    echo "==> Output: $output_path"
}

build_one ios16 16.5 16.0
# Keep the iOS 17 build compatible with the reference package:
# build against the iOS 16 SDK while retaining iOS 15+ ABI support.
build_one ios17 16.5 15.0

# Persist the version only after both platform builds have completed.
CONTROL_TMP="$(mktemp "$ROOT_DIR/control.tmp.XXXXXX")"
trap 'rm -f "$CONTROL_TMP"' EXIT

awk -v next_version="$NEXT_VERSION" '
    BEGIN { updated = 0 }
    /^Version:/ {
        print "Version: " next_version
        updated = 1
        next
    }
    { print }
    END {
        if (!updated) exit 1
    }
' "$CONTROL" > "$CONTROL_TMP"
mv "$CONTROL_TMP" "$CONTROL"
trap - EXIT

echo "==> Build completed successfully: $CUR_VERSION -> $NEXT_VERSION"

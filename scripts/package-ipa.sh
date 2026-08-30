#!/usr/bin/env bash
# ============================================================================
# VTFramePro unsigned IPA 打包脚本（Mac + Xcode 26，无需证书/Team ID/Secrets）
# 用法: bash scripts/package-ipa.sh [--configuration Release|Debug]
# 产物: build/ipa/VTFramePro-unsigned-<配置>.ipa
# ============================================================================
set -euo pipefail

CONFIGURATION="Release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash scripts/package-ipa.sh [--configuration Release|Debug]"
      echo "产物: build/ipa/VTFramePro-unsigned-<配置>.ipa"
      exit 0 ;;
    *) echo "::error::未知参数: $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
IPA_DIR="$ROOT/build/ipa"
APP_PATH="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/VTFramePro.app"

echo "[i] 无签名构建: configuration=$CONFIGURATION"
xcodebuild -project "$ROOT/VTFramePro.xcodeproj" \
  -scheme VTFramePro \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::未找到构建产物: $APP_PATH" >&2
  exit 1
fi

rm -rf "$IPA_DIR"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/VTFramePro.app"
cd "$IPA_DIR"
zip -qry "VTFramePro-unsigned-${CONFIGURATION}.ipa" Payload
rm -rf Payload

echo "=========================================="
echo "[ok] unsigned IPA 已生成："
ls -lh "$IPA_DIR"/*.ipa
echo "=========================================="

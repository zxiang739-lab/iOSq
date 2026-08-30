#!/usr/bin/env bash
# ============================================================================
# VTFramePro CI 打包脚本（在 GitHub Actions macos runner 上运行）
# 用法: bash scripts/package-ipa.sh --team <TEAM> [--method development|ad-hoc|app-store] [--configuration Release|Debug]
# 依赖环境变量（由 workflow 传入）:
#   P12_PATH / P12_PASSWORD / MOBILEPROVISION_PATH / KEYCHAIN_PASSWORD
# ============================================================================
set -euo pipefail

TEAM=""
METHOD="development"
CONFIGURATION="Release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)          TEAM="$2"; shift 2 ;;
    --method)        METHOD="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    *) echo "::error::未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TEAM" ]]; then
  echo "::error::缺少 --team 参数（Development Team ID）" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_PATH="${RUNNER_TEMP:-$ROOT/build}/VTFramePro.xcarchive"
IPA_DIR="$ROOT/build/ipa"
KEYCHAIN_NAME="vtframepro.keychain"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-vtframepro}"

# ---------- 签名材料准备（存在才导入，未提供则跳过正文签名走 CODE_SIGN_STYLE? 不——出口必须签名）----------
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
if [[ -n "${MOBILEPROVISION_PATH:-}" && -f "$MOBILEPROVISION_PATH" ]]; then
  cp "$MOBILEPROVISION_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/"
  echo "[ok] 已安装 provisioning profile"
else
  echo "::warning::未提供 MOBILEPROVISION_PATH，将依赖 -allowProvisioningUpdates 自动管理描述文件"
fi

if [[ -n "${P12_PATH:-}" && -f "$P12_PATH" ]]; then
  if [[ -z "${P12_PASSWORD:-}" ]]; then
    echo "::error::提供了证书但缺少 P12_PASSWORD" >&2
    exit 1
  fi
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" 2>/dev/null || true
  security default-keychain -s "$KEYCHAIN_NAME"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
  security import "$P12_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_NAME"     || { echo "::error::证书导入失败（请检查 P12_PASSWORD 与证书有效性）" >&2; exit 1; }
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
  echo "[ok] 证书已导入自定义 keychain: $KEYCHAIN_NAME"
else
  echo "::warning::未提供 P12_PATH，将尝试使用 runner 上已有的签名身份（DEV 签名）"
fi

# ---------- Archive ----------
echo "[i] Archive: configuration=$CONFIGURATION method=$METHOD"
xcodebuild -project "$ROOT/VTFramePro.xcodeproj" \
  -scheme VTFramePro \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

# ---------- Export options ----------
case "$METHOD" in
  app-store) export_method="app-store" ;;
  ad-hoc)    export_method="ad-hoc" ;;
  *)         export_method="development" ;;
esac

EXPORT_PLIST="$RUNNER_TEMP/exportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${export_method}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

# ---------- Export IPA ----------
mkdir -p "$IPA_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

echo "=========================================="
echo "[ok] IPA 已生成："
ls -lh "$IPA_DIR"/*.ipa
echo "=========================================="

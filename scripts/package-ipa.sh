#!/usr/bin/env bash
# package-ipa.sh — 一键归档、签名并导出 VTFramePro.ipa
#
# 在已登录 Xcode Apple ID 的 Mac 上直接运行即可。默认 Automatic 签名 + development 导出
# （免费证书也能打真机调试包）。付费账号可改 ad-hoc / app-store。
#
# 用法:
#   bash scripts/package-ipa.sh --team YOUR_TEAM_ID
#   bash scripts/package-ipa.sh --team YOUR_TEAM_ID --method ad-hoc
#   bash scripts/package-ipa.sh --team YOUR_TEAM_ID --method app-store
#
# 手动签名（CI / 指定 p12 + 描述文件）:
#   bash scripts/package-ipa.sh \
#     --team YOUR_TEAM_ID \
#     --method ad-hoc \
#     --p12 cert.p12 --p12-password '***' \
#     --provision profile.mobileprovision
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="VTFramePro.xcodeproj"
SCHEME="VTFramePro"
BUNDLE_ID="com.vtframepro.app"
PRODUCT_NAME="VTFramePro"
CONFIGURATION="Release"
METHOD="development"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-}"
P12_PATH="${P12_PATH:-}"
P12_PASSWORD="${P12_PASSWORD:-}"
PROVISION_PATH="${MOBILEPROVISION_PATH:-}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-ipa-build-$(date +%s)}"
BUILD_DIR="${ROOT}/build"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/ipa"
EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
TEMP_KEYCHAIN=""
IMPORTED_PROFILE=""

usage() {
  cat <<'EOF'
一键签名打包 VTFramePro.ipa

必填:
  --team TEAM_ID          Apple Team ID（10 位，Xcode → Signing & Capabilities）

可选:
  --method METHOD         development | ad-hoc | app-store   (默认 development)
  --configuration CONFIG  Release | Debug                    (默认 Release)
  --identity NAME         手动签名证书名，如 "Apple Distribution: …"
  --profile NAME          手动签名描述文件名（Specifier）
  --p12 PATH              .p12 证书（导入临时钥匙串，适合 CI）
  --p12-password PASS     .p12 密码
  --provision PATH        .mobileprovision 描述文件
  -h, --help              显示帮助

环境变量等价项:
  DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY / PROVISIONING_PROFILE_SPECIFIER
  P12_PATH / P12_PASSWORD / MOBILEPROVISION_PATH / KEYCHAIN_PASSWORD

产物:
  build/ipa/VTFramePro.ipa

GitHub Actions Secrets（触发 Package IPA workflow）:
  DEVELOPMENT_TEAM
  BUILD_CERTIFICATE_BASE64     p12 的 base64
  P12_PASSWORD
  BUILD_PROVISION_PROFILE_BASE64
  KEYCHAIN_PASSWORD            可选
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)           TEAM_ID="${2:-}"; shift 2 ;;
    --method)         METHOD="${2:-}"; shift 2 ;;
    --configuration)  CONFIGURATION="${2:-}"; shift 2 ;;
    --identity)       SIGN_IDENTITY="${2:-}"; shift 2 ;;
    --profile)        PROFILE_SPECIFIER="${2:-}"; shift 2 ;;
    --p12)            P12_PATH="${2:-}"; shift 2 ;;
    --p12-password)   P12_PASSWORD="${2:-}"; shift 2 ;;
    --provision)      PROVISION_PATH="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

case "$METHOD" in
  development|ad-hoc|app-store|app-store-connect) ;;
  *) die "--method 必须是 development / ad-hoc / app-store" ;;
esac
[[ "$METHOD" == "app-store" ]] && METHOD="app-store-connect"

[[ "$(uname -s)" == "Darwin" ]] || die "必须在 macOS + Xcode 上运行（当前是 $(uname -s)）"
command -v xcodebuild >/dev/null || die "找不到 xcodebuild，请安装 Xcode 26+"

xcodebuild -version
log "SDK: $(xcodebuild -sdk iphoneos -version 2>/dev/null | head -n1 || true)"

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' \
    | head -n1 || true)"
fi
[[ -n "$TEAM_ID" ]] || die "未检测到 Team ID。请加 --team YOUR_TEAM_ID（Xcode → Signing & Capabilities）"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "Team ID 应为 10 位字母数字，当前: $TEAM_ID"

cleanup() {
  if [[ -n "$TEMP_KEYCHAIN" && -f "$TEMP_KEYCHAIN" ]]; then
    security delete-keychain "$TEMP_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

import_p12() {
  [[ -n "$P12_PATH" ]] || return 0
  [[ -f "$P12_PATH" ]] || die "找不到 p12: $P12_PATH"
  [[ -n "$P12_PASSWORD" ]] || die "提供了 --p12 但未给 --p12-password"

  TEMP_KEYCHAIN="${BUILD_DIR}/ipa-signing.keychain-db"
  rm -f "$TEMP_KEYCHAIN"
  mkdir -p "$BUILD_DIR"

  log "导入签名证书到临时钥匙串"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"
  security import "$P12_PATH" \
    -k "$TEMP_KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/xcodebuild \
    -A
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$TEMP_KEYCHAIN" $(security list-keychains -d user | tr -d '"')

  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning "$TEMP_KEYCHAIN" \
      | sed -n 's/.*"\(.*\)".*/\1/p' | head -n1 || true)"
  fi
  [[ -n "$SIGN_IDENTITY" ]] || die "p12 已导入，但钥匙串里没有可用的 codesign 身份"
  log "签名身份: $SIGN_IDENTITY"
}

install_provision() {
  [[ -n "$PROVISION_PATH" ]] || return 0
  [[ -f "$PROVISION_PATH" ]] || die "找不到描述文件: $PROVISION_PATH"

  local dest_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$dest_dir"

  local uuid
  uuid="$(security cms -D -i "$PROVISION_PATH" 2>/dev/null \
    | plutil -extract UUID raw -o - - 2>/dev/null || true)"
  [[ -n "$uuid" ]] || die "无法读取描述文件 UUID: $PROVISION_PATH"

  IMPORTED_PROFILE="${dest_dir}/${uuid}.mobileprovision"
  cp "$PROVISION_PATH" "$IMPORTED_PROFILE"
  log "已安装描述文件 UUID=$uuid"

  if [[ -z "$PROFILE_SPECIFIER" ]]; then
    PROFILE_SPECIFIER="$(security cms -D -i "$PROVISION_PATH" 2>/dev/null \
      | plutil -extract Name raw -o - - 2>/dev/null || true)"
  fi
}

write_export_options() {
  mkdir -p "$BUILD_DIR"
  local signing_style="automatic"
  [[ -n "$SIGN_IDENTITY" || -n "$PROFILE_SPECIFIER" ]] && signing_style="manual"

  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>${METHOD}</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>${signing_style}</string>
	<key>destination</key>
	<string>export</string>
	<key>stripSwiftSymbols</key>
	<true/>
EOF
    if [[ "$signing_style" == "manual" && -n "$PROFILE_SPECIFIER" ]]; then
      cat <<EOF
	<key>signingCertificate</key>
	<string>${SIGN_IDENTITY:-Apple Distribution}</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${BUNDLE_ID}</key>
		<string>${PROFILE_SPECIFIER}</string>
	</dict>
EOF
    fi
    if [[ "$METHOD" == "app-store-connect" ]]; then
      cat <<'EOF'
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
EOF
    fi
    cat <<'EOF'
</dict>
</plist>
EOF
  } > "$EXPORT_PLIST"
  log "ExportOptions → $EXPORT_PLIST"
}

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

import_p12
install_provision
write_export_options

TEAM_ARGS=(DEVELOPMENT_TEAM="$TEAM_ID")
if [[ -n "$SIGN_IDENTITY" || -n "$PROFILE_SPECIFIER" ]]; then
  SIGN_LABEL="Manual"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual)
  [[ -n "$SIGN_IDENTITY" ]] && SIGN_ARGS+=("CODE_SIGN_IDENTITY=${SIGN_IDENTITY}")
  [[ -n "$PROFILE_SPECIFIER" ]] && SIGN_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=${PROFILE_SPECIFIER}")
else
  SIGN_LABEL="Automatic"
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic)
fi

log "归档 ${PRODUCT_NAME}  (${CONFIGURATION} / ${SIGN_LABEL} / team ${TEAM_ID} / method ${METHOD})"

ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA"
  -allowProvisioningUpdates
  archive
  "${TEAM_ARGS[@]}"
  "${SIGN_ARGS[@]}"
)

if [[ "$SIGN_LABEL" == "Automatic" ]]; then
  ARCHIVE_CMD+=(-allowProvisioningDeviceRegistration)
fi

"${ARCHIVE_CMD[@]}"

[[ -d "$ARCHIVE_PATH" ]] || die "归档失败，未生成 $ARCHIVE_PATH"

log "导出 IPA"
EXPORT_CMD=(
  xcodebuild
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_DIR"
  -exportOptionsPlist "$EXPORT_PLIST"
  -allowProvisioningUpdates
)
"${EXPORT_CMD[@]}"

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n1)"
[[ -n "$IPA" && -f "$IPA" ]] || die "导出完成但没有找到 .ipa"
FINAL_IPA="${EXPORT_DIR}/${PRODUCT_NAME}.ipa"
if [[ "$IPA" != "$FINAL_IPA" ]]; then
  mv "$IPA" "$FINAL_IPA"
  IPA="$FINAL_IPA"
fi

SIZE="$(du -h "$IPA" | awk '{print $1}')"
log "打包成功"
printf '\n  IPA:  %s\n  大小: %s\n  方法: %s\n  Team: %s\n\n' "$IPA" "$SIZE" "$METHOD" "$TEAM_ID"
cat <<'EOF'
安装到 iPhone:
  • Xcode → Window → Devices and Simulators → 把 IPA 拖进去
  • 或:  xcrun devicectl device install app --device <UDID> build/ipa/VTFramePro.ipa
  • 或:  Apple Configurator / Finder（开发包需该设备已登记在描述文件里）
EOF

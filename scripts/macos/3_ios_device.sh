#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法：scripts/macos/3_ios_device.sh --team TEAM_ID --bundle-id APP_ID [选项]
      scripts/macos/3_ios_device.sh --list-devices

用 Xcode 编译 WireGuard 及其 VPN 扩展，并安装到已配对的 iPhone。

  --team TEAM_ID          Apple Developer 团队 ID
  --bundle-id APP_ID      主应用的 Bundle ID
  --device ID             iPhone 的 Identifier 或 UDID。省略时选择唯一可用的 iPhone
  --configuration MODE    Debug 或 Release，默认为 Debug
  --provision             允许 Xcode 在线创建或更新 App ID、开发证书和描述文件
  --list-devices          列出 CoreDevice 识别的 iPhone
  -h, --help              显示帮助

签名需要 Network Extensions、App Groups 和主应用的 Access WiFi Information。
扩展 Bundle ID 为 APP_ID.network-extension，两个目标使用 group.APP_ID。
EOF
}

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$*"; }

team_id=''
bundle_id=''
device=''
configuration=Debug
list_devices=false
provision=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team|--bundle-id|--device|--configuration)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 需要一个值。"
      case "$1" in
        --team) team_id="$2" ;;
        --bundle-id) bundle_id="$2" ;;
        --device) device="$2" ;;
        --configuration) configuration="$2" ;;
      esac
      shift 2
      ;;
    --list-devices) list_devices=true; shift ;;
    --provision) provision=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项 $1。使用 --help 查看用法。" ;;
  esac
done

iphone_filter="hardwareProperties.deviceType == 'iPhone'"
if "$list_devices"; then
  exec xcrun devicectl list devices --timeout 15 --filter "$iphone_filter"
fi

[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || die '请用 --team 指定 10 位 Apple Developer Team ID。'
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die '请用 --bundle-id 指定有效的 Bundle ID。'
[[ "$configuration" == Debug || "$configuration" == Release ]] || die '--configuration 需要 Debug 或 Release。'
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v go >/dev/null || die '找不到 Go。请安装 Go 并将其加入 PATH。'
xcrun --sdk iphoneos --show-sdk-path >/dev/null || die '找不到 iOS SDK。请在 Xcode 中安装 iOS 平台组件。'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
device_tmp="$(mktemp -d "${TMPDIR:-/tmp}/wireguard-ios-device.XXXXXX")"
trap 'rm -f "$device_tmp/device.json"; rmdir "$device_tmp"' EXIT
device_json="$device_tmp/device.json"
device_field() { /usr/bin/plutil -extract "$1" raw -o - "$device_json"; }

if [[ -n "$device" ]]; then
  xcrun devicectl device info details --device "$device" --timeout 15 --json-output "$device_json" --quiet \
    || die '无法查询指定设备。请用 --list-devices 检查连接和 Identifier。'
  device_key=result
else
  xcrun devicectl list devices --timeout 15 --json-output "$device_json" --quiet \
    --filter "$iphone_filter AND connectionProperties.tunnelState IN {'connected', 'available'}" \
    || die '无法列出 iPhone。请在 Xcode 的设备窗口检查连接。'
  device_count="$(device_field result.devices)"
  case "$device_count" in
    0) die '没有可用的 iPhone。请解锁手机、连接 Mac，并在手机上信任此电脑。' ;;
    1) device_key=result.devices.0 ;;
    *) die '发现多台 iPhone。请用 --list-devices 查看 Identifier，再用 --device 选择。' ;;
  esac
fi

[[ "$(device_field "$device_key.hardwareProperties.deviceType")" == iPhone ]] || die '目标设备必须是 iPhone。'
device_udid="$(device_field "$device_key.hardwareProperties.udid")"
device_identifier="$(device_field "$device_key.identifier")"
device_name="$(device_field "$device_key.deviceProperties.name")"
developer_mode="$(device_field "$device_key.deviceProperties.developerModeStatus" 2>/dev/null || true)"
[[ "$developer_mode" != disabled ]] || die '请在 iPhone 的「设置 → 隐私与安全性 → 开发者模式」开启开发者模式。'

derived_data="$repo_root/build/ios-device/$bundle_id"
xcode_args=(
  -project WireGuard.xcodeproj -scheme WireGuardiOS -configuration "$configuration"
  -destination "platform=iOS,id=$device_udid" -destination-timeout 30
  -derivedDataPath "$derived_data"
  "DEVELOPMENT_TEAM=$team_id" "APP_ID_IOS=$bundle_id"
  'CODE_SIGN_STYLE=Automatic' 'CODE_SIGN_IDENTITY=Apple Development'
)
if "$provision"; then
  xcode_args+=(-allowProvisioningUpdates)
fi

log_info "正在为 $device_name 编译 WireGuard 和 VPN 扩展。"
xcodebuild "${xcode_args[@]}" build \
  || die 'Xcode 编译失败。请检查上方错误和开发签名配置。'

app="$derived_data/Build/Products/$configuration-iphoneos/WireGuard.app"
[[ -d "$app/PlugIns/WireGuardNetworkExtension.appex" ]] || die "应用产物缺少 VPN 扩展 $app。"
/usr/bin/codesign --verify --deep --strict "$app" || die '应用签名验证失败。'

log_info "正在安装到 $device_name。"
xcrun devicectl device install app --device "$device_identifier" --timeout 60 "$app" \
  || die '安装失败。请检查上方错误、设备连接及描述文件的设备列表。'
log_info "安装完成。请在 iPhone 上打开 WG 连接（WG Connect）。"

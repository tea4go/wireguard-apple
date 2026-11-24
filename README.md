# [WireGuard](https://www.wireguard.com/) for iOS and macOS

This project contains an application for iOS and for macOS, as well as many components shared between the two of them. You may toggle between the two platforms by selecting the target from within Xcode.

The iOS target builds **WG Connect** (WG 连接), which shares its configuration backup and node sync formats with WG Connect for HarmonyOS.

## Building

- Clone this repo:

```
$ git clone https://git.zx2c4.com/wireguard-apple
$ cd wireguard-apple
```

- Rename and populate developer team ID file:

```
$ cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig
$ vim Sources/WireGuardApp/Config/Developer.xcconfig
```

- Install swiftlint and go 1.19:

```
$ brew install swiftlint go
```

- Open project in Xcode:

```
$ open WireGuard.xcodeproj
```

- Flip switches, press buttons, and make whirling noises until Xcode builds it.

## Installing on an iPhone

Connect and unlock the iPhone, trust the Mac, and enable **Developer Mode** under **Settings → Privacy & Security**. Install the iOS platform in Xcode and sign in under **Xcode → Settings → Accounts** with a team that supports Network Extensions.

From the repository root, replace the example Team ID and Bundle ID with your own:

```sh
./scripts/macos/3_ios_device.sh --team ABCDE12345 --bundle-id com.example.wireguard
```

The script builds and installs a development-signed app. The team needs development profiles for the app and `com.example.wireguard.network-extension`. Both App IDs need **Network Extensions** and the shared App Group `group.com.example.wireguard`. The app also needs **Access WiFi Information**. If the team permits Xcode to create or update signing assets, add `--provision`. The iPhone must be registered with the team.

If more than one iPhone is available, run `./scripts/macos/3_ios_device.sh --list-devices` and pass the chosen Identifier with `--device`.

## Configuration sync on iOS

Open **Settings** in WG Connect and choose **Gitee Backup**, **GitHub Gist Backup**, or **Gitee Node Sync**. Enter a token with gist permissions and reuse the gist ID from HarmonyOS to exchange configurations. Leave the ID empty when creating a new gist. The app stores credentials in the iOS Keychain.

- Backup versions use HarmonyOS's version 1 snapshot format. Restoring a version adds missing tunnels and updates matching names after confirmation. iOS cannot restore HarmonyOS per-app VPN rules. HarmonyOS diagnostic settings are skipped during import.
- Node sync compares a local tunnel with a Gitee node file. Review each difference and choose whether to send a local node, use the remote node, or use a remote identity as the local interface.
- Backups can contain private keys. GitHub secret gists are accessible to anyone who has their URL. Deleting a backup file from the current gist does not remove it from the gist's revision history.

## WireGuardKit integration

1. Open your Xcode project and add the Swift package with the following URL:
   
   ```
   https://git.zx2c4.com/wireguard-apple
   ```
   
2. `WireGuardKit` links against `wireguard-go-bridge` library, but it cannot build it automatically
   due to Swift package manager limitations. So it needs a little help from a developer. 
   Please follow the instructions below to create a build target(s) for `wireguard-go-bridge`.
   
   - In Xcode, click File -> New -> Target. Switch to "Other" tab and choose "External Build 
     System".
   - Type in `WireGuardGoBridge<PLATFORM>` under the "Product name", replacing the `<PLATFORM>` 
     placeholder with the name of the platform. For example, when targeting macOS use `macOS`, or 
     when targeting iOS use `iOS`.
     Make sure the build tool is set to: `/usr/bin/make` (default).
   - In the appeared "Info" tab of a newly created target, type in the "Directory" path under 
     the "External Build Tool Configuration":
     
     ```
     ${BUILD_DIR%Build/*}SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo
     ```
     
   - Switch to "Build Settings" and find `SDKROOT`.
     Type in `macosx` if you target macOS, or type in `iphoneos` if you target iOS.
   
3. Go to Xcode project settings and locate your network extension target and switch to 
   "Build Phases" tab.
   
   - Locate "Dependencies" section and hit "+" to add `WireGuardGoBridge<PLATFORM>` replacing 
     the `<PLATFORM>` placeholder with the name of platform matching the network extension 
     deployment target (i.e macOS or iOS).
     
   - Locate the "Link with binary libraries" section and hit "+" to add `WireGuardKit`.
   
4. In Xcode project settings, locate your main bundle app and switch to "Build Phases" tab. 
   Locate the "Link with binary libraries" section and hit "+" to add `WireGuardKit`.
   
5. iOS only: Locate Bitcode settings under your application target, Build settings -> Enable Bitcode, 
   change the corresponding value to "No".
   
Note that if you ship your app for both iOS and macOS, make sure to repeat the steps 2-4 twice, 
once per platform.

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

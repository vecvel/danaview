<!-- OWNER: INT-104 -->
# Signing the Share Extension (Danaview 1.2.0)

From 1.2.0 the iOS app embeds a Share Extension (ARCH v1.2 §8 "Platform declarations"). The IPA now
signs two bundles, and both use the same App Group.

| Target | Bundle id | Entitlements | Embedded at |
|---|---|---|---|
| `Runner` | `com.vecvel.danaview` | `ios/Runner/Runner.entitlements` (App Group), or `RunnerBackgroundGpu.entitlements` when `DANAVIEW_BG_GPU_ENTITLEMENT=YES` | – |
| `DanaviewShare` | `com.vecvel.danaview.share` | `ios/DanaviewShare/DanaviewShare.entitlements` (App Group) | `Runner.app/PlugIns/DanaviewShare.appex` |

App Group: `group.com.vecvel.danaview`. Team `63LNPXAB49`, automatic signing on both targets,
deployment target 15.0. The extension's version strings come from the pubspec through
`Flutter/Generated.xcconfig` (its base configuration), so they always match the app's.

## One-time portal setup (owner, before the first 1.2.0 signed build)

1. Certificates, Identifiers & Profiles › Identifiers › App Groups: register `group.com.vecvel.danaview`.
2. Identifiers › `com.vecvel.danaview`: enable **App Groups** and tick the group. Regenerate its
   App Store and development profiles (automatic signing does this when Xcode signs in with the
   team account).
3. Identifiers › register `com.vecvel.danaview.share` (App ID, explicit), enable **App Groups**
   and tick the same group.
4. App Store Connect needs no separate record for the extension; it ships inside the app.

With automatic signing and an Xcode account for the team, steps 1–3 can also be done by opening
`ios/Runner.xcworkspace` once, selecting each target › Signing & Capabilities and letting Xcode
register the identifiers. Command-line builds (`flutter build ipa`, the `build`/`beta`/`release`
lanes) then pick up both profiles: `ios/ExportOptions.plist` is `signingStyle = automatic`, which
covers every embedded bundle, so it needs no `provisioningProfiles` map. If signing ever moves to
manual or `match`, add a profile for `com.vecvel.danaview.share` next to the app's and list both
under `provisioningProfiles` in `ExportOptions.plist`.

## Checks after a signed build

```sh
codesign -d --entitlements - build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
codesign -d --entitlements - build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/PlugIns/DanaviewShare.appex
```

Both must list `com.apple.security.application-groups` = `group.com.vecvel.danaview`. The
extension must contain its own `PrivacyInfo.xcprivacy` (FileTimestamp C617.1, DiskSpace E174.1).

## Background GPU entitlement (unchanged from 1.1)

`DANAVIEW_BG_GPU_ENTITLEMENT` stays `NO` until Apple grants
`com.apple.developer.background-tasks.continued-processing.gpu`. With `YES` the Runner signs with
`RunnerBackgroundGpu.entitlements`, which carries the same App Group; keep the two files' groups equal.

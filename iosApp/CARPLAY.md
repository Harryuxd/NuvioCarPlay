# Nuvio on CarPlay (experimental)

Nuvio can show its full native interface — browse, search, details and the MPV
player — on a CarPlay display. The approach is adapted from
[YouDash](https://github.com/sa4hnd/YouDash) (GPL-3.0): rather than building a
separate CarPlay template app, the one already-running Nuvio root controller is
moved onto the car display and returned to the phone afterwards.

> For use while parked. Follow local laws and your vehicle's restrictions.

## Requirements

- A provisioning profile that grants `com.apple.developer.carplay-video`.
  Adding the key to a file does not grant it; signing fails without it.
- An iOS version and head unit that hand the app a drawable CarPlay window
  (YouDash reports iOS 26.4+; not all versions or cars have been verified).

## Building with CarPlay enabled

The entitlement is opt-in so ordinary/sideload builds are unaffected:

```bash
xcodebuild -project iosApp/iosApp.xcodeproj -scheme iosApp \
  NUVIO_CARPLAY_ENTITLEMENTS=Configuration/NuvioCarPlay.entitlements \
  TEAM_ID=<your team suffix> build
```

Or set `NUVIO_CARPLAY_ENTITLEMENTS` in `iosApp/Configuration/Config.xcconfig`.
It is applied to the `.app` only, not the widget extension.

## How it works

Source: `iosApp/iosApp/CarPlay/`.

1. **Scenes.** `Info.plist` declares a `CPTemplateApplicationScene`
   (`NuvioCarPlayTemplateDelegate`) plus CarPlay / external-display window scene
   roles (`NuvioCarPlayWindowDelegate`). The phone scene stays SwiftUI's own.
2. **Single surface.** `NuvioCarPlaySurface` installs a host controller in
   whichever car window arrives (CPWindow or window scene), then moves the phone
   window's root controller into it and leaves a placeholder on the phone with a
   "Use on iPhone" button. On disconnect the exact root goes back, keeping
   navigation and playback state. Only one copy of the UI ever exists.
3. **Cold launch from the car.** If iOS never creates the phone scene, a
   standalone root is created for the car after ~3 s. If the phone scene appears
   later, it is parked behind the placeholder and restored on disconnect.
4. **Scaling.** Content is laid out on a logical canvas of at least 1024×600 pt
   and uniformly scaled to fit small displays, inside the CarPlay safe area.
   The host reports an iPad idiom / regular size classes so Nuvio uses its
   wide layouts instead of an unsupported `.carPlay` idiom.
5. **Keyboard.** iOS never shows the system keyboard on a car display. When a
   text input (Compose or UIKit) becomes first responder on the car window, an
   on-screen SwiftUI keyboard appears and types into it through `UIKeyInput`.
6. **Orientation.** The player's landscape lock is skipped while Nuvio is on
   CarPlay, so the phone placeholder doesn't rotate.

## Known limitations

- Untested on a real head unit in this change; behavior depends on Apple's
  CarPlay video support for the iOS version and car.
- English/symbols keyboard only.
- `UIApplicationSupportsMultipleScenes` is now `true` (needed for car scenes);
  on iPad this also permits multiple Nuvio windows.

# ¡HOYO! — native Swift port

Native iOS version of the Puerto Rico downhill pothole racer, built with
**SwiftUI + SceneKit**. Same mountain road as the web version, same hazards —
potholes, iguanas, el tapón — with analog touch controls, haptics, and a fully
synthesized soundtrack (AVAudioEngine renders the dembow beat, engine, wind, and
coquí chirps from math; there are zero audio or image assets).

The road itself is the fixed seeded course, but the **hazard layout is reseeded
every run** — potholes, piraguas, toolboxes, iguanas and traffic are laid out
fresh each race, with density and cluster size ramping up as you descend. The end
screen shows the track id so runs can be compared.

Feature parity with the web v2 plus native-only polish:

- **HDR post-processing** — bloom on the neon (underglow, headlights, brake
  lights, nitro flames), motion blur, and vignette, straight from `SCNCamera`
- **Procedural sky cubemap** — sunset gradient, sun disc + glow, and early
  stars computed per-pixel at launch; pans correctly with the camera and is
  immune to fog
- **Countdown start** (3…2…1…¡DALE! with beeps), **pause menu** (auto-pauses
  when the app is backgrounded), **records** in UserDefaults, **near-miss
  combos** up to x5, **toolbox repairs** 🧰
- Wind-streak particles that stretch through the motion blur at speed,
  camera roll into carves, light haptics on pickups / heavy on hits,
  and the screen never sleeps mid-run

## Requirements

- A **Mac with Xcode 15+** (iOS apps can't be built on Windows — this folder is
  the complete source, ready to drop in)
- iOS 16+ device or simulator (a real device is much faster for SceneKit)

## Setup — fast path (XcodeGen)

```bash
git clone https://github.com/iamvictorblue/hoyo.git
cd hoyo/HoyoSwift
brew install xcodegen     # once
xcodegen                  # generates Hoyo.xcodeproj from project.yml
open Hoyo.xcodeproj
```

Then in Xcode: pick a simulator (or your iPhone) in the toolbar and hit **⌘R**.
Landscape orientation, bundle id, and deployment target are already configured
by `project.yml`.

To run on a real iPhone: target **Hoyo → Signing & Capabilities → Team →**
your Apple ID (personal team works), then on the phone accept
**Settings → General → VPN & Device Management → trust developer**.

## Setup — manual path (no XcodeGen)

1. Xcode → **File → New → Project → iOS App**
   - Product Name: `Hoyo`
   - Interface: **SwiftUI**, Language: **Swift**
2. Delete the generated `ContentView.swift` and `HoyoApp.swift` (or just their contents).
3. Drag all files from `Sources/` into the project navigator
   (check *Copy items if needed*, add to the `Hoyo` target).
4. Project settings → target **Hoyo** → General → Deployment Info:
   - check **Landscape Left** + **Landscape Right**, uncheck Portrait.
5. Run on your iPhone (or the simulator). Tap **TOCA PA' ARRANCAR**.

## Controls

| Control | Action |
| --- | --- |
| steering pad (bottom-left) | **analog** steer — how far you slide your thumb is how hard it turns |
| tilt | optional device-roll steering; pick **INCLINAR** under CONTROL in the pause menu (has a sentido/invert toggle) |
| 🔥 | nitro (recharges slowly; piraguas 🍧 give +35) |
| 🛑 | brake — **brake + steer = drift** for style points, and it lays skid marks |
| 🎵 | music on/off |

Launching with the `-autoplay` argument starts a self-driving smoke-test run
(the native equivalent of the web build's `?autoplay`): a lane-holding
controller weaves, punches nitro and brake-drifts, so a headless run exercises
steering, drifting and skid marks.

## File map

| File | What it is |
| --- | --- |
| `HoyoApp.swift` | App entry; hosts the SceneKit view + SwiftUI HUD |
| `GameScene.swift` | The whole world: track/terrain generation, car, potholes, iguanas, traffic, physics, camera, game loop |
| `Textures.swift` | All textures drawn in code (sky, asphalt, PR flag, banners, water normals) |
| `HUDView.swift` | HUD, touch controls, intro / finish / game-over screens |
| `GameState.swift` | Observable bridge between the render loop and SwiftUI (one batched `HudSnapshot` per update) |
| `Audio.swift` | AVAudioEngine synth: engine, wind, skid, dembow loop, coquí, horn |
| `Haptics.swift` | Core Haptics patterns with a prepared-UIKit fallback |
| `Motion.swift` | CoreMotion device-roll steering for tilt mode |
| `WebGameView.swift` | *Optional*: WKWebView wrapper that ships the JS game instead (see comments inside) |

## Two ways to ship

- **Native (default)** — the files above. Fastest, feels like an app, haptics.
- **WebView wrapper** — follow the comments in `WebGameView.swift` and bundle
  `../hoyo-game.html`. Pixel-identical to the browser game, ~10 minutes total.

## Notes

- The port targets SceneKit because it ships with iOS and needs no packages.
  If you later want RealityKit or Metal, the game logic in `GameScene.swift`
  (path math + physics in `renderer(_:updateAtTime:)`) ports over directly.
- Two RNGs: `worldRng` is fixed-seed and drives the road path, terrain,
  vegetation and props (built once); `runRng` is reseeded per race and drives the
  hazard layout. Because the road is unchanged, lap times stay comparable — but
  scores are not directly comparable to the web version, whose potholes sit in
  fixed places.
- Render quality (MSAA, shadow map, motion blur, particle counts) is chosen from
  the GPU family at launch, so older devices drop the expensive passes instead of
  dropping frames.

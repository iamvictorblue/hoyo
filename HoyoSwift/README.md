# ¡HOYO! — native Swift port

Native iOS version of the Puerto Rico downhill pothole racer, built with
**SwiftUI + SceneKit**. Same course (identical seeded track generation), same
physics, same hazards — potholes, iguanas, el tapón — with touch controls,
haptics, and a fully synthesized soundtrack (AVAudioEngine renders the dembow
beat, engine, wind, and coquí chirps from math; there are zero audio or image
assets).

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

## Setup (about 2 minutes)

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
| ◀ ▶ | steer |
| 🔥 | nitro (recharges slowly; piraguas 🍧 give +35) |
| 🛑 | brake — **brake + steer = drift** for style points |
| 🎵 | music on/off |

## File map

| File | What it is |
| --- | --- |
| `HoyoApp.swift` | App entry; hosts the SceneKit view + SwiftUI HUD |
| `GameScene.swift` | The whole world: track/terrain generation, car, potholes, iguanas, traffic, physics, camera, game loop |
| `Textures.swift` | All textures drawn in code (sky, asphalt, PR flag, banners, water normals) |
| `HUDView.swift` | HUD, touch controls, intro / finish / game-over screens |
| `GameState.swift` | Observable bridge between the render loop and SwiftUI |
| `Audio.swift` | AVAudioEngine synth: engine, wind, skid, dembow loop, coquí, horn |
| `WebGameView.swift` | *Optional*: WKWebView wrapper that ships the JS game instead (see comments inside) |

## Two ways to ship

- **Native (default)** — the files above. Fastest, feels like an app, haptics.
- **WebView wrapper** — follow the comments in `WebGameView.swift` and bundle
  `../hoyo-game.html`. Pixel-identical to the browser game, ~10 minutes total.

## Notes

- The port targets SceneKit because it ships with iOS and needs no packages.
  If you later want RealityKit or Metal, the game logic in `GameScene.swift`
  (path math + physics in `renderer(_:updateAtTime:)`) ports over directly.
- The track is deterministic (same LCG seed as the JS version), so lap times
  are comparable across the web and native versions.

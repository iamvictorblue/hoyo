# ¡HOYO! — native iOS

SwiftUI + SceneKit. You fly a flying saucer down three Puerto Rican courses at
200 km/h dodging potholes, iguanas and el tapón. The title screen runs a looping
cutscene of the craft breaking out of a hangar at Area 51 — which is the excuse for a
vehicle that can hop potholes, clear traffic roofs, and shunt police cars out of the
lane.

**There are no asset files.** Every texture, mesh, sky and sound is generated at launch
or computed per pixel. See the parent [README](../README.md) for what that covers.

![Guajataca](../screenshots/guajataca.png)

## Requirements

- A **Mac with Xcode 15+** (iOS apps can't be built on Windows — this folder is the
  complete source, ready to drop in)
- iOS 16+ device or simulator. A real device is much faster for SceneKit, and it is the
  only place the haptics exist.

## Setup — fast path (XcodeGen)

```bash
git clone https://github.com/iamvictorblue/hoyo.git
cd hoyo/HoyoSwift
brew install xcodegen     # once
xcodegen                  # generates Hoyo.xcodeproj from project.yml
open Hoyo.xcodeproj
```

Then pick a simulator or your iPhone and hit **⌘R**. Landscape orientation, bundle id
and deployment target are already set by `project.yml`.

`xcodegen` needs re-running whenever a file is added to `Sources/` or `Tests/`, since
the project file is generated rather than committed as the source of truth.

To run on a real iPhone: target **Hoyo → Signing & Capabilities → Team →** your Apple
ID (a personal team is fine), then on the phone accept **Settings → General → VPN &
Device Management → trust developer**.

## Setup — manual path (no XcodeGen)

1. Xcode → **File → New → Project → iOS App** — Product Name `Hoyo`, Interface
   **SwiftUI**, Language **Swift**
2. Delete the generated `ContentView.swift` and `HoyoApp.swift`
3. Drag everything in `Sources/` into the navigator (*Copy items if needed*, add to the
   `Hoyo` target). `PostFX.metal` must land in **Compile Sources**.
4. Target → General → Deployment Info: check **Landscape Left** + **Landscape Right**,
   uncheck Portrait
5. Run. Tap **TOCA PA' ARRANCAR**.

## Courses

Three, unlocked in order by finishing the previous one. The road of each is a fixed
seeded course so lap times stay comparable; the **hazard layout is reseeded every
run**, and the end screen shows the track id so two runs can be compared.

| | Course | Road | Surface |
| --- | --- | --- | --- |
| 1 | **GUAJATACA** — *bajada por el karso* | PR-113 | four lanes through karst and a pueblo |
| 2 | **EL YUNQUE** — *vereda en el bosque* | PR-191 | single-track dirt under canopy |
| 3 | **ISLA VERDE** — *orilla y arena mojada* | PR-187 | wet sand, no guardrail |

Each carries **bronce / plata / oro** thresholds anchored on measured score ceilings,
and your best run is stored as a **ghost** you then race.

## Controls

| Control | Action |
| --- | --- |
| steering pad (bottom-left) | **analog** — how far you slide your thumb is how hard it turns |
| tilt | optional device-roll steering; **INCLINAR** under CONTROL in the pause menu, with a sentido/invert toggle |
| **SALTA** ▲ | hop — clears potholes outright, scores big over a car's roof |
| **FRENO** ■ | brake, and **brake + steer = drift** for style points and skid marks |
| **NITRO** ▶ | recharges slowly; piraguas give +35 |
| **RAYO** ⚡ | beam that seals potholes under a tar patch and knocks cars aside. Two shots, then ~4.6 s a shot |
| speaker | music on/off |

Ram a car with more than 16 m/s of closing speed and you parry it out of the lane
instead of bouncing off — worth more against a police cruiser. Below that you just
thump into it. Holding a big combo builds **heat**, and heat brings cruisers that
actively hunt you.

![El Yunque](../screenshots/yunque.png)

## Launch arguments

All five exist for testing without playing through. Set them in the scheme's **Run →
Arguments**, or pass them via `xcrun simctl launch`.

| Argument | Effect |
| --- | --- |
| `-autoplay` | self-driving smoke test: a lane-holding PD controller weaves, punches nitro and brake-drifts, so a headless run exercises steering, drifting and skid marks |
| `-stage <0-2>` | jump straight to a course, unlocking it |
| `-startAt <metres>` | drop in partway down, for looking at the pueblo or the costa without surviving the descent |
| `-endless` | start in *sin fin* mode |
| `-showpause` | pauses itself shortly after the start, so the pause screen can be inspected without a touch |
| `-inspect <prop>` | parks the camera on the first live `piragua`, `toolbox`, `traffic` or `iguana` and holds it there. Pair with `-autoplay`. Small props cannot be checked any other way — sampling a recorded run at 4 fps produced no usable close-up of either pickup. |

## File map

| File | What it is |
| --- | --- |
| `HoyoApp.swift` | App entry; hosts the SceneKit view + SwiftUI HUD, parses `-stage` / `-endless` |
| `GameScene.swift` | The world and the game loop: track and terrain generation, craft, potholes, iguanas, traffic, pursuit, camera |
| `GameState.swift` | Observable bridge between the render loop and SwiftUI (one batched `HudSnapshot` per update). Also `Stage` and `Medal`. |
| `HUDView.swift` | HUD, touch controls, intro / pause / finish / game-over screens |
| `Textures.swift` | Every texture, drawn in code — sky cubemaps, asphalt, dirt, wet sand, casita facades, banners, water normals |
| `PropMeshes.swift` | Pure prop geometry — palms, flamboyán crowns, boulders. Returns raw vertex data so it can be tested without a renderer. |
| `FlattenGuard.swift` | The one rule that makes `flattenedClone()` safe, checked before every use. See below. |
| `Physics.swift` | Pure gameplay maths — swept collision, jump chains — lifted out so it can be tested |
| `PostFX.swift` / `PostFX.metal` | Per-course colour grade as an `SCNTechnique`, plus heat shimmer |
| `GhostTrace.swift` | Encoding for the recorded ghost path. The only binary data the game persists. |
| `SaveSchema.swift` | Versioning for everything persisted, so a scoring change retires old scores instead of misreporting them |
| `Audio.swift` | AVAudioEngine synth: engine, wind, skid, dembow loop, coquí, horn, surf |
| `Haptics.swift` | Core Haptics patterns with a prepared-UIKit fallback |
| `Motion.swift` | CoreMotion device-roll steering for tilt mode |
| `WebGameView.swift` | *Optional*: WKWebView wrapper that ships the browser game instead (see comments inside) |

## Tests

```bash
# any installed simulator; `xcrun simctl list devices available` to see yours
xcodebuild test -project Hoyo.xcodeproj -scheme Hoyo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

58 tests. They are not coverage for its own sake — the rule is that **everything under
test has produced a real bug at least once**, and each test is named for the bug it
encodes rather than the function it calls. A bolt that tunnelled through cars, a hazard
that hurt you 12 m above it, boulders documented as wider than tall that came out
taller, a crown whose shading floor sat above its own lowest vertex, and every palm on
every stage silently deleted by a flattened container holding two materials.

## Notes worth knowing before changing things

- **`flattenedClone()` fails silently, and has done so three times here.** A container
  is safe to flatten *if and only if everything inside it shares one material*.
  Otherwise you get a geometry with zero elements, no error, and a scene graph that
  still looks perfectly healthy. `FlattenGuard` asserts this in debug. It also cannot be
  covered end to end by a test: `flattenedClone()` returns empty in any process without
  a live renderer, including the test host.
- **Two RNGs.** `worldRng` is fixed-seed and drives the road, terrain, vegetation and
  props, built once. `runRng` is reseeded per race and drives the hazard layout. The
  *count* of draws taken from `worldRng` is part of the contract — adding one shifts
  every later draw and moves the scenery, so prop variants come off placement counters
  and a pure hash instead.
- **`SCNTechnique` cannot take parameters.** Measured, not assumed: a params struct at
  `buffer(0)` collides with SceneKit's own `SCNSceneBuffer`, and at `buffer(2)` nothing
  arrives. So each course's grade is a separate Metal entry point with its constants
  compiled in, and the technique is swapped when the stage loads.
- **Beware hand-checking `propHash`.** The `* 43758` blows the gap between `Float` and
  `Double` wide open, so evaluating the same expression in float64 answers a different
  question. Verify in Swift, not in a scratch script.
- Render quality (MSAA, shadow map, motion blur, particle counts) is chosen from the GPU
  family at launch, so older devices drop the expensive passes instead of frames.
- Scores are not comparable to the browser version, whose potholes sit in fixed places.

## Two ways to ship

- **Native (default)** — the files above. Fastest, feels like an app, has the haptics.
- **WebView wrapper** — follow the comments in `WebGameView.swift` and bundle
  `../hoyo-game.html`. Pixel-identical to the browser game, about ten minutes.

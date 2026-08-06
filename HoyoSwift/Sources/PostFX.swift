import SceneKit

/// Full-screen colour grade. Everything the game rendered before this came out of
/// SceneKit's stock camera knobs — HDR, bloom, SSAO, motion blur — which is why all
/// three courses read as "the same renderer with different art". A grade is what
/// gives each one a look of its own.
///
/// One `SCNTechnique` per grade, swapped when the stage loads, because SceneKit
/// gives no working way to pass a value into a technique's Metal shader. That is
/// measured, not assumed: a params struct at buffer(0) reads Apple's own
/// SCNSceneBuffer, and at buffer(2) with the symbol declared in the dictionary
/// nothing arrives — both render a flat grey scene. Apple's own reference sample
/// has every attempt at per-symbol binding commented out.
///
/// The casualty is the speed-reactive radial blur, which needed a per-frame float.
/// Options if it is wanted later: quantise it into a few more baked techniques and
/// swap on threshold crossings, or drive the whole scene through a hand-rolled
/// Metal pass instead of SceneKit's. Not worth contorting this API for.
enum PostFX {

    /// Which baked grade to use.
    enum Look {
        case cordillera, yunque, playa, night

        var fragmentFunction: String {
            switch self {
            case .cordillera: return "hoyoGradeCordillera"
            case .yunque:     return "hoyoGradeYunque"
            case .playa:      return "hoyoGradePlaya"
            case .night:      return "hoyoGradeNight"
            }
        }

        static func racing(_ stage: Stage) -> Look {
            switch stage {
            case .cordillera: return .cordillera
            case .yunque:     return .yunque
            case .playa:      return .playa
            }
        }
    }

    /// Built once each and reused — constructing an SCNTechnique allocates a render
    /// pipeline, so this must never happen per frame.
    private static var cache: [String: SCNTechnique] = [:]

    /// Entry points SceneKit has already rejected. `updatePostFX` runs once per
    /// frame, so a caller that retries after a failure would allocate a render
    /// pipeline every frame forever. Negative results have to be cached too.
    ///
    /// Neither this nor `cache` is synchronised, which is safe only because
    /// `technique(for:)` has exactly one call site — `GameScene.updatePostFX`,
    /// reached solely from `renderer(_:updateAtTime:)` on SceneKit's serial render
    /// thread. A second caller from any other thread needs a lock first. (Swift 6
    /// language mode will reject these outright; the target is on 5.9 today.)
    private static var rejected: Set<String> = []

    /// Returns nil if SceneKit rejects the dictionary or the Metal function is
    /// missing.
    ///
    /// This used to promise that a failure "costs the grade and nothing else",
    /// which was true only while `SCNCamera` still carried its own saturation,
    /// contrast and vignette. Those were double-applying against this grade and
    /// have been zeroed, so the grade is now the only thing deciding the look and
    /// losing it renders a flat frame. `GameScene.updatePostFX` handles that by
    /// installing a fallback grade back onto the camera — a nil from here is no
    /// longer free, and a caller that ignores it will look broken.
    static func technique(for look: Look) -> SCNTechnique? {
        let fn = look.fragmentFunction
        if let hit = cache[fn] { return hit }
        if rejected.contains(fn) { return nil }
        let pass: [String: Any] = [
            "draw": "DRAW_QUAD",
            // required by SceneKit even though it is unused on the Metal path
            "program": "unusedOnMetal",
            "metalVertexShader": "hoyoPostVertex",
            "metalFragmentShader": fn,
            "inputs": ["colorSampler": "COLOR"],
            "outputs": ["color": "COLOR"]
        ]
        let dict: [String: Any] = [
            "passes": ["hoyoGrade": pass],
            "sequence": ["hoyoGrade"]
        ]
        guard let t = SCNTechnique(dictionary: dict) else { rejected.insert(fn); return nil }
        cache[fn] = t
        return t
    }
}

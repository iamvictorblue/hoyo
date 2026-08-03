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

    /// Returns nil if SceneKit rejects the dictionary or the Metal function is
    /// missing, so a failure costs the grade and nothing else: the caller leaves
    /// `view.technique` alone and the game renders exactly as it always did.
    static func technique(for look: Look) -> SCNTechnique? {
        let fn = look.fragmentFunction
        if let hit = cache[fn] { return hit }
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
        guard let t = SCNTechnique(dictionary: dict) else { return nil }
        cache[fn] = t
        return t
    }
}

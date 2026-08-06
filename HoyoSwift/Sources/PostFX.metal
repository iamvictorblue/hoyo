//  Post-processing for ¡HOYO! — per-stage colour grade.
//
//  Bound by PostFX.swift via SCNTechnique. `program` in that dictionary is
//  required but ignored; metalVertexShader/metalFragmentShader name these
//  functions. UV carries a flipped Y because SceneKit's quad is upside down
//  relative to texture space.
//
//  WHY THE CONSTANTS ARE LITERALS INSTEAD OF UNIFORMS
//
//  Passing values from Swift into an SCNTechnique's Metal shader does not work.
//  Tried and measured: a params struct at buffer(0) reads SceneKit's own
//  SCNSceneBuffer (Apple owns that index) and at buffer(2) with the symbol
//  declared in the technique dictionary nothing arrives at all. Both produce a
//  flat grey scene. Apple's own SCNTechnique+Metal sample has every attempt at
//  per-symbol binding commented out, which is the same finding.
//
//  So each stage gets its own entry point with its grade compiled in, and
//  PostFX.swift swaps the whole technique when the stage loads. That costs the
//  speed-reactive radial blur, which needed a per-frame float — see PostFX.swift.

#include <metal_stdlib>
using namespace metal;
// Must follow `using namespace metal` — SceneKit's own header refers to float4x4
// unqualified, so including it first fails to compile inside Apple's header.
#include <SceneKit/scn_metal>

constexpr sampler pfxSampler = sampler(coord::normalized,
                                       address::clamp_to_edge,
                                       filter::linear);

struct PFXVertexIn {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
};

struct PFXVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PFXVertexOut hoyoPostVertex(PFXVertexIn in [[stage_in]]) {
    PFXVertexOut out;
    out.position = in.position;
    // Y flipped into [0,1] rather than [0,-1]. Apple's sample writes the negative
    // form and gets away with it because its sampler wraps; this one clamps, so a
    // negative v made every pixel sample row 0 — the scene came out as a smear of
    // the top edge.
    out.uv = float2((in.position.x + 1.0) * 0.5,
                    1.0 - (in.position.y + 1.0) * 0.5);
    return out;
}

/// The grade itself. One implementation, called by the per-stage entry points
/// below with their own constants, so the maths lives in exactly one place.
///
/// `lift` opens the shadows toward the stage's cast, `gain` pulls the highlights.
/// Order matters: lift/gain, then contrast about mid grey, then saturation against
/// luma, then vignette. Grading in that order keeps the vignette from being
/// re-saturated into a coloured ring.
static inline half4 pfxGrade(float2 uv,
                             texture2d<float, access::sample> src,
                             float3 lift, float3 gain,
                             float saturation, float contrast,
                             float vignette, float grain, float t,
                             float shimmer = 0.0) {
    // Heat rising off hot tarmac. Only worth it where the air is actually hot, so
    // it is a per-stage argument rather than something every grade pays for.
    //
    // Two sines at different rates and scales, because a single one reads as a
    // regular ripple rather than convection. Masked to a band around the horizon:
    // shimmer belongs where the sightline grazes the surface over distance, and
    // applying it to the whole frame would just look like a wobbling screen.
    if (shimmer > 0.0) {
        float band = exp(-pow((uv.y - 0.52) * 7.0, 2.0));
        float w = sin(uv.y * 130.0 + t * 3.1) * 0.6
                + sin(uv.y * 61.0 - t * 1.9 + uv.x * 8.0) * 0.4;
        uv.x += w * shimmer * band;
    }
    float3 col = src.sample(pfxSampler, uv).rgb;
    float  r = length(uv - float2(0.5, 0.5));

    col = col * gain + lift * (1.0 - col);
    col = (col - 0.5) * contrast + 0.5;

    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = mix(float3(luma), col, saturation);

    // squared so it stays clear of the playable centre
    float v = smoothstep(0.25, 0.95, r);
    col *= 1.0 - vignette * v * v;

    // Animated from SceneKit's own frame time — the one value that *is* reliably
    // bound — so the grain doesn't look like a dirty lens.
    if (grain > 0.001) {
        float2 g = uv * float2(1920.0, 1080.0) + t * 91.7;
        float n = fract(sin(dot(g, float2(12.9898, 78.233))) * 43758.5453);
        col += (n - 0.5) * grain * (1.0 - luma * 0.7);
    }
    return half4(half3(saturate(col)), 1.0h);
}

// Late sunset over the karst: warm highlights, magenta in the shadows.
fragment half4 hoyoGradeCordillera(PFXVertexOut vert [[stage_in]],
                                   texture2d<float, access::sample> colorSampler [[texture(0)]],
                                   constant SCNSceneBuffer& scn_frame [[buffer(0)]]) {
    return pfxGrade(vert.uv, colorSampler,
                    float3(0.030, 0.008, 0.045), float3(1.06, 0.99, 0.94),
                    1.12, 1.06, 0.24, 0.022, scn_frame.time,
                    // the only stage with sun-baked asphalt to rise off
                    0.0016);
}

// Under canopy. Deliberately close to neutral: this stage's fog is already green
// (0.42, 0.55, 0.42), so a green gain on top of it drove the whole frame to one
// hue. Desaturating is what makes the greens read as different greens.
fragment half4 hoyoGradeYunque(PFXVertexOut vert [[stage_in]],
                               texture2d<float, access::sample> colorSampler [[texture(0)]],
                               constant SCNSceneBuffer& scn_frame [[buffer(0)]]) {
    // 0.96, not 0.86. These grades were all authored while SCNCamera was applying
    // its own saturation of 1.14 on top, so the number that was actually being
    // looked at here was 0.86 * 1.14 = 0.98 — which is what "close to neutral"
    // above describes. Removing the camera's copy as a double-apply was correct,
    // but it silently turned this stage's real saturation down to 0.86 and made the
    // comment false. Restored to roughly the composite it was tuned against.
    return pfxGrade(vert.uv, colorSampler,
                    float3(0.014, 0.024, 0.022), float3(0.99, 1.02, 1.00),
                    0.96, 1.02, 0.26, 0.026, scn_frame.time);
}

// Glare off wet sand: cool, bright, slightly bleached.
fragment half4 hoyoGradePlaya(PFXVertexOut vert [[stage_in]],
                              texture2d<float, access::sample> colorSampler [[texture(0)]],
                              constant SCNSceneBuffer& scn_frame [[buffer(0)]]) {
    // Vignette 0.26, up from 0.16. The camera used to add its own 0.45 on top of
    // every grade; that has been removed as a double-apply, which left this stage
    // — the brightest of the four, pale sand under a high sun — with the weakest
    // vignette of the four holding down its frame edges. This is the compensation,
    // not a new look.
    return pfxGrade(vert.uv, colorSampler,
                    float3(0.010, 0.020, 0.038), float3(1.02, 1.03, 1.08),
                    1.04, 0.97, 0.26, 0.014, scn_frame.time);
}

// Night over the water, used by the cutscene and the title. Contrast is *below* 1
// here on purpose: this grade pivots about mid grey, and at 1.14 a dim value of 0.1
// became 0.044 — which crushed the whole city skyline to black and left only the
// moon. On a night frame the grade has to open the shadows, not squeeze them.
fragment half4 hoyoGradeNight(PFXVertexOut vert [[stage_in]],
                              texture2d<float, access::sample> colorSampler [[texture(0)]],
                              constant SCNSceneBuffer& scn_frame [[buffer(0)]]) {
    // Vignette 0.34, up from 0.20 — same compensation as the beach. A night frame
    // leans on its vignette harder than a daylit one, since the falloff into the
    // corners is most of what keeps the eye on the craft, and this is the grade the
    // title and the Area 51 cutscene run under.
    return pfxGrade(vert.uv, colorSampler,
                    float3(0.022, 0.030, 0.058), float3(1.02, 1.04, 1.14),
                    1.10, 0.96, 0.34, 0.018, scn_frame.time);
}

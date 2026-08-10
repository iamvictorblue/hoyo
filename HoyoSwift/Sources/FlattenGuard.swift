import SceneKit

/// The one rule that makes `flattenedClone()` safe, and a way to trip over breaking
/// it immediately instead of three commits later.
///
/// This API fails silently and has now done so three separate times in this project:
/// the flamboyanes, the casitas, and — most expensively — every palm on every stage,
/// which vanished for several commits because the trunk and the fronds were given
/// different materials inside one container. The symptom is always the same and is
/// always useless: a geometry with zero elements, no error, no warning, and a scene
/// graph that still looks perfectly healthy under inspection.
///
/// The rule that actually holds, narrower than the earlier comments in `GameScene`
/// guessed: **a container is only safe to flatten if everything inside it shares a
/// single material.** Count them first.
///
/// Note this cannot be covered by a unit test end to end. `flattenedClone()` returns
/// an empty geometry in any process without a live renderer — including the test
/// host — so a test asserting "flattening yields vertices" fails even for a correct
/// single-material container. What is testable, and what `FlattenGuardTests` covers,
/// is the material count that decides it.
enum FlattenGuard {

    /// Distinct materials used anywhere under `node`, itself included.
    ///
    /// Identity comparison, not equality: SceneKit's flattening groups by material
    /// object, so two identical-looking materials still count as two.
    static func distinctMaterials(in node: SCNNode) -> Int {
        var seen: [ObjectIdentifier: Bool] = [:]
        func walk(_ n: SCNNode) {
            for m in n.geometry?.materials ?? [] { seen[ObjectIdentifier(m)] = true }
            for c in n.childNodes { walk(c) }
        }
        walk(node)
        return seen.count
    }

    /// `flattenedClone()`, with the precondition checked.
    ///
    /// The assertion is debug-only on purpose: in release the worst case is the props
    /// not drawing, which is what already happens, and tripping an assertion in a
    /// shipped game to report a cosmetic fault would be the wrong trade. In debug it
    /// fires the moment someone reintroduces the mistake.
    static func flattened(_ node: SCNNode, _ label: String) -> SCNNode {
        let n = distinctMaterials(in: node)
        assert(n <= 1, "\(label): flattening a container with \(n) materials returns an "
                     + "empty geometry and the whole group silently disappears. Split it "
                     + "into one container per material.")
        return node.flattenedClone()
    }
}

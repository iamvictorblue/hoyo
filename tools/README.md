# tools

## obj2swift.py

Converts a Wavefront OBJ into compiled Swift arrays in `PropMeshes.Mesh` form.

    python3 tools/obj2swift.py path/to/model.obj name

Written for the move to authored 3D props. It exists because the alternative —
bundling model files and loading them at runtime — breaks three things the
renderer depends on:

- **One material per flattened container.** Imported models arrive with their own
  material list, and `flattenedClone()` silently returns an empty geometry the
  moment a container holds more than one. Converting per material keeps the
  existing one-container-per-material arrangement.
- **Colour in the vertex stream.** All the scenery shares a single white material
  and carries its colour per vertex. An imported model wants textures instead,
  which would mean one material per prop and no batching at all.
- **The wind channel.** `Mesh.sway` rides texcoord 0, which is exactly where an
  imported model puts its UVs. Emitting sway during conversion sidesteps the
  collision.

So the mesh data is authored by a person and ships as generated source. No
resource pipeline, no new material per prop, and the flatten and wind invariants
hold unchanged.

Faces are fan-triangulated and vertices de-indexed, one set per material. De-indexing
is not waste: it is what gives flat shading, since `makeGeometry` averages normals
across shared vertices and a faceted prop needs them unshared.

Sway weights are emitted as `(y / height)^2` for foliage materials and 0 for the
rest, matching the falloff `PropMeshes` uses for its own fronds.

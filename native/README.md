# C++ CPU intersection worker

Windows x64, C++17, MSVC. The saved working version is `native/stable/cj_engine.exe`; its source is `native/stable/engine.cpp`, with the baseline commit and SHA256 in `native/stable/manifest.json`. EXEs are local backups and are not committed to Git. The saved version uses protocol v1.

Continue editing `native/engine.cpp`. `./native/build.ps1` builds only into `native/build/experimental/cj_engine.exe`. It never copies an EXE into stable, the plugin, or a release. The compiler/linker flags are unchanged; there are no third-party libraries. `./native/build.ps1 -SyntaxOnly` checks the source without generating or running an EXE. While the detection remains unresolved, use this syntax check and do not execute experimental workers. Do not disable antivirus or add exclusions.

Run `python native/test_engine.py` to test only the saved working EXE, after checking its pinned SHA256. Inside SketchUp, load `dev/cpp_checks.rb` and call `CJCppChecks.run` in an empty test model. This creates and removes a temporary fixture; results go to `reports/cpp_check.json`. These checks do not validate the experimental C++ source.

`python tooling/build_release.py` includes only the saved, hash-checked EXE in `cj_insolation/bin/`. Missing or changed stable EXE stops packaging before writing a release. The plugin uses only its packaged worker, or `native/stable/cj_engine.exe` during development, and verifies the pinned SHA256 before launch. It never falls back to an experimental build. Updating the saved version requires a separate deliberate change; building source is not installation.

## Protocol v1

Integers: little-endian uint32. Coordinates and distances: little-endian IEEE754 doubles in SketchUp internal inches. Usage: `cj_engine.exe input.bin output.bin` (Unicode paths supported).

Input: ASCII `CJIN0001`, triangle count, point count, direction count; triangles (nine doubles each), origins (three doubles each), shared directions (three doubles each). Directions are normalized by the worker. Invalid counts, nonfinite values, zero directions, wrong magic and truncated/trailing payloads are rejected with exit code 2 and stderr text.

Output: ASCII `CJOUT001`, point count, direction count, then one distance per ray, point-major then direction-major. `-1` means no hit. Two-sided nearest triangle intersections use a median-split BVH with at most eight triangles per leaf. Batches run on up to 16 CPU threads. Distances below 1e-7 inches are excluded to avoid self-intersections.

## Integration and limits

Ruby exports a fresh scene in the main thread. Nested transforms, visibility and real face holes are included; point handles and generated results are excluded. Visibility is checked explicitly on every ancestor, tag and tag folder. Hidden geometry is excluded even if Show Hidden options are enabled. Images are exported through their internal image definitions, including the instance transforms. Non-geometric entities are skipped.

Glued cutting components do not necessarily modify the host face mesh. These scenes and active sections with DisplaySectionCuts enabled fall back to SketchUp. Stored sections with cuts disabled do not block export. Boundary/self-contact tolerances need further real-model coverage; the current worker is a development implementation, not a claim of universal parity.

Intersection work runs in a child process that never touches SketchUp API. The plugin polls completion, supports cancellation, removes temporary files and retains the existing display/Undo flow. There is no live tracking or scene cache.

## Experimental source

The current `native/engine.cpp` retains v1 and adds `CJIN0002`: uint32 mesh/instance/point/direction counts; indexed local mesh patches; mesh index plus 16 doubles per instance; origins and shared directions. Instance transforms are applied in C++. `dev/scene_export.rb` and `dev/scene_cache.rb` preserve the export optimization work and are not loaded or shipped by the plugin. Runtime continues using its working v1 exporter, compatible with the saved EXE. Experimental runtime tests remain pending; no performance claim is made for the latest source-only corrections.

Visibility regression: load `dev/export_visibility_checks.rb` and run `CJExportVisibilityChecks.run`. It uses a temporary fixture rolled back within the current model, including nested hidden tag folders, hidden faces/instances/images and enabled/disabled section cuts.

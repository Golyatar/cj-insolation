# C++ CPU intersection worker

Windows x64, C++17, MSVC. Build using `./native/build.ps1` in PowerShell with Visual Studio C++ Build Tools installed. Visual Studio is discovered via vswhere. The output is `native/build/cj_engine.exe`, statically linking the C runtime. No SketchUp SDK, external library or GPU driver is required. The Windows subsystem avoids opening a console when launched by SketchUp.

Run `python native/test_engine.py`. Inside SketchUp, load `dev/cpp_checks.rb` and call `CJCppChecks.run` in an empty test model. This creates and removes a temporary fixture; results go to `reports/cpp_check.json`.

`python tooling/build_release.py` includes the EXE in `cj_insolation/bin/`. Rebuild the worker after editing `engine.cpp`; binaries are ignored by Git.

## Protocol v1

Integers: little-endian uint32. Coordinates and distances: little-endian IEEE754 doubles in SketchUp internal inches. Usage: `cj_engine.exe input.bin output.bin` (Unicode paths supported).

Input: ASCII `CJIN0001`, triangle count, point count, direction count; triangles (nine doubles each), origins (three doubles each), shared directions (three doubles each). Directions are normalized by the worker. Invalid counts, nonfinite values, zero directions, wrong magic and truncated/trailing payloads are rejected with exit code 2 and stderr text.

Output: ASCII `CJOUT001`, point count, direction count, then one distance per ray, point-major then direction-major. `-1` means no hit. Two-sided nearest triangle intersections use a median-split BVH with at most eight triangles per leaf. Batches run on up to 16 CPU threads. Distances below 1e-7 inches are excluded to avoid self-intersections.

## Integration and limits

Ruby exports a fresh scene in the main thread. Nested transforms, visibility and real face holes are included; point handles and generated results are excluded. SketchUp versions before 2026 cannot query visibility with an instance as the final path element, so visibility is queried on leaf geometry instead.

Glued cutting components do not necessarily modify the host face mesh. These scenes, active sections and images fall back to SketchUp. Boundary/self-contact tolerances need further real-model coverage; the current worker is a development implementation, not a claim of universal parity.

Intersection work runs in a child process that never touches SketchUp API. The plugin polls completion, supports cancellation, removes temporary files and retains the existing display/Undo flow. There is no live tracking or scene cache.

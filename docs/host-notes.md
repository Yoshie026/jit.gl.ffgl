# Host notes

`FFGL.h` does not document everything real plugins depend on. These are the behaviours this host
matches, each found the hard way.

- **`FF_SET_TIME` is in milliseconds.** The header says seconds, but Resolume passes milliseconds
  and plugins divide by 1000 (the FFGL SDK's own Particles example does). Passing seconds makes
  time-based plugins run ~1000x too slow.
- **Input texture type.** Some plugins take the input as `GL_TEXTURE_RECTANGLE` unless
  `HardwareWidth > Width`; others always sample a `sampler2D`. The default gives every plugin a
  `GL_TEXTURE_2D` allocated one texel larger than the image, with Hardware = size + 1, which
  satisfies both. `@intarget rect` hands over the IOSurface-backed rectangle texture instead, for
  plugins that assume rectangle input unconditionally (what Resolume does on macOS).
- **Private GL context.** Plugins get an OpenGL 4.1 core context (`NSOpenGLContext`, since plugins
  often ask for `[NSOpenGLContext currentContext]`). Host state is reset (`sanitizeState`) before
  every plugin call. Jitter's context is never touched.
- **Max quirk when testing:** Max reopens its previous workspace on launch, so a scripted test can
  open every earlier test patch in one process. `tools/run_max_patch.sh` clears it first.
- **Max's "Max Search Helper" listens on 127.0.0.1:8088**, which can shadow a plugin that opens
  a run of sequential local ports (its wildcard bind still succeeds, but clients reach the wrong
  process). See compatibility rules below.
- Pattern tests: don't judge results with `jit.noise` (random alpha averages to a semi-transparent
  grey after downscaling); use real video such as `bball.mov`.
- `ProcessOpenGL` returning `FF_FAIL` every frame is logged once; some marker/bridge plugins do it
  by design.

## Compatibility rules

Plugin-specific workarounds live in optional JSON files, not in the host. The host reads every
`*.json` in `$FFGL_COMPAT_DIR`, or `~/Library/Application Support/ffgl_for_max/compat/`, and
applies a rule once per process, right before the first matching plugin loads.

`plugins` is a list of bundle names (case-insensitive; a trailing `*` matches a prefix).
`port_guard` counts how many of the `lanes` ports above the base port are free on 127.0.0.1 and,
if some are taken, sets `limit_env` to the free count (unless you already set it), so a plugin
that reads it at start-up serves fewer lanes. See [compat-example.json](compat-example.json).

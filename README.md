# FFGL for Max

`jit.gl.ffgl` loads a [FFGL 2.x](https://github.com/resolume/ffgl) plugin (the GPU plugin format
used by Resolume and others) and runs it inside Max/Jitter, on the GPU.

```
[jit.world]        [jit.gl.texture]--(input 0 <name>)--+
                                                       v
                                   [jit.gl.ffgl @plugin MyPlugin]--jit_gl_texture--[jit.gl.videoplane]
```

Every plugin parameter becomes a real Max attribute (`@name value`, `attrui`, the inspector), and
`param` / `paramn` / `getparam` messages work generically. Text, file, option, boolean and event
parameters are supported. Buffer (FFT/audio) parameters are not.

- macOS 11+, Max 8 or newer (tested with Max 9.1.5 on Apple Silicon)
- OpenGL-based FFGL plugins only (`.bundle` files). Apple has deprecated OpenGL, so this is a
  macOS-only, OpenGL-era tool; there is no Windows build.

## Install

Grab a build from the releases page (once published), or build it yourself:

```sh
git clone --recursive <this repo>
cd ffgl_for_max
cmake -B build
cmake --build build
```

That produces `package/externals/jit.gl.ffgl.mxo`. Make the folder a Max package by linking (or
copying) `package/` into your Packages folder:

```sh
ln -s "$PWD/package" ~/Documents/Max\ 9/Packages/ffgl_for_max
```

Restart Max and open the help patch (`jit.gl.ffgl.maxhelp`).

Requirements: CMake 3.19+, Xcode command line tools. The build is arm64 by default; for Intel or
a universal binary use `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`. The Max SDK base (`Cycling74/max-sdk-base`) is a git submodule
(`git submodule update --init` if you cloned without `--recursive`).

## Use

1. `plugins` lists the FFGL bundles found. Bundles are searched in
   `/Library/Graphics/FreeFrame Plug-Ins`, `/Library/Application Support/FreeFrame`, the same
   folders under `~/Library`, and Resolume's `Extra Effects` folders. Add more with `searchpath <dir>`.
2. `@plugin Name` (or the message `load Name`) loads one. Parameters are dumped out the right outlet
   (`plugininfo`, `paraminfo`, `paramoption`) and again on `params`.
3. Feed inputs with `input <slot> <jit.gl.texture name>` (a plain `jit_gl_texture` into the left
   inlet is slot 0). Effects take one input, sources none, mixers two.

| Attribute | Meaning |
|---|---|
| `@plugin` | plugin name or absolute bundle path |
| `@dim w h`, `@adapt` | output size; with `@adapt 1` (default) follow the first input's size |
| `@clear` | clear the render target before each frame (default 1); set 0 if the plugin overwrites every pixel |
| `@sync` | `glFinish` around the plugin call (default 0; only for debugging) |
| `@intarget 2d\|rect` | input texture type (see [docs/host-notes.md](docs/host-notes.md)) |
| `@bpm`, `@barphase` | beat info passed to the plugin |
| `@automatic` | 1 (default): renders in the context's draw pass. 0: renders only on `bang` / `draw` |

Plugin-specific workarounds are not built in; they are optional JSON rules (see
[docs/host-notes.md](docs/host-notes.md#compatibility-rules)).

Right outlet also reports plugin-initiated changes: `paramchanged`, `paramvisible`, `paramlabel`.

## Performance

The plugin runs in its own OpenGL 4.1 core context and frames cross to Jitter as IOSurfaces, so
plugin GL state can never disturb Jitter. That costs three full-frame copies per input/output on
the GPU. Measured on Apple Silicon with a pass-through effect (`FFGL_GPUTIME=1`):

| size | copy in | plugin | copy out |
|---|---|---|---|
| 1280x720 | 0.17 ms | 0.19 ms | 0.17 ms |
| 3840x2160 | 0.31 ms | 0.43 ms | 0.29 ms |

(These include `glFinish` latency, so they overstate the real cost.) Practical advice:

- Render at the size you need: cost scales with pixels; use `@dim` and `@adapt 0`.
- Don't also bang the object from `jit.world` with `@automatic 1`. Since 0.1 that no longer renders twice.
- Use `jit.movie @output_texture 1` or HAP to avoid a per-frame CPU upload.
- Keep `@sync 0`, and `@clear 0` when the plugin overwrites the whole frame.

## Debugging

- `FFGL_TRACE=<file>` writes a per-frame trace (draw calls, timings, sampled pixels of input and output).
- `FFGL_GPUTIME=1` logs per-stage GPU time every 300 frames. It serialises the pipeline; don't leave it on.
- `build/ffgl_probe <plugin> --size 1920x1080 --frames 300 --out out.png` loads a plugin, dumps its
  parameters and renders without Max (all options are listed at the top of `tools/ffgl_probe.mm`).
- `tools/run_max_patch.sh <patch> <trace>` runs one patch in a fresh Max with tracing on. It quits
  Max and clears its restored workspace first, so don't run it with unsaved work open.

## Layout

```
source/host/         Max-independent FFGL host (ffgl_host.h/.mm): loading, params, private GL context
source/jit.gl.ffgl/  the Jitter class + Max wrapper
package/             the Max package (help patch; externals/ is build output)
tools/               ffgl_probe and run_max_patch.sh
third_party/         FFGL headers (BSD-3), max-sdk-base (submodule)
docs/host-notes.md   behaviours a host must match for real-world plugins
```

## Known issues

- Two `jit_gl_bind_texture / unbind_texture: state not bound` lines can appear in the Max console
  when the object is created. Rendering is unaffected.
- Buffer parameters (FFT / audio) are not settable from Max.
- A plugin that returns `FF_FAIL` from `ProcessOpenGL` is reported once and then left running.

## License

See [LICENSE](LICENSE). The FFGL headers in `third_party/ffgl` are under their own BSD-3 license;
the Max SDK is under Cycling '74's license.

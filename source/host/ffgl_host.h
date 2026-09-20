// ffgl_host.h — Max-independent FFGL 2.x host.
//
// Loads an FFGL bundle, enumerates its parameters (name / type / default /
// range / group / options), and renders it inside a *private* OpenGL 4.1 core
// context. Frames go in and out as IOSurfaces, so the host never touches the
// caller's GL context (Jitter's legacy context in Max) and the caller never
// sees whatever GL state the plugin leaves behind.
//
// This header deliberately includes no OpenGL header: Jitter's legacy <gl.h>
// and the core <gl3.h> that FFGL.h needs cannot live in one translation unit.

#pragma once

#include <IOSurface/IOSurfaceRef.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace ffgl_host {

enum class ParamKind {
    Boolean,  // 0 / 1
    Event,    // momentary trigger
    Float,    // any FFGL float-valued type (standard, colour channels, hue, ...)
    Integer,
    Option,   // pick one of `options`
    Text,
    File,
    Buffer,   // FFT / audio buffer — not settable from Max in this version
};

struct Option {
    std::string name;
    float value = 0.f;  // the float the plugin expects for this element
};

struct ParamInfo {
    uint32_t index = 0;
    std::string name;         // stable identifier used for messages / attributes
    std::string displayName;  // may differ from name (FFGL 2.1 display names)
    std::string group;
    uint32_t ffType = 0;      // raw FF_TYPE_*
    ParamKind kind = ParamKind::Float;
    float def = 0.f;          // default, in the plugin's native (normalized) units
    std::string defText;
    float min = 0.f;          // real-world range reported by FF_GET_RANGE
    float max = 1.f;
    std::vector<Option> options;
    bool visible = true;
};

struct PluginInfo {
    std::string path;
    std::string id;           // 4-char FFGL unique id
    std::string name;
    std::string description;
    std::string about;
    uint32_t type = 0;        // 0 effect, 1 source, 2 mixer
    uint32_t apiMajor = 0, apiMinor = 0;
    uint32_t numInputs = 0;   // textures the plugin wants per frame
    bool wantsTime = false;
};

// Plugin logs and host diagnostics go here. Default: stderr.
void setLogger(std::function<void(const std::string&)> fn);

// Directories searched for bundles when a plugin is given by bare name.
std::vector<std::string> searchPaths();
void addSearchPath(const std::string& dir);
struct FoundPlugin { std::string name; std::string path; };
std::vector<FoundPlugin> scanPlugins();
// Resolve "MyPlugin", "MyPlugin.bundle" or an absolute path to a bundle path.
// Returns "" when nothing matches.
std::string resolvePlugin(const std::string& nameOrPath);

// A loaded bundle. Shared by every Instance of the same plugin, because FFGL
// keeps per-module global state.
class Module {
public:
    static std::shared_ptr<Module> open(const std::string& nameOrPath, std::string& error);
    ~Module();

    const PluginInfo& info() const { return info_; }
    const std::vector<ParamInfo>& params() const { return params_; }
    int findParam(const std::string& name) const;  // by name or display name, case-insensitive; -1 if none

private:
    Module() = default;
    friend class Instance;
    struct Impl;
    std::unique_ptr<Impl> impl_;
    PluginInfo info_;
    std::vector<ParamInfo> params_;
};

// Which kind of texture the plugin gets as its input.
//  Texture2D  (default) a GL_TEXTURE_2D one texel larger than the image, so Hardware > Width like
//             a classic NPOT-padding host. SDK plugins (sampler2D) work, and plugins that
//             choose 2D vs rectangle from that padding take their 2D path.
//  Rectangle  the IOSurface-backed GL_TEXTURE_RECTANGLE (what Resolume hands plugins on macOS)
//             for plugins that assume rectangle input unconditionally.
enum class InputTarget { Texture2D, Rectangle };

struct ParamEvent {
    uint32_t index;
    bool valueChanged, visibilityChanged, displayNameChanged, optionsChanged;
};

class Instance {
public:
    static std::unique_ptr<Instance> create(std::shared_ptr<Module> module,
                                            uint32_t width, uint32_t height,
                                            std::string& error);
    ~Instance();

    const std::shared_ptr<Module>& module() const { return module_; }
    uint32_t width() const;
    uint32_t height() const;
    bool resize(uint32_t width, uint32_t height);  // recreates surfaces; old handles become invalid
    uint32_t numInputs() const;

    // IOSurfaces the caller fills / reads from its own GL context.
    // Bumped whenever they are recreated (resize) so callers know to re-bind.
    IOSurfaceRef inputSurface(uint32_t i) const;
    IOSurfaceRef outputSurface() const;
    uint64_t surfaceGeneration() const;

    // Parameters. Sets are queued and applied at the next render() inside the
    // plugin's GL context; reads return the last known value.
    void setFloat(uint32_t index, float value);
    void setText(uint32_t index, const std::string& value);
    void trigger(uint32_t index);
    float floatValue(uint32_t index) const;
    std::string textValue(uint32_t index) const;
    bool visible(uint32_t index) const;
    std::string displayName(uint32_t index) const;

    void setInputTarget(InputTarget t);
    InputTarget inputTarget() const;

    void setBeat(float bpm, float barPhase);

    // Runs the plugin once: inputs (already filled by the caller) -> output.
    // `clear` wipes the render target first. `events` (optional) receives
    // plugin-initiated parameter changes.
    bool render(double timeSeconds, bool clear, std::vector<ParamEvent>* events = nullptr);

    uint64_t framesRendered() const;

    // Block until the GPU has retired everything render() submitted. Only for
    // CPU readback in tests; a Jitter caller relies on glFlush ordering instead.
    void finish();

private:
    Instance() = default;
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::shared_ptr<Module> module_;
};

// Info about the private GL context (for diagnostics).
std::string glInfo();

// CPU readback of the output surface as tightly packed BGRA — for tests only.
bool readSurface(IOSurfaceRef surface, std::vector<uint8_t>& bgra, uint32_t& w, uint32_t& h);

}  // namespace ffgl_host

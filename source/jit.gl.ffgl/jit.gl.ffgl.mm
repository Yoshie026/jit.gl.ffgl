// jit.gl.ffgl — load an FFGL 2.x plugin in Max/Jitter.
//
//   [jit.world]──bang──►[jit.gl.ffgl @plugin MyPlugin]──jit_gl_texture──►[jit.gl.videoplane]
//
// The plugin runs in a private OpenGL 4.1 core context (see ffgl_host.h); frames
// travel to and from Jitter as IOSurfaces, so nothing the plugin does to GL state
// can disturb Jitter's context. Every plugin parameter is exposed as a real Max
// attribute (usable as @name in the box, as a message, in attrui / the inspector)
// plus the generic `param` / `paramn` / `getparam` messages.
//
// Compiled as one translation unit: the Jitter class and its Max wrapper.

#define GL_SILENCE_DEPRECATION 1

#include "jit.common.h"
#include "jit.gl.h"

#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/OpenGL.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "ffgl_host.h"

using ffgl_host::InputTarget;
using ffgl_host::ParamInfo;
using ffgl_host::ParamKind;

// ---------------------------------------------------------------------------
// types
// ---------------------------------------------------------------------------

namespace {

struct GLSide {  // resources living in *Jitter's* context
    CGLContextObj ctx = nullptr;
    uint64_t gen = 0;
    uint32_t w = 0, h = 0;
    std::vector<GLuint> inTex, inFbo;
    GLuint outTex = 0, outFbo = 0;
    GLuint tmpFbo = 0;
};

struct DynAttr {
    t_symbol* name;      // attribute name on the object
    uint32_t param;      // plugin parameter index
    t_object* attr;
};

struct State {
    std::shared_ptr<ffgl_host::Module> mod;
    std::unique_ptr<ffgl_host::Instance> inst;
    GLSide gl;
    std::vector<t_symbol*> inputs;          // texture names per input slot
    std::vector<DynAttr> dyn;
    std::mutex evMutex;
    std::vector<ffgl_host::ParamEvent> events;
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    uint64_t framesLogged = 0;
    bool failedOnce = false;
};

}  // namespace

typedef struct _jit_gl_ffgl {
    t_object ob;
    void* ob3d;

    void* output;        // internal jit.gl.texture we hand downstream
    t_symbol* outname;

    t_symbol* plugin;    // @plugin
    t_atom_long dim[2];  // @dim
    long adapt;          // @adapt
    long clear;          // @clear
    long sync;           // @sync
    t_symbol* intarget;  // @intarget 2d (default, padded) | rect
    double bpm;          // @bpm
    double barphase;     // @barphase

    State* st;
} t_jit_gl_ffgl;

static void* s_jit_class = nullptr;
static t_symbol *sym_glid, *sym_dim, *sym_rectangle, *sym_flip, *sym_name, *sym_drawto, *sym_texture,
    *sym_jit_gl_texture, *sym_defaultimage, *sym_black, *sym_draw, *sym_out_name, *sym_two_d, *sym_rect;

// ---------------------------------------------------------------------------
// forward declarations
// ---------------------------------------------------------------------------

static t_jit_gl_ffgl* jit_gl_ffgl_new(t_symbol* dest_name);
static void jit_gl_ffgl_free(t_jit_gl_ffgl* x);
static void trace(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void trace(const char* fmt, ...) {
    static const char* path = getenv("FFGL_TRACE");
    if (!path) return;
    FILE* f = fopen(path, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static t_jit_err jit_gl_ffgl_draw(t_jit_gl_ffgl* x);
static t_jit_err jit_gl_ffgl_dest_closing(t_jit_gl_ffgl* x);
static t_jit_err jit_gl_ffgl_dest_changed(t_jit_gl_ffgl* x);
static bool ffgl_load(t_jit_gl_ffgl* x, const std::string& nameOrPath);
static void ffgl_unload(t_jit_gl_ffgl* x);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static std::string sanitize(const std::string& in) {
    std::string s;
    for (char c : in) {
        if (std::isalnum((unsigned char)c)) s += (char)std::tolower((unsigned char)c);
        else if (!s.empty() && s.back() != '_') s += '_';
    }
    while (!s.empty() && s.back() == '_') s.pop_back();
    if (s.empty()) s = "param";
    if (std::isdigit((unsigned char)s[0])) s = "p_" + s;
    return s;
}

static std::string atomsToString(long argc, t_atom* argv) {
    std::string s;
    for (long i = 0; i < argc; ++i) {
        if (i) s += ' ';
        if (atom_gettype(argv + i) == A_SYM) s += atom_getsym(argv + i)->s_name;
        else if (atom_gettype(argv + i) == A_LONG) s += std::to_string((long long)atom_getlong(argv + i));
        else if (atom_gettype(argv + i) == A_FLOAT) s += std::to_string(atom_getfloat(argv + i));
    }
    return s;
}

static void logToMax(const std::string& s) { post("jit.gl.ffgl: %s", s.c_str()); }

// ---------------------------------------------------------------------------
// attributes
// ---------------------------------------------------------------------------

static t_jit_err attr_plugin_set(t_jit_gl_ffgl* x, void*, long ac, t_atom* av) {
    if (!x) return JIT_ERR_INVALID_PTR;
    if (ac && av && atom_gettype(av) == A_SYM && atom_getsym(av) != _jit_sym_nothing)
        ffgl_load(x, atom_getsym(av)->s_name);
    else
        ffgl_unload(x);
    return JIT_ERR_NONE;
}

static t_jit_err attr_dim_set(t_jit_gl_ffgl* x, void*, long ac, t_atom* av) {
    if (!x) return JIT_ERR_INVALID_PTR;
    for (long i = 0; i < std::min(ac, 2L); ++i) x->dim[i] = std::max<t_atom_long>(1, jit_atom_getlong(av + i));
    if (ac == 1) x->dim[1] = x->dim[0];
    return JIT_ERR_NONE;
}

static t_jit_err attr_intarget_set(t_jit_gl_ffgl* x, void*, long ac, t_atom* av) {
    if (!x) return JIT_ERR_INVALID_PTR;
    t_symbol* s = (ac && av && atom_gettype(av) == A_SYM) ? atom_getsym(av) : sym_two_d;
    if (s != sym_two_d && s != sym_rect) {
        object_error((t_object*)x, "@intarget must be 2d or rect");
        return JIT_ERR_NONE;
    }
    x->intarget = s;
    if (x->st && x->st->inst)
        x->st->inst->setInputTarget(s == sym_rect ? InputTarget::Rectangle : InputTarget::Texture2D);
    return JIT_ERR_NONE;
}

static t_jit_err attr_bpm_set(t_jit_gl_ffgl* x, void*, long ac, t_atom* av) {
    if (!x || !ac) return JIT_ERR_INVALID_PTR;
    x->bpm = jit_atom_getfloat(av);
    if (x->st && x->st->inst) x->st->inst->setBeat((float)x->bpm, (float)x->barphase);
    return JIT_ERR_NONE;
}
static t_jit_err attr_barphase_set(t_jit_gl_ffgl* x, void*, long ac, t_atom* av) {
    if (!x || !ac) return JIT_ERR_INVALID_PTR;
    x->barphase = jit_atom_getfloat(av);
    if (x->st && x->st->inst) x->st->inst->setBeat((float)x->bpm, (float)x->barphase);
    return JIT_ERR_NONE;
}

static t_jit_err attr_out_name_get(t_jit_gl_ffgl* x, void*, long* ac, t_atom** av) {
    if (!(*ac && *av)) {
        *ac = 1;
        if (!(*av = (t_atom*)jit_getbytes(sizeof(t_atom)))) {
            *ac = 0;
            return JIT_ERR_OUT_OF_MEM;
        }
    }
    jit_atom_setsym(*av, x->output ? jit_attr_getsym(x->output, sym_name) : _jit_sym_nothing);
    return JIT_ERR_NONE;
}

// --- dynamic per-parameter attributes ---------------------------------------

static const DynAttr* dyn_lookup(t_jit_gl_ffgl* x, void* attr) {
    if (!x->st) return nullptr;
    t_symbol* n = (t_symbol*)jit_object_method(attr, _jit_sym_getname);
    for (auto& d : x->st->dyn)
        if (d.name == n) return &d;
    return nullptr;
}

// Convert a Max value into what the plugin expects and queue it.
static bool apply_param(t_jit_gl_ffgl* x, uint32_t idx, long ac, t_atom* av, bool normalized) {
    State* s = x->st;
    if (!s || !s->inst || idx >= s->mod->params().size() || ac < 1) return false;
    const ParamInfo& p = s->mod->params()[idx];
    auto& inst = *s->inst;
    trace("apply_param %s idx=%u kind=%d ac=%ld a0=%f", p.name.c_str(), idx, (int)p.kind, ac, (double)atom_getfloat(av));
    switch (p.kind) {
        case ParamKind::Text:
        case ParamKind::File:
            inst.setText(idx, atomsToString(ac, av));
            return true;
        case ParamKind::Event:
            inst.trigger(idx);
            return true;
        case ParamKind::Boolean: {
            bool on = atom_gettype(av) == A_SYM ? std::strcmp(atom_getsym(av)->s_name, "0") != 0
                                                  : atom_getfloat(av) != 0.0;
            inst.setFloat(idx, on ? 1.f : 0.f);
            return true;
        }
        case ParamKind::Option: {
            if (p.options.empty()) return false;
            if (atom_gettype(av) == A_SYM) {
                std::string want = atom_getsym(av)->s_name;
                for (auto& o : p.options)
                    if (o.name == want) { inst.setFloat(idx, o.value); return true; }
                object_error((t_object*)x, "%s: no option named \"%s\"", p.name.c_str(), want.c_str());
                return false;
            }
            long i = std::clamp<long>(atom_getlong(av), 0, (long)p.options.size() - 1);
            inst.setFloat(idx, p.options[(size_t)i].value);
            return true;
        }
        case ParamKind::Buffer:
            object_error((t_object*)x, "%s: buffer parameters are not supported yet", p.name.c_str());
            return false;
        case ParamKind::Integer:
        case ParamKind::Float:
        default: {
            float v = (float)atom_getfloat(av);
            if (normalized) v = p.min + std::clamp(v, 0.f, 1.f) * (p.max - p.min);
            else v = std::clamp(v, p.min, p.max);
            if (p.kind == ParamKind::Integer) v = std::round(v);
            inst.setFloat(idx, v);
            return true;
        }
    }
}

static t_jit_err dyn_attr_set(t_jit_gl_ffgl* x, void* attr, long ac, t_atom* av) {
    const DynAttr* d = dyn_lookup(x, attr);
    if (!d) return JIT_ERR_GENERIC;
    apply_param(x, d->param, ac, av, false);
    return JIT_ERR_NONE;
}

static t_jit_err dyn_attr_get(t_jit_gl_ffgl* x, void* attr, long* ac, t_atom** av) {
    const DynAttr* d = dyn_lookup(x, attr);
    if (!d || !x->st || !x->st->inst) return JIT_ERR_GENERIC;
    const ParamInfo& p = x->st->mod->params()[d->param];
    if (!(*ac && *av)) {
        *ac = 1;
        if (!(*av = (t_atom*)jit_getbytes(sizeof(t_atom)))) {
            *ac = 0;
            return JIT_ERR_OUT_OF_MEM;
        }
    }
    auto& inst = *x->st->inst;
    switch (p.kind) {
        case ParamKind::Text:
        case ParamKind::File:
            jit_atom_setsym(*av, gensym(inst.textValue(d->param).c_str()));
            break;
        case ParamKind::Option: {
            float v = inst.floatValue(d->param);
            t_symbol* nm = _jit_sym_nothing;
            for (auto& o : p.options)
                if (std::fabs(o.value - v) < 1e-4f) { nm = gensym(o.name.c_str()); break; }
            jit_atom_setsym(*av, nm);
            break;
        }
        case ParamKind::Boolean:
        case ParamKind::Event:
        case ParamKind::Integer:
            jit_atom_setlong(*av, (t_atom_long)std::lround(inst.floatValue(d->param)));
            break;
        default:
            jit_atom_setfloat(*av, inst.floatValue(d->param));
    }
    return JIT_ERR_NONE;
}

static void dyn_attrs_clear(t_jit_gl_ffgl* x) {
    if (!x->st) return;
    for (auto& d : x->st->dyn) object_deleteattr((t_object*)x, d.name);
    x->st->dyn.clear();
}

static void dyn_attrs_build(t_jit_gl_ffgl* x) {
    State* s = x->st;
    std::set<std::string> taken;
    // Names the object already owns must not be shadowed by a plugin parameter.
    for (const char* r : {"plugin", "dim", "adapt", "clear", "sync", "intarget", "bpm", "barphase",
                          "out_name", "drawto", "enable", "automatic", "name", "texture", "position",
                          "rotate", "scale", "blend", "color", "depth_enable", "lighting_enable",
                          "layer", "capture", "matrixoutput", "inputs"})
        taken.insert(r);
    for (auto& p : s->mod->params()) {
        std::string base = sanitize(p.name), name = base;
        for (int n = 2; taken.count(name); ++n) name = base + "_" + std::to_string(n);
        taken.insert(name);

        t_symbol* type = gensym("float32");
        switch (p.kind) {
            case ParamKind::Boolean: case ParamKind::Event: case ParamKind::Integer: type = _jit_sym_long; break;
            case ParamKind::Text: case ParamKind::File: case ParamKind::Option: type = _jit_sym_symbol; break;
            default: break;
        }
        // Option parameters accept a number or a name, so declare them as atoms.
        if (p.kind == ParamKind::Option) type = _jit_sym_atom;
        t_object* attr = (t_object*)attribute_new(name.c_str(), type, ATTR_FLAGS_NONE,
                                                  (method)dyn_attr_get, (method)dyn_attr_set);
        if (!attr) continue;
        // Clamp to the plugin's reported range (also what attrui / the inspector show).
        if (p.kind == ParamKind::Float || p.kind == ParamKind::Integer)
            attr_addfilter_clip(attr, p.min, p.max, 1, 1);
        object_addattr((t_object*)x, attr);
        s->dyn.push_back({gensym(name.c_str()), p.index, attr});
    }
}

// ---------------------------------------------------------------------------
// load / unload
// ---------------------------------------------------------------------------

static void gl_release(t_jit_gl_ffgl* x);

static void ffgl_unload(t_jit_gl_ffgl* x) {
    if (!x->st) return;
    dyn_attrs_clear(x);
    gl_release(x);
    x->st->inst.reset();
    x->st->mod.reset();
    x->plugin = _jit_sym_nothing;
}

static bool ffgl_load(t_jit_gl_ffgl* x, const std::string& nameOrPath) {
    State* s = x->st;
    ffgl_unload(x);
    std::string err;
    auto mod = ffgl_host::Module::open(nameOrPath, err);
    if (!mod) {
        object_error((t_object*)x, "%s", err.c_str());
        return false;
    }
    auto inst = ffgl_host::Instance::create(mod, (uint32_t)x->dim[0], (uint32_t)x->dim[1], err);
    if (!inst) {
        object_error((t_object*)x, "%s", err.c_str());
        return false;
    }
    inst->setInputTarget(x->intarget == sym_rect ? InputTarget::Rectangle : InputTarget::Texture2D);
    inst->setBeat((float)x->bpm, (float)x->barphase);
    s->mod = mod;
    s->inst = std::move(inst);
    // Keep texture names set with `input` across (re)loads, so message order doesn't matter.
    if (s->inputs.size() < std::max<uint32_t>(1, s->inst->numInputs()))
        s->inputs.resize(std::max<uint32_t>(1, s->inst->numInputs()), nullptr);
    s->t0 = std::chrono::steady_clock::now();
    s->failedOnce = false;
    x->plugin = gensym(nameOrPath.c_str());
    dyn_attrs_build(x);
    object_post((t_object*)x, "loaded %s (%s) — %zu parameters, %u input%s", mod->info().name.c_str(),
                mod->info().id.c_str(), mod->params().size(), mod->info().numInputs,
                mod->info().numInputs == 1 ? "" : "s");
    return true;
}

// ---------------------------------------------------------------------------
// GL side (Jitter's context)
// ---------------------------------------------------------------------------

static void gl_release(t_jit_gl_ffgl* x) {
    GLSide& g = x->st->gl;
    // Only touch GL names if the context they belong to is the current one;
    // otherwise the context is gone (or elsewhere) and the names died with it.
    if (g.ctx && g.ctx == CGLGetCurrentContext()) {
        if (!g.inFbo.empty()) glDeleteFramebuffers((GLsizei)g.inFbo.size(), g.inFbo.data());
        if (!g.inTex.empty()) glDeleteTextures((GLsizei)g.inTex.size(), g.inTex.data());
        if (g.outFbo) glDeleteFramebuffers(1, &g.outFbo);
        if (g.outTex) glDeleteTextures(1, &g.outTex);
        if (g.tmpFbo) glDeleteFramebuffers(1, &g.tmpFbo);
    }
    g = GLSide();
}

static bool gl_bind_surface(CGLContextObj ctx, IOSurfaceRef surf, uint32_t w, uint32_t h, GLuint& tex,
                            GLuint& fbo) {
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, tex);
    CGLError err = CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE_EXT, GL_RGBA8, (GLsizei)w, (GLsizei)h,
                                          GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surf, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, 0);
    if (err != kCGLNoError) return false;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_EXT, tex, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

static bool gl_ensure(t_jit_gl_ffgl* x, CGLContextObj ctx) {
    State* s = x->st;
    GLSide& g = s->gl;
    auto& inst = *s->inst;
    if (g.ctx == ctx && g.gen == inst.surfaceGeneration() && g.w == inst.width() && g.h == inst.height())
        return true;
    gl_release(x);
    g.ctx = ctx;
    g.gen = inst.surfaceGeneration();
    g.w = inst.width();
    g.h = inst.height();
    g.inTex.assign(inst.numInputs(), 0);
    g.inFbo.assign(inst.numInputs(), 0);
    bool ok = true;
    for (uint32_t i = 0; i < inst.numInputs(); ++i)
        ok = gl_bind_surface(ctx, inst.inputSurface(i), g.w, g.h, g.inTex[i], g.inFbo[i]) && ok;
    ok = gl_bind_surface(ctx, inst.outputSurface(), g.w, g.h, g.outTex, g.outFbo) && ok;
    glGenFramebuffers(1, &g.tmpFbo);
    if (!ok) {
        object_error((t_object*)x, "could not bind IOSurface textures in Jitter's context");
        gl_release(x);
        return false;
    }
    return true;
}

// is_gl_texture() is declared in jit.gl.h but not exported by Jitter,
// so recognise texture objects by class name instead.
static bool is_gl_texture(void* ob) {
    if (!ob) return false;
    t_symbol* cn = jit_object_classname(ob);
    return cn && std::strncmp(cn->s_name, "jit_gl_texture", 14) == 0;
}

// Make sure a jit.gl.texture has real GL storage in the current context and
// return its GL id (0 if it isn't a usable texture).
static GLuint texture_glid(t_jit_gl_ffgl* x, t_object* tex, t_symbol* name) {
    t_jit_gl_drawinfo di;
    jit_gl_drawinfo_setup(x, &di);
    jit_gl_bindtexture(&di, name, 0);
    jit_gl_unbindtexture(&di, name, 0);
    return (GLuint)jit_attr_getlong(tex, sym_glid);
}

// Trace-only: average CPU time spent inside ob3d_draw, reported with the pixel trace.
struct DrawTimer {
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    static double& total() { static double v = 0; return v; }
    static long& n() { static long v = 0; return v; }
    ~DrawTimer() {
        total() += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        ++n();
    }
};

static t_jit_err jit_gl_ffgl_draw(t_jit_gl_ffgl* x) {
    DrawTimer drawTimer;
    State* s = x ? x->st : nullptr;
    trace("draw: x=%p st=%p inst=%p output=%p ctx=%p", (void*)x, (void*)s, s ? (void*)s->inst.get() : nullptr,
          x ? (void*)x->output : nullptr, (void*)CGLGetCurrentContext());
    if (!s || !s->inst || !x->output) return JIT_ERR_NONE;
    auto& inst = *s->inst;
    CGLContextObj ctx = CGLGetCurrentContext();
    if (!ctx) return JIT_ERR_NONE;

    // --- decide the working size: follow the first input, else @dim --------
    t_object* in0 = nullptr;
    if (!s->inputs.empty() && s->inputs[0] && s->inputs[0] != _jit_sym_nothing) {
        in0 = (t_object*)jit_object_findregistered(s->inputs[0]);
        if (in0 && !is_gl_texture(in0)) in0 = nullptr;
    }
    uint32_t w = (uint32_t)x->dim[0], h = (uint32_t)x->dim[1];
    if (x->adapt && in0) {
        t_atom_long d[2] = {0, 0};
        jit_attr_getlong_array(in0, sym_dim, 2, d);
        if (d[0] > 0 && d[1] > 0) { w = (uint32_t)d[0]; h = (uint32_t)d[1]; }
    }
    if (w != inst.width() || h != inst.height()) inst.resize(w, h);
    if (!gl_ensure(x, ctx)) { trace("draw: gl_ensure failed"); return JIT_ERR_NONE; }
    GLSide& g = s->gl;

    // --- save the bits of state we touch -----------------------------------
    GLint prevRead = 0, prevDraw = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prevRead);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDraw);

    // --- Jitter textures -> input IOSurfaces (GPU blit, flips if needed) -----
    for (uint32_t i = 0; i < inst.numInputs(); ++i) {
        t_symbol* nm = i < s->inputs.size() ? s->inputs[i] : nullptr;
        t_object* tex = nm && nm != _jit_sym_nothing ? (t_object*)jit_object_findregistered(nm) : nullptr;
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g.inFbo[i]);
        if (!tex || !is_gl_texture(tex)) {
            glClearColor(0, 0, 0, 0);
            glClear(GL_COLOR_BUFFER_BIT);
            continue;
        }
        GLuint id = texture_glid(x, tex, nm);
        if (!id) {
            glClearColor(0, 0, 0, 0);
            glClear(GL_COLOR_BUFFER_BIT);
            continue;
        }
        t_atom_long d[2] = {(t_atom_long)w, (t_atom_long)h};
        jit_attr_getlong_array(tex, sym_dim, 2, d);
        const bool rect = jit_attr_getlong(tex, sym_rectangle) != 0;
        const bool flip = jit_attr_getlong(tex, sym_flip) != 0;
        const GLenum target = rect ? GL_TEXTURE_RECTANGLE_EXT : GL_TEXTURE_2D;
        glBindFramebuffer(GL_READ_FRAMEBUFFER, g.tmpFbo);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, id, 0);
        // A texture with @flip 1 stores its image top-down; FFGL wants bottom-left origin.
        glBlitFramebuffer(0, 0, (GLint)d[0], (GLint)d[1], 0, flip ? (GLint)h : 0, (GLint)w,
                          flip ? 0 : (GLint)h, GL_COLOR_BUFFER_BIT,
                          (d[0] == (t_atom_long)w && d[1] == (t_atom_long)h) ? GL_NEAREST : GL_LINEAR);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, 0, 0);
    }
    glFlush();
    if (x->sync) glFinish();

    // --- run the plugin in its private context --------------------------------
    const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - s->t0).count();
    std::vector<ffgl_host::ParamEvent> evs;
    bool ok = inst.render(t, x->clear != 0, &evs);
    trace("[%s %p] rendered %ux%u ok=%d t=%.3f", s->mod->info().name.c_str(), (void*)x, w, h, (int)ok, t);
    if (!ok && !s->failedOnce) {
        s->failedOnce = true;
        object_warn((t_object*)x, "plugin returned FF_FAIL from ProcessOpenGL");
    }
    if (!evs.empty()) {
        std::lock_guard<std::mutex> lk(s->evMutex);
        s->events.insert(s->events.end(), evs.begin(), evs.end());
    }
    if (x->sync) glFinish();  // (render() already flushed on its side)

    // --- output IOSurface -> our jit.gl.texture -------------------------------
    t_atom_long od[2] = {0, 0};
    jit_attr_getlong_array(x->output, sym_dim, 2, od);
    if (od[0] != (t_atom_long)w || od[1] != (t_atom_long)h) {
        od[0] = w;
        od[1] = h;
        jit_attr_setlong_array(x->output, sym_dim, 2, od);
    }
    GLuint outId = texture_glid(x, (t_object*)x->output, x->outname);
    if (outId) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, g.outFbo);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g.tmpFbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_EXT, outId, 0);
        if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE)
            glBlitFramebuffer(0, 0, (GLint)w, (GLint)h, 0, 0, (GLint)w, (GLint)h, GL_COLOR_BUFFER_BIT,
                              GL_NEAREST);
        else if (!s->failedOnce) {
            s->failedOnce = true;
            object_error((t_object*)x, "output texture is not renderable");
        }
        static const bool tracing = getenv("FFGL_TRACE") != nullptr;
        if (tracing) {
            static std::map<void*, int> counts;
            int n = ++counts[(void*)x];
            if (n <= 3 || n % 500 == 0) {
                GLubyte a[4] = {0}, b[4] = {0};
                glBindFramebuffer(GL_READ_FRAMEBUFFER, g.outFbo);
                glReadPixels((GLint)w / 2, (GLint)h / 2, 1, 1, GL_BGRA, GL_UNSIGNED_BYTE, a);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, g.tmpFbo);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_EXT, outId, 0);
                glReadPixels((GLint)w / 2, (GLint)h / 2, 1, 1, GL_BGRA, GL_UNSIGNED_BYTE, b);
                GLubyte c[4] = {0};
                if (!g.inFbo.empty()) {
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, g.inFbo[0]);
                    glReadPixels((GLint)w / 2, (GLint)h / 2, 1, 1, GL_BGRA, GL_UNSIGNED_BYTE, c);
                }
                trace("[%s %p] input0 centre BGRA=%u,%u,%u,%u", s->mod->info().name.c_str(), (void*)x, c[0], c[1],
                      c[2], c[3]);
                trace("[%s %p] avg draw cpu %.3f ms/frame over %ld frames", s->mod->info().name.c_str(), (void*)x,
                      DrawTimer::total() / std::max(1L, DrawTimer::n()), DrawTimer::n());
                trace("[%s %p] pixels[%d] centre plugin-out BGRA=%u,%u,%u,%u  jitter-tex BGRA=%u,%u,%u,%u outId=%u", s->mod->info().name.c_str(), (void*)x, n, a[0],
                      a[1], a[2], a[3], b[0], b[1], b[2], b[3], outId);
            }
        }
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_EXT, 0, 0);
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prevRead);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDraw);
    return JIT_ERR_NONE;
}

static t_jit_err jit_gl_ffgl_dest_closing(t_jit_gl_ffgl* x) {
    if (x && x->st) gl_release(x);  // context is current here
    return JIT_ERR_NONE;
}

static t_jit_err jit_gl_ffgl_dest_changed(t_jit_gl_ffgl* x) {
    if (!x) return JIT_ERR_INVALID_PTR;
    if (x->st) x->st->gl = GLSide();  // old context's names are gone with it
    if (x->output) {
        t_symbol* ctxName = jit_attr_getsym(x, sym_drawto);
        jit_attr_setsym(x->output, sym_drawto, ctxName);
        // a texture must be bound once in a new context before it is usable there
        t_jit_gl_drawinfo di;
        jit_gl_drawinfo_setup(x, &di);
        jit_gl_bindtexture(&di, x->outname, 0);
        jit_gl_unbindtexture(&di, x->outname, 0);
    }
    return JIT_ERR_NONE;
}

// input textures ---------------------------------------------------------------

static t_jit_err jit_gl_ffgl_set_input(t_jit_gl_ffgl* x, long slot, t_symbol* name) {
    if (!x || !x->st) return JIT_ERR_INVALID_PTR;
    if (slot < 0 || slot > 15) return JIT_ERR_GENERIC;
    if ((size_t)slot >= x->st->inputs.size()) x->st->inputs.resize((size_t)slot + 1, nullptr);
    x->st->inputs[(size_t)slot] = name;
    return JIT_ERR_NONE;
}

static t_jit_err jit_gl_ffgl_texture_msg(t_jit_gl_ffgl* x, t_symbol* name) {
    return jit_gl_ffgl_set_input(x, 0, name);
}

// ---------------------------------------------------------------------------
// jit class
// ---------------------------------------------------------------------------

static t_jit_err jit_gl_ffgl_init(void) {
    sym_glid = gensym("glid");
    sym_dim = _jit_sym_dim;
    sym_rectangle = gensym("rectangle");
    sym_flip = gensym("flip");
    sym_name = _jit_sym_name;
    sym_drawto = gensym("drawto");
    sym_texture = gensym("texture");
    sym_jit_gl_texture = gensym("jit_gl_texture");
    sym_defaultimage = gensym("defaultimage");
    sym_black = gensym("black");
    sym_draw = gensym("draw");
    sym_out_name = gensym("out_name");
    sym_two_d = gensym("2d");
    sym_rect = gensym("rect");

    long flags = JIT_OB3D_NO_MATRIXOUTPUT | JIT_OB3D_NO_ROTATION_SCALE | JIT_OB3D_NO_POLY_VARS |
                 JIT_OB3D_NO_FOG | JIT_OB3D_NO_LIGHTING_MATERIAL | JIT_OB3D_NO_DEPTH | JIT_OB3D_NO_COLOR;

    s_jit_class = jit_class_new("jit_gl_ffgl", (method)jit_gl_ffgl_new, (method)jit_gl_ffgl_free,
                                sizeof(t_jit_gl_ffgl), A_DEFSYM, 0L);
    jit_ob3d_setup(s_jit_class, calcoffset(t_jit_gl_ffgl, ob3d), flags);

    jit_class_addmethod(s_jit_class, (method)jit_gl_ffgl_draw, "ob3d_draw", A_CANT, 0L);
    jit_class_addmethod(s_jit_class, (method)jit_gl_ffgl_dest_closing, "dest_closing", A_CANT, 0L);
    jit_class_addmethod(s_jit_class, (method)jit_gl_ffgl_dest_changed, "dest_changed", A_CANT, 0L);
    jit_class_addmethod(s_jit_class, (method)jit_object_register, "register", A_CANT, 0L);
    jit_class_addmethod(s_jit_class, (method)jit_gl_ffgl_texture_msg, "jit_gl_texture", A_SYM, 0L);

    const long af = JIT_ATTR_GET_DEFER_LOW | JIT_ATTR_SET_USURP_LOW;
    t_jit_object* a;

    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, "plugin", _jit_sym_symbol, af, (method)0L,
                                      (method)attr_plugin_set, calcoffset(t_jit_gl_ffgl, plugin));
    jit_class_addattr(s_jit_class, a);

    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset_array, "dim", _jit_sym_long, 2, af,
                                      (method)0L, (method)attr_dim_set, 0, calcoffset(t_jit_gl_ffgl, dim));
    jit_class_addattr(s_jit_class, a);

    const std::vector<std::pair<const char*, long>> longAttrs = {
        {"adapt", calcoffset(t_jit_gl_ffgl, adapt)},
        {"clear", calcoffset(t_jit_gl_ffgl, clear)},
        {"sync", calcoffset(t_jit_gl_ffgl, sync)}};
    for (auto& [name, off] : longAttrs) {
        a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, name, _jit_sym_long, af, (method)0L,
                                          (method)0L, off);
        jit_class_addattr(s_jit_class, a);
    }
    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, "intarget", _jit_sym_symbol, af, (method)0L,
                                      (method)attr_intarget_set, calcoffset(t_jit_gl_ffgl, intarget));
    jit_class_addattr(s_jit_class, a);
    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, "bpm", _jit_sym_float64, af, (method)0L,
                                      (method)attr_bpm_set, calcoffset(t_jit_gl_ffgl, bpm));
    jit_class_addattr(s_jit_class, a);
    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, "barphase", _jit_sym_float64, af, (method)0L,
                                      (method)attr_barphase_set, calcoffset(t_jit_gl_ffgl, barphase));
    jit_class_addattr(s_jit_class, a);

    a = (t_jit_object*)jit_object_new(_jit_sym_jit_attr_offset, "out_name", _jit_sym_symbol,
                                      JIT_ATTR_GET_DEFER_LOW | JIT_ATTR_SET_OPAQUE_USER,
                                      (method)attr_out_name_get, (method)0L, 0);
    jit_class_addattr(s_jit_class, a);

    jit_class_register(s_jit_class);
    return JIT_ERR_NONE;
}

static t_jit_gl_ffgl* jit_gl_ffgl_new(t_symbol* dest_name) {
    t_jit_gl_ffgl* x = (t_jit_gl_ffgl*)jit_object_alloc(s_jit_class);
    if (!x) return nullptr;
    x->st = new State();
    x->plugin = _jit_sym_nothing;
    x->dim[0] = 1280;
    x->dim[1] = 720;
    x->adapt = 1;
    x->clear = 1;
    x->sync = 0;
    x->intarget = sym_two_d;
    x->bpm = 120.0;
    x->barphase = 0.0;

    x->output = jit_object_new(sym_jit_gl_texture, dest_name);
    if (x->output) {
        x->outname = jit_symbol_unique();
        jit_attr_setsym(x->output, sym_name, x->outname);
        jit_attr_setsym(x->output, sym_defaultimage, sym_black);
        jit_attr_setlong(x->output, sym_rectangle, 1);
        jit_attr_setlong(x->output, sym_flip, 0);  // our pixels are already GL-oriented
        jit_attr_setlong_array(x->output, sym_dim, 2, x->dim);
    } else {
        object_error((t_object*)x, "jit.gl.ffgl: could not create the output texture");
        x->outname = _jit_sym_nothing;
    }
    jit_ob3d_new(x, dest_name);
    return x;
}

static void jit_gl_ffgl_free(t_jit_gl_ffgl* x) {
    if (!x) return;
    if (x->st) {
        dyn_attrs_clear(x);
        gl_release(x);
        x->st->inst.reset();
        x->st->mod.reset();
    }
    jit_ob3d_free(x);
    if (x->output) jit_object_free(x->output);
    delete x->st;
    x->st = nullptr;
}

// ===========================================================================
// Max wrapper
// ===========================================================================

typedef struct _max_jit_gl_ffgl {
    t_object ob;
    void* obex;
    void* texout;
    void* dumpout;
} t_max_jit_gl_ffgl;

static t_class* s_max_class = nullptr;

static t_jit_gl_ffgl* jitob(t_max_jit_gl_ffgl* x) { return (t_jit_gl_ffgl*)max_jit_obex_jitob_get(x); }

static const char* kind_name(ParamKind k) {
    switch (k) {
        case ParamKind::Boolean: return "bool";
        case ParamKind::Event: return "event";
        case ParamKind::Float: return "float";
        case ParamKind::Integer: return "int";
        case ParamKind::Option: return "option";
        case ParamKind::Text: return "text";
        case ParamKind::File: return "file";
        case ParamKind::Buffer: return "buffer";
    }
    return "?";
}

// Resolve "name" / "attr_name" / index to a parameter index.
static int find_param(t_jit_gl_ffgl* x, t_atom* a) {
    State* s = x->st;
    if (!s || !s->mod) return -1;
    if (atom_gettype(a) != A_SYM) {
        long i = (long)atom_getlong(a);
        return i >= 0 && (size_t)i < s->mod->params().size() ? (int)i : -1;
    }
    std::string want = atom_getsym(a)->s_name;
    for (auto& d : s->dyn)
        if (want == d.name->s_name) return (int)d.param;
    return s->mod->findParam(want);
}

static void max_ffgl_param_common(t_max_jit_gl_ffgl* x, long argc, t_atom* argv, bool normalized) {
    t_jit_gl_ffgl* j = jitob(x);
    if (!j->st || !j->st->inst) { object_error((t_object*)x, "no plugin loaded"); return; }
    if (argc < 2) { object_error((t_object*)x, "usage: param <name|index> <value...>"); return; }
    int idx = find_param(j, argv);
    if (idx < 0) {
        object_error((t_object*)x, "no such parameter: %s", atomsToString(1, argv).c_str());
        return;
    }
    apply_param(j, (uint32_t)idx, argc - 1, argv + 1, normalized);
}

static void max_ffgl_param(t_max_jit_gl_ffgl* x, t_symbol*, long argc, t_atom* argv) {
    max_ffgl_param_common(x, argc, argv, false);
}
static void max_ffgl_paramn(t_max_jit_gl_ffgl* x, t_symbol*, long argc, t_atom* argv) {
    max_ffgl_param_common(x, argc, argv, true);
}

static void max_ffgl_getparam(t_max_jit_gl_ffgl* x, t_symbol*, long argc, t_atom* argv) {
    t_jit_gl_ffgl* j = jitob(x);
    if (!j->st || !j->st->inst || argc < 1) return;
    int idx = find_param(j, argv);
    if (idx < 0) { object_error((t_object*)x, "no such parameter"); return; }
    const ParamInfo& p = j->st->mod->params()[(size_t)idx];
    t_atom out[2];
    atom_setsym(out, gensym(p.name.c_str()));
    if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
        atom_setsym(out + 1, gensym(j->st->inst->textValue((uint32_t)idx).c_str()));
    else
        atom_setfloat(out + 1, j->st->inst->floatValue((uint32_t)idx));
    outlet_anything(x->dumpout, gensym("param"), 2, out);
}

// Emit the plugin description + every parameter out of the dump outlet:
//   plugininfo <id> <name> <type> <inputs> <api>
//   paraminfo <index> <attrname> <kind> <default> <min> <max> <group> <displayname>
//   paramoption <index> <element#> <name> <value>
static void max_ffgl_params(t_max_jit_gl_ffgl* x) {
    t_jit_gl_ffgl* j = jitob(x);
    State* s = j->st;
    if (!s || !s->mod) { object_error((t_object*)x, "no plugin loaded"); return; }
    const auto& info = s->mod->info();
    {
        t_atom a[5];
        atom_setsym(a, gensym(info.id.c_str()));
        atom_setsym(a + 1, gensym(info.name.c_str()));
        atom_setsym(a + 2, gensym(info.type == 0 ? "effect" : info.type == 1 ? "source" : "mixer"));
        atom_setlong(a + 3, info.numInputs);
        atom_setsym(a + 4, gensym((std::to_string(info.apiMajor) + "." + std::to_string(info.apiMinor)).c_str()));
        outlet_anything(x->dumpout, gensym("plugininfo"), 5, a);
    }
    for (auto& p : s->mod->params()) {
        std::string attrName = p.name;
        for (auto& d : s->dyn) if (d.param == p.index) attrName = d.name->s_name;
        t_atom a[8];
        atom_setlong(a, p.index);
        atom_setsym(a + 1, gensym(attrName.c_str()));
        atom_setsym(a + 2, gensym(kind_name(p.kind)));
        if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
            atom_setsym(a + 3, gensym(p.defText.empty() ? "\"\"" : p.defText.c_str()));
        else
            atom_setfloat(a + 3, p.def);
        atom_setfloat(a + 4, p.min);
        atom_setfloat(a + 5, p.max);
        atom_setsym(a + 6, gensym(p.group.empty() ? "-" : p.group.c_str()));
        atom_setsym(a + 7, gensym(s->inst ? s->inst->displayName(p.index).c_str() : p.displayName.c_str()));
        outlet_anything(x->dumpout, gensym("paraminfo"), 8, a);
        for (size_t e = 0; e < p.options.size(); ++e) {
            t_atom o[4];
            atom_setlong(o, p.index);
            atom_setlong(o + 1, (long)e);
            atom_setsym(o + 2, gensym(p.options[e].name.c_str()));
            atom_setfloat(o + 3, p.options[e].value);
            outlet_anything(x->dumpout, gensym("paramoption"), 4, o);
        }
    }
}

static void max_ffgl_plugins(t_max_jit_gl_ffgl* x) {
    outlet_anything(x->dumpout, gensym("clear"), 0, nullptr);
    for (auto& p : ffgl_host::scanPlugins()) {
        t_atom a[2];
        atom_setsym(a, gensym(p.name.c_str()));
        atom_setsym(a + 1, gensym(p.path.c_str()));
        outlet_anything(x->dumpout, gensym("plugin"), 2, a);
    }
}

static void max_ffgl_load(t_max_jit_gl_ffgl* x, t_symbol*, long argc, t_atom* argv) {
    t_jit_gl_ffgl* j = jitob(x);
    if (argc < 1 || atom_gettype(argv) != A_SYM) { object_error((t_object*)x, "usage: load <plugin name|path>"); return; }
    ffgl_load(j, atomsToString(argc, argv));
    max_ffgl_params(x);
}

static void max_ffgl_reload(t_max_jit_gl_ffgl* x) {
    t_jit_gl_ffgl* j = jitob(x);
    if (j->plugin && j->plugin != _jit_sym_nothing) {
        std::string p = j->plugin->s_name;
        ffgl_load(j, p);
        max_ffgl_params(x);
    }
}

static void max_ffgl_searchpath(t_max_jit_gl_ffgl* x, t_symbol* s) {
    (void)x;
    ffgl_host::addSearchPath(s->s_name);
}

static void max_ffgl_texture(t_max_jit_gl_ffgl* x, t_symbol* s) { jit_gl_ffgl_set_input(jitob(x), 0, s); }

// input <slot> <texname>   (slot 0 is also reachable with a plain jit_gl_texture)
static void max_ffgl_input(t_max_jit_gl_ffgl* x, t_symbol*, long argc, t_atom* argv) {
    if (argc < 2 || atom_gettype(argv + 1) != A_SYM) { object_error((t_object*)x, "usage: input <slot> <texture name>"); return; }
    jit_gl_ffgl_set_input(jitob(x), (long)atom_getlong(argv), atom_getsym(argv + 1));
}

static void max_ffgl_drain_events(t_max_jit_gl_ffgl* x) {
    t_jit_gl_ffgl* j = jitob(x);
    State* s = j->st;
    if (!s || !s->inst) return;
    std::vector<ffgl_host::ParamEvent> evs;
    {
        std::lock_guard<std::mutex> lk(s->evMutex);
        evs.swap(s->events);
    }
    for (auto& e : evs) {
        if (e.index >= s->mod->params().size()) continue;
        const ParamInfo& p = s->mod->params()[e.index];
        if (e.valueChanged) {
            t_atom a[2];
            atom_setsym(a, gensym(p.name.c_str()));
            if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
                atom_setsym(a + 1, gensym(s->inst->textValue(e.index).c_str()));
            else
                atom_setfloat(a + 1, s->inst->floatValue(e.index));
            outlet_anything(x->dumpout, gensym("paramchanged"), 2, a);
        }
        if (e.visibilityChanged) {
            t_atom a[2];
            atom_setsym(a, gensym(p.name.c_str()));
            atom_setlong(a + 1, s->inst->visible(e.index) ? 1 : 0);
            outlet_anything(x->dumpout, gensym("paramvisible"), 2, a);
        }
        if (e.displayNameChanged) {
            t_atom a[2];
            atom_setsym(a, gensym(p.name.c_str()));
            atom_setsym(a + 1, gensym(s->inst->displayName(e.index).c_str()));
            outlet_anything(x->dumpout, gensym("paramlabel"), 2, a);
        }
    }
}

static void max_ffgl_draw(t_max_jit_gl_ffgl* x, t_symbol* s, long argc, t_atom* argv) {
    t_jit_object* jo = (t_jit_object*)max_jit_obex_jitob_get(x);
    // With @automatic 1 (default) the object already draws in its context's render pass, so a
    // bang from jit.world would render the plugin a second time per frame. Only render here when
    // the patch drives drawing itself (@automatic 0); either way, re-emit the texture name.
    static t_symbol* sym_automatic = gensym("automatic");
    if (!jit_attr_getlong(jo, sym_automatic))
        jit_object_method(jo, sym_draw, sym_draw, argc, argv);  // sets up Jitter's context, calls ob3d_draw
    t_atom a;
    jit_atom_setsym(&a, jit_attr_getsym(jo, sym_out_name));
    outlet_anything(x->texout, sym_jit_gl_texture, 1, &a);
    max_ffgl_drain_events(x);
    (void)s;
}

static void max_ffgl_bang(t_max_jit_gl_ffgl* x) { max_ffgl_draw(x, sym_draw, 0, nullptr); }

static void max_ffgl_assist(t_max_jit_gl_ffgl*, void*, long m, long a, char* s) {
    if (m == ASSIST_INLET) {
        std::snprintf(s, 256, "bang / jit_gl_texture in, param and attribute messages");
    } else {
        if (a == 0) std::snprintf(s, 256, "jit_gl_texture out");
        else std::snprintf(s, 256, "dumpout (plugininfo, paraminfo, paramoption, paramchanged, ...)");
    }
}

static void* max_ffgl_new(t_symbol*, long argc, t_atom* argv) {
    t_max_jit_gl_ffgl* x = (t_max_jit_gl_ffgl*)max_jit_object_alloc(s_max_class, gensym("jit_gl_ffgl"));
    if (!x) return nullptr;
    long attrstart = max_jit_attr_args_offset(argc, argv);
    t_symbol* dest = _jit_sym_nothing;
    if (attrstart && argv) jit_atom_arg_getsym(&dest, 0, attrstart, argv);

    void* jo = jit_object_new(gensym("jit_gl_ffgl"), dest);
    if (!jo) {
        object_error((t_object*)x, "jit.gl.ffgl: could not allocate object");
        freeobject((t_object*)x);
        return nullptr;
    }
    max_jit_obex_jitob_set(x, jo);
    x->dumpout = outlet_new(x, nullptr);
    max_jit_obex_dumpout_set(x, x->dumpout);
    x->texout = outlet_new(x, "jit_gl_texture");
    max_jit_ob3d_attach(x, (t_jit_object*)jo, x->texout);

    // @plugin must be applied before the plugin's own attributes exist, and
    // max_jit_attr_args applies attributes left to right, so `@plugin X @phase 1` works.
    max_jit_attr_args(x, argc, argv);
    return x;
}

static void max_ffgl_free(t_max_jit_gl_ffgl* x) {
    max_jit_ob3d_detach(x);
    if (max_jit_obex_jitob_get(x)) jit_object_free(max_jit_obex_jitob_get(x));
    max_jit_object_free(x);
}

extern "C" void ext_main(void*) {
    ffgl_host::setLogger(logToMax);
    jit_gl_ffgl_init();

    t_class* c = class_new("jit.gl.ffgl", (method)max_ffgl_new, (method)max_ffgl_free,
                           sizeof(t_max_jit_gl_ffgl), nullptr, A_GIMME, 0);
    max_jit_class_obex_setup(c, calcoffset(t_max_jit_gl_ffgl, obex));
    t_class* jc = (t_class*)jit_class_findbyname(gensym("jit_gl_ffgl"));
    max_jit_class_wrap_standard(c, jc, 0);
    max_jit_class_ob3d_wrap(c);

    // registered after the ob3d wrap so they take precedence over its bang / draw
    class_addmethod(c, (method)max_ffgl_bang, "bang", 0);
    class_addmethod(c, (method)max_ffgl_draw, "draw", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_texture, "jit_gl_texture", A_SYM, 0);
    class_addmethod(c, (method)max_ffgl_input, "input", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_load, "load", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_reload, "reload", 0);
    class_addmethod(c, (method)max_ffgl_params, "params", 0);
    class_addmethod(c, (method)max_ffgl_plugins, "plugins", 0);
    class_addmethod(c, (method)max_ffgl_searchpath, "searchpath", A_SYM, 0);
    class_addmethod(c, (method)max_ffgl_param, "param", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_paramn, "paramn", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_getparam, "getparam", A_GIMME, 0);
    class_addmethod(c, (method)max_ffgl_assist, "assist", A_CANT, 0);

    class_register(CLASS_BOX, c);
    s_max_class = c;
}

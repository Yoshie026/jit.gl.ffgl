// ffgl_host.mm — see ffgl_host.h
#define GL_SILENCE_DEPRECATION 1

#include "ffgl_host.h"

#include "FFGL.h"  // pulls in <OpenGL/gl3.h>

#import <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOReturn.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/OpenGL.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <map>
#include <mutex>
#include <set>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace ffgl_host {

// ---------------------------------------------------------------------------
// logging
// ---------------------------------------------------------------------------

namespace {

std::mutex g_logMutex;
std::function<void(const std::string&)> g_logger;

void logMsg(const std::string& s) {
    std::function<void(const std::string&)> fn;
    {
        std::lock_guard<std::mutex> lk(g_logMutex);
        fn = g_logger;
    }
    if (fn) fn(s);
    else std::fprintf(stderr, "[ffgl_host] %s\n", s.c_str());
}

void pluginLogCallback(char* s) {
    if (s) logMsg(std::string("plugin: ") + s);
}

// On arm64 macOS every heap pointer is above the 4 GiB __PAGEZERO, whereas an
// FFMixed carrying FF_FAIL only fills the low 32 bits. That makes this a safe
// way to tell "pointer" from "error code" in a return value.
bool validPtr(const void* p) { return reinterpret_cast<uintptr_t>(p) > 0xFFFFFFFFull; }

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
    return s;
}

std::string safeString(const char* p, size_t maxLen = 256) {
    if (!validPtr(p)) return {};
    return std::string(p, strnlen(p, maxLen));
}

float bitsToFloat(uint32_t u) {
    float f;
    std::memcpy(&f, &u, sizeof f);
    return f;
}
uint32_t floatToBits(float f) {
    uint32_t u;
    std::memcpy(&u, &f, sizeof u);
    return u;
}

}  // namespace

void setLogger(std::function<void(const std::string&)> fn) {
    std::lock_guard<std::mutex> lk(g_logMutex);
    g_logger = std::move(fn);
}

// ---------------------------------------------------------------------------
// private GL context
// ---------------------------------------------------------------------------

namespace {

struct Engine {
    NSOpenGLContext* nsContext = nil;  // keeps the context alive (ARC)
    CGLContextObj ctx = nullptr;
    std::recursive_mutex mtx;
    std::string info;
    std::string error;

    static Engine& get() {
        // Intentionally leaked: plugin teardown at process exit must not race
        // with static destruction of the context.
        static Engine* e = new Engine();
        return *e;
    }

    bool ensure() {
        if (ctx) return true;
        if (!error.empty()) return false;
        // NSOpenGLContext rather than a bare CGL context: plugins commonly ask
        // [NSOpenGLContext currentContext] (e.g. to build a CVOpenGLTextureCache),
        // which is nil for contexts created straight through CGL.
        for (NSOpenGLPixelFormatAttribute prof :
             {(NSOpenGLPixelFormatAttribute)NSOpenGLProfileVersion4_1Core,
              (NSOpenGLPixelFormatAttribute)NSOpenGLProfileVersion3_2Core}) {
            NSOpenGLPixelFormatAttribute attrs[] = {
                NSOpenGLPFAAccelerated, NSOpenGLPFAOpenGLProfile, prof,
                NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8,
                NSOpenGLPFADepthSize, 24, 0};
            NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
            if (!pf) continue;
            NSOpenGLContext* c = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil];
            if (!c) continue;
            nsContext = c;
            ctx = c.CGLContextObj;
            break;
        }
        if (!ctx) {
            error = "could not create an OpenGL 3.2/4.1 core-profile context";
            return false;
        }
        CGLContextObj prev = CGLGetCurrentContext();
        CGLSetCurrentContext(ctx);
        info = std::string((const char*)glGetString(GL_RENDERER)) + " / OpenGL " +
               (const char*)glGetString(GL_VERSION);
        CGLSetCurrentContext(prev);
        return true;
    }
};

// Serialises all plugin access and makes the private context current for the
// scope, restoring whatever the calling thread had (Jitter's context).
struct ScopedContext {
    std::unique_lock<std::recursive_mutex> lock;
    CGLContextObj prev;
    bool ok;
    ScopedContext() : lock(Engine::get().mtx), prev(CGLGetCurrentContext()) {
        ok = Engine::get().ensure();
        if (ok) CGLSetCurrentContext(Engine::get().ctx);
    }
    ~ScopedContext() {
        if (ok) glFlush();
        CGLSetCurrentContext(prev);
    }
};

// Put the private context back to a known baseline before handing it to a
// plugin, so one plugin's leftovers never affect the next call.
void sanitizeState() {
    glBindVertexArray(0);
    glUseProgram(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glDepthMask(GL_TRUE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
}

}  // namespace

std::string glInfo() {
    ScopedContext sc;
    return sc.ok ? Engine::get().info : Engine::get().error;
}

// ---------------------------------------------------------------------------
// plugin discovery
// ---------------------------------------------------------------------------

namespace {
std::mutex g_pathMutex;
std::vector<std::string> g_extraPaths;

std::string homeDir() {
    const char* h = getenv("HOME");
    return h ? h : "";
}
}  // namespace

void addSearchPath(const std::string& dir) {
    std::lock_guard<std::mutex> lk(g_pathMutex);
    if (std::find(g_extraPaths.begin(), g_extraPaths.end(), dir) == g_extraPaths.end())
        g_extraPaths.push_back(dir);
}

std::vector<std::string> searchPaths() {
    std::vector<std::string> v;
    {
        std::lock_guard<std::mutex> lk(g_pathMutex);
        v = g_extraPaths;
    }
    const std::string home = homeDir();
    const char* fixed[] = {
        "/Library/Graphics/FreeFrame Plug-Ins",
        "/Library/Application Support/FreeFrame",
    };
    for (auto* p : fixed) v.push_back(p);
    if (!home.empty()) {
        v.push_back(home + "/Library/Graphics/FreeFrame Plug-Ins");
        v.push_back(home + "/Library/Graphics/FreeFrame");
        v.push_back(home + "/Documents/Resolume Arena/Extra Effects");
        v.push_back(home + "/Documents/Resolume Avenue/Extra Effects");
        v.push_back(home + "/Documents/Resolume Wire/Extra Effects");
    }
    return v;
}

std::vector<FoundPlugin> scanPlugins() {
    std::vector<FoundPlugin> out;
    std::set<std::string> seen;
    for (auto& dir : searchPaths()) {
        std::error_code ec;
        if (!fs::is_directory(dir, ec)) continue;
        for (auto& e : fs::directory_iterator(dir, ec)) {
            if (e.path().extension() != ".bundle") continue;
            if (!fs::is_directory(e.path() / "Contents" / "MacOS", ec)) continue;
            std::string p = e.path().string();
            if (seen.insert(p).second) out.push_back({e.path().stem().string(), p});
        }
    }
    return out;
}

std::string resolvePlugin(const std::string& nameOrPath) {
    if (nameOrPath.empty()) return {};
    std::error_code ec;
    auto isBundle = [&](const fs::path& p) {
        return fs::is_directory(p / "Contents" / "MacOS", ec);
    };
    fs::path p(nameOrPath);
    if (p.is_absolute()) {
        if (isBundle(p)) return p.string();
        if (isBundle(p.string() + ".bundle")) return p.string() + ".bundle";
        return {};
    }
    std::string want = lower(p.extension() == ".bundle" ? p.stem().string() : p.string());
    for (auto& f : scanPlugins())
        if (lower(f.name) == want) return f.path;
    return {};
}

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

struct Module::Impl {
    CFBundleRef bundle = nullptr;
    FF_Main_FuncPtr main = nullptr;
    bool initialised = false;

    FFMixed call(FFUInt32 code, FFMixed in, FFInstanceID inst = nullptr) const {
        return main(code, in, inst);
    }
    FFMixed callU(FFUInt32 code, FFUInt32 v, FFInstanceID inst = nullptr) const {
        FFMixed m;
        std::memset(&m, 0, sizeof m);
        m.UIntValue = v;
        return main(code, m, inst);
    }
    FFMixed callP(FFUInt32 code, void* p, FFInstanceID inst = nullptr) const {
        FFMixed m;
        m.PointerValue = p;
        return main(code, m, inst);
    }
};

namespace {
std::mutex g_moduleMutex;
std::map<std::string, std::weak_ptr<Module>> g_modules;

ParamKind kindFor(uint32_t t) {
    switch (t) {
        case FF_TYPE_BOOLEAN: return ParamKind::Boolean;
        case FF_TYPE_EVENT: return ParamKind::Event;
        case FF_TYPE_TEXT: return ParamKind::Text;
        case FF_TYPE_FILE: return ParamKind::File;
        case FF_TYPE_OPTION: return ParamKind::Option;
        case FF_TYPE_INTEGER: return ParamKind::Integer;
        case FF_TYPE_BUFFER: return ParamKind::Buffer;
        default: return ParamKind::Float;
    }
}
}  // namespace

namespace {
// ---------------------------------------------------------------------------
// Per-plugin compatibility rules (optional).
//
// Some plugins run a local server on a range of consecutive ports and bind it on the wildcard
// address. Something else already listening on 127.0.0.1:<port> (Max's own "Max Search Helper"
// holds 8088) still lets that wildcard bind succeed, but a client connecting to localhost:<port>
// then reaches the OTHER process. A rule can ask the host to count how many ports are actually
// free before the plugin loads and hand the plugin a smaller count through an environment
// variable it reads at start-up. Rules are JSON files in
//   $FFGL_COMPAT_DIR  or  ~/Library/Application Support/ffgl_for_max/compat/
// and look like (see docs/compat-example.json):
//   { "plugins": ["MyPlugin", "MyFamily*"],
//     "port_guard": { "base_port_env": "MY_PORT", "default_base_port": 8081, "lanes": 8,
//                     "limit_env": "MY_LANES" } }
// Lanes are the `lanes` ports above the base port. A value the user already set in
// `limit_env` is left alone. Each rule is applied once per process.
// ---------------------------------------------------------------------------
bool loopbackPortInUse(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    const bool used = connect(fd, (sockaddr*)&a, sizeof a) == 0;
    close(fd);
    return used;
}

bool ruleMatches(const std::string& pattern, const std::string& name) {
    const std::string p = lower(pattern), n = lower(name);
    if (!p.empty() && p.back() == '*') return n.compare(0, p.size() - 1, p, 0, p.size() - 1) == 0;
    return p == n;
}

void applyPortGuard(NSDictionary* g) {
    NSString* limitEnv = g[@"limit_env"];
    if (![limitEnv isKindOfClass:[NSString class]] || getenv(limitEnv.UTF8String)) return;
    int base = [g[@"default_base_port"] intValue];
    if (NSString* baseEnv = g[@"base_port_env"])
        if (const char* v = getenv(baseEnv.UTF8String); v && atoi(v) > 0) base = atoi(v);
    const int lanes = std::clamp([g[@"lanes"] intValue], 1, 64);
    if (base <= 0) return;
    int free = 0;
    while (free < lanes && !loopbackPortInUse(base + 1 + free)) ++free;
    if (free < lanes) {
        char v[8];
        std::snprintf(v, sizeof v, "%d", std::max(1, free));
        setenv(limitEnv.UTF8String, v, 0);
        logMsg("port " + std::to_string(base + 1 + free) + " is already in use on 127.0.0.1: setting " +
               limitEnv.UTF8String + "=" + v);
    }
}

void applyCompatRules(const std::string& bundlePath) {
    static std::mutex m;
    static std::set<std::string> applied;
    const std::string name = std::filesystem::path(bundlePath).stem().string();
    std::string dir;
    if (const char* d = getenv("FFGL_COMPAT_DIR")) dir = d;
    else if (!homeDir().empty()) dir = homeDir() + "/Library/Application Support/ffgl_for_max/compat";
    std::error_code ec;
    if (dir.empty() || !std::filesystem::is_directory(dir, ec)) return;
    std::lock_guard<std::mutex> lk(m);
    for (auto& e : std::filesystem::directory_iterator(dir, ec)) {
        if (e.path().extension() != ".json" || applied.count(e.path().string())) continue;
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:e.path().c_str()]];
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![root isKindOfClass:[NSDictionary class]]) continue;
        bool match = false;
        for (id pat in (NSArray*)([root[@"plugins"] isKindOfClass:[NSArray class]] ? root[@"plugins"] : @[]))
            if ([pat isKindOfClass:[NSString class]] && ruleMatches([pat UTF8String], name)) match = true;
        if (!match) continue;
        applied.insert(e.path().string());
        if ([root[@"port_guard"] isKindOfClass:[NSDictionary class]]) applyPortGuard(root[@"port_guard"]);
    }
}

}  // namespace

std::shared_ptr<Module> Module::open(const std::string& nameOrPath, std::string& error) {
    std::string path = resolvePlugin(nameOrPath);
    if (path.empty()) {
        error = "FFGL plugin not found: " + nameOrPath;
        return nullptr;
    }
    std::lock_guard<std::mutex> cacheLock(g_moduleMutex);
    if (auto it = g_modules.find(path); it != g_modules.end())
        if (auto m = it->second.lock()) return m;

    ScopedContext sc;
    if (!sc.ok) {
        error = Engine::get().error;
        return nullptr;
    }

    std::shared_ptr<Module> mod(new Module());
    applyCompatRules(path);
    mod->impl_.reset(new Impl());
    Impl& I = *mod->impl_;

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, (const UInt8*)path.c_str(), (CFIndex)path.size(), true);
    I.bundle = url ? CFBundleCreate(nullptr, url) : nullptr;
    if (url) CFRelease(url);
    if (!I.bundle) {
        error = "not a loadable bundle: " + path;
        return nullptr;
    }
    CFErrorRef cfErr = nullptr;
    if (!CFBundleLoadExecutableAndReturnError(I.bundle, &cfErr)) {
        error = "could not load bundle executable: " + path;
        if (cfErr) {
            char buf[512] = {0};
            CFStringRef d = CFErrorCopyDescription(cfErr);
            if (d) {
                CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8);
                CFRelease(d);
                error += std::string(" (") + buf + ")";
            }
            CFRelease(cfErr);
        }
        CFRelease(I.bundle);
        I.bundle = nullptr;
        return nullptr;
    }
    I.main = (FF_Main_FuncPtr)CFBundleGetFunctionPointerForName(I.bundle, CFSTR("plugMain"));
    if (!I.main) {
        error = "bundle has no plugMain export (is it an FFGL plugin?): " + path;
        return nullptr;
    }
    if (auto setLog = (FF_SetLogCallback_FuncPtr)CFBundleGetFunctionPointerForName(
            I.bundle, CFSTR("SetLogCallback")))
        setLog(&pluginLogCallback);

    // --- info ---
    PluginInfo& info = mod->info_;
    info.path = path;
    if (auto* pi = (PluginInfoStruct*)I.callU(FF_GET_INFO, 0).PointerValue; validPtr(pi)) {
        info.apiMajor = pi->APIMajorVersion;
        info.apiMinor = pi->APIMinorVersion;
        info.id = std::string(pi->PluginUniqueID, strnlen(pi->PluginUniqueID, 4));
        info.name = std::string(pi->PluginName, strnlen(pi->PluginName, 16));
        info.type = pi->PluginType;
    } else {
        error = "plugin did not answer FF_GET_INFO: " + path;
        return nullptr;
    }
    if (info.apiMajor < 2) {
        error = "FFGL " + std::to_string(info.apiMajor) + "." + std::to_string(info.apiMinor) +
                " plugins are not supported yet (need an OpenGL legacy context): " + path;
        return nullptr;
    }
    if (I.callU(FF_INITIALISE_V2, 0).UIntValue == FF_FAIL) {
        error = "plugin refused FF_INITIALISE_V2: " + path;
        return nullptr;
    }
    I.initialised = true;

    if (auto* ext = (PluginExtendedInfoStruct*)I.callU(FF_GET_EXTENDED_INFO, 0).PointerValue; validPtr(ext)) {
        info.description = safeString(ext->Description, 1024);
        info.about = safeString(ext->About, 1024);
    }
    info.wantsTime = I.callU(FF_GET_PLUGIN_CAPS, FF_CAP_SET_TIME).UIntValue == FF_SUPPORTED;
    {
        FFUInt32 minIn = I.callU(FF_GET_PLUGIN_CAPS, FF_CAP_MINIMUM_INPUT_FRAMES).UIntValue;
        if (minIn > 8) minIn = info.type == FF_SOURCE ? 0 : info.type == FF_MIXER ? 2 : 1;
        info.numInputs = minIn;
    }

    // --- parameters (prototype level: instance id 0) ---
    FFUInt32 n = I.callU(FF_GET_NUM_PARAMETERS, 0).UIntValue;
    if (n > 4096) n = 0;
    for (FFUInt32 i = 0; i < n; ++i) {
        ParamInfo p;
        p.index = i;
        p.name = safeString((const char*)I.callU(FF_GET_PARAMETER_NAME, i).PointerValue, 128);
        if (p.name.empty()) p.name = "param" + std::to_string(i);
        p.displayName = p.name;
        p.ffType = I.callU(FF_GET_PARAMETER_TYPE, i).UIntValue;
        p.kind = kindFor(p.ffType);

        FFMixed def = I.callU(FF_GET_PARAMETER_DEFAULT, i);
        if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
            p.defText = safeString((const char*)def.PointerValue, 4096);
        else
            p.def = bitsToFloat(def.UIntValue);

        if (p.kind == ParamKind::Float || p.kind == ParamKind::Integer) {
            GetRangeStruct r{};
            r.parameterNumber = i;
            r.range = {0.f, 1.f};
            if (I.callP(FF_GET_RANGE, &r).UIntValue != FF_FAIL && r.range.max > r.range.min) {
                p.min = r.range.min;
                p.max = r.range.max;
            }
        }
        {
            char buf[128] = {0};
            GetStringStruct gs{};
            gs.parameterNumber = i;
            gs.stringBuffer.address = buf;
            gs.stringBuffer.maxToWrite = sizeof buf - 1;
            if (I.callP(FF_GET_PARAM_GROUP, &gs).UIntValue != FF_FAIL) p.group = buf;
        }
        if (p.kind == ParamKind::Option) {
            FFUInt32 ne = I.callU(FF_GET_NUM_PARAMETER_ELEMENTS, i).UIntValue;
            if (ne > 4096) ne = 0;
            for (FFUInt32 e = 0; e < ne; ++e) {
                GetParameterElementNameStruct ns{i, e};
                GetParameterElementValueStruct vs{i, e};
                Option o;
                o.name = safeString((const char*)I.callP(FF_GET_PARAMETER_ELEMENT_NAME, &ns).PointerValue, 128);
                if (o.name.empty()) o.name = std::to_string(e);
                FFMixed v = I.callP(FF_GET_PARAMETER_ELEMENT_VALUE, &vs);
                o.value = v.UIntValue == FF_FAIL ? (float)e : bitsToFloat(v.UIntValue);
                p.options.push_back(std::move(o));
            }
        }
        mod->params_.push_back(std::move(p));
    }

    g_modules[path] = mod;
    return mod;
}

Module::~Module() {
    if (!impl_) return;
    {
        std::lock_guard<std::mutex> lk(g_moduleMutex);
        auto it = g_modules.find(info_.path);
        if (it != g_modules.end() && it->second.expired()) g_modules.erase(it);
    }
    ScopedContext sc;
    if (impl_->initialised && impl_->main) impl_->callU(FF_DEINITIALISE, 0);
    // The bundle is deliberately not unloaded: plugins that spawned threads or
    // registered atexit handlers crash if their code disappears under them.
}

int Module::findParam(const std::string& name) const {
    const std::string w = lower(name);
    for (auto& p : params_)
        if (lower(p.name) == w) return (int)p.index;
    for (auto& p : params_)
        if (lower(p.displayName) == w) return (int)p.index;
    return -1;
}

// ---------------------------------------------------------------------------
// Instance
// ---------------------------------------------------------------------------

namespace {

IOSurfaceRef makeSurface(uint32_t w, uint32_t h) {
    const int bpe = 4;
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * bpe);
    size_t alloc = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr * h);
    int iw = (int)w, ih = (int)h, ibpe = bpe;
    int ipf = 'BGRA';
    long ibpr = (long)bpr, ialloc = (long)alloc;
    CFNumberRef nw = CFNumberCreate(nullptr, kCFNumberIntType, &iw);
    CFNumberRef nh = CFNumberCreate(nullptr, kCFNumberIntType, &ih);
    CFNumberRef nb = CFNumberCreate(nullptr, kCFNumberIntType, &ibpe);
    CFNumberRef np = CFNumberCreate(nullptr, kCFNumberIntType, &ipf);
    CFNumberRef nr = CFNumberCreate(nullptr, kCFNumberLongType, &ibpr);
    CFNumberRef na = CFNumberCreate(nullptr, kCFNumberLongType, &ialloc);
    const void* keys[] = {kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement,
                          kIOSurfacePixelFormat, kIOSurfaceBytesPerRow, kIOSurfaceAllocSize};
    const void* vals[] = {nw, nh, nb, np, nr, na};
    CFDictionaryRef d = CFDictionaryCreate(nullptr, keys, vals, 6, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d);
    for (CFNumberRef n : {nw, nh, nb, np, nr, na}) CFRelease(n);
    return s;
}

struct Tex2D {
    GLuint tex = 0, fbo = 0;
    void make(uint32_t w, uint32_t h) {
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)w, (GLsizei)h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, 0);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    }
    void destroy() {
        if (fbo) glDeleteFramebuffers(1, &fbo);
        if (tex) glDeleteTextures(1, &tex);
        fbo = tex = 0;
    }
};

// A rectangle texture living on an IOSurface, plus an FBO to blit through.
struct SurfaceTex {
    GLuint tex = 0, fbo = 0;
    bool make(IOSurfaceRef s, uint32_t w, uint32_t h) {
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_RECTANGLE, tex);
        CGLError err = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, GL_RGBA8,
                                              (GLsizei)w, (GLsizei)h, GL_BGRA,
                                              GL_UNSIGNED_INT_8_8_8_8_REV, s, 0);
        glBindTexture(GL_TEXTURE_RECTANGLE, 0);
        if (err != kCGLNoError) return false;
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, tex, 0);
        return true;
    }
    void destroy() {
        if (fbo) glDeleteFramebuffers(1, &fbo);
        if (tex) glDeleteTextures(1, &tex);
        fbo = tex = 0;
    }
};

void blit(GLuint srcFbo, GLuint dstFbo, uint32_t w, uint32_t h) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, srcFbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dstFbo);
    glBlitFramebuffer(0, 0, (GLint)w, (GLint)h, 0, 0, (GLint)w, (GLint)h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
}


}  // namespace

struct Instance::Impl {
    FFInstanceID id = nullptr;
    uint32_t w = 0, h = 0;
    uint64_t generation = 0;
    uint64_t frames = 0;

    std::vector<IOSurfaceRef> inSurfaces;
    IOSurfaceRef outSurface = nullptr;
    std::vector<SurfaceTex> inRect;
    std::vector<Tex2D> inTex;
    std::vector<FFGLTextureStruct> inStructs;
    SurfaceTex outRect;
    Tex2D outTex;
    GLuint depthRb = 0;

    // param state (cache + pending writes), guarded by pmtx
    mutable std::mutex pmtx;
    std::vector<float> fvals;
    std::vector<std::string> tvals;
    std::vector<ParamInfo> live;  // per-instance copy: visibility / display names change
    struct Pending { bool isText; float f; std::string s; };
    std::map<uint32_t, Pending> pending;
    std::set<uint32_t> triggers;
    float bpm = 120.f, phase = 0.f;
    bool beatDirty = true;
    bool hostInfoSent = false;
    std::atomic<int> inputTarget{(int)InputTarget::Texture2D};

    // FFGL_GPUTIME=1: per-stage GPU time. Apple's GL driver returns zeros for GL_TIME_ELAPSED, so this
    // brackets each stage with glFinish and reads the wall clock. It serialises the pipeline: a
    // benchmark aid only, never for real-time use.
    struct GpuTimer {
        static constexpr int kStages = 3;  // input copy / plugin / output copy
        using Clock = std::chrono::steady_clock;
        Clock::time_point t0;
        double sumMs[kStages] = {};
        uint64_t frame = 0;
        int cur = 0;
        bool active = false;
        void begin(int st) {
            if (!active) return;
            glFinish();
            cur = st;
            t0 = Clock::now();
        }
        void end() {
            if (!active) return;
            glFinish();
            sumMs[cur] += std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        }
        void collect(const std::string& name, uint32_t w, uint32_t h) {
            if (!active || ++frame % 300) return;
            static const char* names[kStages] = {"input copy", "plugin", "output copy"};
            std::string msg = "GPU " + name + " " + std::to_string(w) + "x" + std::to_string(h) + " (per frame):";
            double tot = 0;
            for (int st = 0; st < kStages; ++st) {
                char b[96];
                std::snprintf(b, sizeof b, "  %s %.3f ms", names[st], sumMs[st] / 300.0);
                msg += b;
                tot += sumMs[st] / 300.0;
                sumMs[st] = 0;
            }
            char b[64];
            std::snprintf(b, sizeof b, "  | total %.3f ms", tot);
            logMsg(msg + b);
        }
    } gpu;

    bool createResources(const Module::Impl& M, uint32_t width, uint32_t height, uint32_t nIn) {
        w = width;
        h = height;
        ++generation;
        outSurface = makeSurface(w, h);
        if (!outSurface) return false;
        for (uint32_t i = 0; i < nIn; ++i) {
            IOSurfaceRef s = makeSurface(w, h);
            if (!s) return false;
            inSurfaces.push_back(s);
        }
        inRect.assign(nIn, {});
        inTex.assign(nIn, {});
        inStructs.assign(nIn, {});
        for (uint32_t i = 0; i < nIn; ++i) {
            if (!inRect[i].make(inSurfaces[i], w, h)) return false;
            // Padded by one texel each way: the reported HardwareWidth/Height exceed Width/Height
            // like on classic NPOT-padding FFGL hosts. Plugins that scale texcoords by
            // Width/HardwareWidth stay exact, and plugins that pick GL_TEXTURE_2D only when
            // Hardware > Width take their 2D path. The padding is cleared once and never written.
            inTex[i].make(w + 1, h + 1);
            glClearColor(0.f, 0.f, 0.f, 0.f);
            glClear(GL_COLOR_BUFFER_BIT);
            inStructs[i] = FFGLTextureStruct{w, h, w + 1, h + 1, inTex[i].tex};
        }
        if (!outRect.make(outSurface, w, h)) return false;
        outTex.make(w, h);
        glGenRenderbuffers(1, &depthRb);
        glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, (GLsizei)w, (GLsizei)h);
        glBindFramebuffer(GL_FRAMEBUFFER, outTex.fbo);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRb);
        bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        (void)M;
        return ok;
    }

    void destroyResources() {
        for (auto& t : inRect) t.destroy();
        for (auto& t : inTex) t.destroy();
        inRect.clear();
        inTex.clear();
        inStructs.clear();
        outRect.destroy();
        outTex.destroy();
        if (depthRb) glDeleteRenderbuffers(1, &depthRb);
        depthRb = 0;
        for (auto s : inSurfaces) CFRelease(s);
        inSurfaces.clear();
        if (outSurface) CFRelease(outSurface);
        outSurface = nullptr;
    }
};

std::unique_ptr<Instance> Instance::create(std::shared_ptr<Module> module, uint32_t width,
                                           uint32_t height, std::string& error) {
    if (!module) {
        error = "no module";
        return nullptr;
    }
    width = std::max(1u, width);
    height = std::max(1u, height);
    ScopedContext sc;
    if (!sc.ok) {
        error = Engine::get().error;
        return nullptr;
    }
    sanitizeState();

    std::unique_ptr<Instance> inst(new Instance());
    inst->module_ = module;
    inst->impl_.reset(new Instance::Impl());
    Impl& S = *inst->impl_;
    const Module::Impl& M = *module->impl_;

    FFGLViewportStruct vp{0, 0, width, height};
    FFMixed r = M.callP(FF_INSTANTIATE_GL, &vp);
    if (r.UIntValue == FF_FAIL || !validPtr(r.PointerValue)) {
        // On arm64 a valid instance id is a heap pointer; FF_FAIL only fills 32 bits.
        error = "FF_INSTANTIATE_GL failed for " + module->info().name;
        return nullptr;
    }
    S.id = r.PointerValue;

    if (!S.createResources(M, width, height, module->info().numInputs)) {
        error = "could not create GL / IOSurface resources";
        S.destroyResources();
        M.callP(FF_DEINSTANTIATE_GL, nullptr, S.id);
        return nullptr;
    }
    M.callP(FF_RESIZE, &vp, S.id);

    S.live = module->params();
    S.fvals.resize(S.live.size());
    S.tvals.resize(S.live.size());
    for (auto& p : S.live) {
        S.fvals[p.index] = p.def;
        S.tvals[p.index] = p.defText;
        // instance-level display names + visibility (FFGL 2.1)
        char buf[128] = {0};
        GetStringStruct gs{};
        gs.parameterNumber = p.index;
        gs.stringBuffer.address = buf;
        gs.stringBuffer.maxToWrite = sizeof buf - 1;
        if (M.callP(FF_GET_PARAM_DISPLAY_NAME, &gs, S.id).UIntValue != FF_FAIL && buf[0])
            p.displayName = buf;
        FFUInt32 vis = M.callU(FF_GET_PRAMETER_VISIBILITY, p.index, S.id).UIntValue;
        p.visible = vis != 0 && vis != FF_FAIL;
        if (vis == FF_FAIL) p.visible = true;
    }
    return inst;
}

Instance::~Instance() {
    if (!impl_ || !module_) return;
    ScopedContext sc;
    if (sc.ok) {
        sanitizeState();
        impl_->destroyResources();
    }
    if (impl_->id) module_->impl_->callP(FF_DEINSTANTIATE_GL, nullptr, impl_->id);
}

uint32_t Instance::width() const { return impl_->w; }
uint32_t Instance::height() const { return impl_->h; }
uint32_t Instance::numInputs() const { return (uint32_t)impl_->inSurfaces.size(); }
IOSurfaceRef Instance::inputSurface(uint32_t i) const {
    return i < impl_->inSurfaces.size() ? impl_->inSurfaces[i] : nullptr;
}
IOSurfaceRef Instance::outputSurface() const { return impl_->outSurface; }
uint64_t Instance::surfaceGeneration() const { return impl_->generation; }
uint64_t Instance::framesRendered() const { return impl_->frames; }

bool Instance::resize(uint32_t width, uint32_t height) {
    width = std::max(1u, width);
    height = std::max(1u, height);
    if (width == impl_->w && height == impl_->h) return true;
    ScopedContext sc;
    if (!sc.ok) return false;
    sanitizeState();
    const uint32_t nIn = (uint32_t)impl_->inSurfaces.size();
    impl_->destroyResources();
    if (!impl_->createResources(*module_->impl_, width, height, nIn)) return false;
    FFGLViewportStruct vp{0, 0, width, height};
    module_->impl_->callP(FF_RESIZE, &vp, impl_->id);
    return true;
}

void Instance::setFloat(uint32_t index, float value) {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    if (index >= impl_->fvals.size()) return;
    impl_->fvals[index] = value;
    impl_->pending[index] = {false, value, {}};
}
void Instance::setText(uint32_t index, const std::string& value) {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    if (index >= impl_->tvals.size()) return;
    impl_->tvals[index] = value;
    impl_->pending[index] = {true, 0.f, value};
}
void Instance::trigger(uint32_t index) {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    if (index < impl_->fvals.size()) impl_->triggers.insert(index);
}
float Instance::floatValue(uint32_t index) const {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    return index < impl_->fvals.size() ? impl_->fvals[index] : 0.f;
}
std::string Instance::textValue(uint32_t index) const {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    return index < impl_->tvals.size() ? impl_->tvals[index] : std::string();
}
bool Instance::visible(uint32_t index) const {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    return index < impl_->live.size() ? impl_->live[index].visible : true;
}
std::string Instance::displayName(uint32_t index) const {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    return index < impl_->live.size() ? impl_->live[index].displayName : std::string();
}
void Instance::setInputTarget(InputTarget t) { impl_->inputTarget.store((int)t); }
InputTarget Instance::inputTarget() const { return (InputTarget)impl_->inputTarget.load(); }
void Instance::setBeat(float bpm, float barPhase) {
    std::lock_guard<std::mutex> lk(impl_->pmtx);
    impl_->bpm = bpm;
    impl_->phase = barPhase;
    impl_->beatDirty = true;
}

bool Instance::render(double timeSeconds, bool clear, std::vector<ParamEvent>* events) {
    Impl& S = *impl_;
    const Module::Impl& M = *module_->impl_;
    ScopedContext sc;
    if (!sc.ok) return false;
    sanitizeState();
    if (!S.hostInfoSent) S.gpu.active = std::getenv("FFGL_GPUTIME") != nullptr;

    if (!S.hostInfoSent) {
        SetHostinfoStruct hi{"Max/MSP Jitter", "1.0"};
        M.callP(FF_SET_HOSTINFO, &hi, S.id);
        S.hostInfoSent = true;
    }

    // 1. flush queued parameter writes into the plugin, now that its context is current
    {
        std::map<uint32_t, Impl::Pending> pend;
        std::set<uint32_t> trig;
        float bpm, phase;
        bool beatDirty;
        {
            std::lock_guard<std::mutex> lk(S.pmtx);
            pend.swap(S.pending);
            trig.swap(S.triggers);
            bpm = S.bpm;
            phase = S.phase;
            beatDirty = S.beatDirty;
            S.beatDirty = false;
        }
        for (auto& [idx, p] : pend) {
            SetParameterStruct sps;
            std::memset(&sps, 0, sizeof sps);
            sps.ParameterNumber = idx;
            if (p.isText) sps.NewParameterValue.PointerValue = (void*)p.s.c_str();
            else sps.NewParameterValue.UIntValue = floatToBits(p.f);
            M.callP(FF_SET_PARAMETER, &sps, S.id);
        }
        for (uint32_t idx : trig) {
            // events are edge-triggered: 1 then back to 0
            for (float v : {1.f, 0.f}) {
                SetParameterStruct sps;
                std::memset(&sps, 0, sizeof sps);
                sps.ParameterNumber = idx;
                sps.NewParameterValue.UIntValue = floatToBits(v);
                M.callP(FF_SET_PARAMETER, &sps, S.id);
            }
        }
        if (beatDirty) {
            SetBeatinfoStruct bi{bpm, phase};
            M.callP(FF_SET_BEATINFO, &bi, S.id);
        }
    }
    if (module_->info().wantsTime) {
        // FFGL.h documents seconds, but real hosts (Resolume) pass MILLISECONDS and plugins
        // rely on it (the SDK's own Particles plugin does hostTime / 1000).
        double t = timeSeconds * 1000.0;
        M.callP(FF_SET_TIME, &t, S.id);
    }

    // 2. IOSurface (rect) -> plain 2D textures the plugin can sample
    std::vector<FFGLTextureStruct*> ptrs;
    S.gpu.begin(0);
    for (size_t i = 0; i < S.inRect.size(); ++i) {
        blit(S.inRect[i].fbo, S.inTex[i].fbo, S.w, S.h);
        const bool rectIn = S.inputTarget.load() == (int)InputTarget::Rectangle;
        S.inStructs[i].Handle = rectIn ? S.inRect[i].tex : S.inTex[i].tex;
        S.inStructs[i].HardwareWidth = rectIn ? S.w : S.w + 1;
        S.inStructs[i].HardwareHeight = rectIn ? S.h : S.h + 1;
        ptrs.push_back(&S.inStructs[i]);
    }
    S.gpu.end();

    // 3. run the plugin into its own FBO
    glBindFramebuffer(GL_FRAMEBUFFER, S.outTex.fbo);
    glViewport(0, 0, (GLsizei)S.w, (GLsizei)S.h);
    if (clear) {
        glClearColor(0.f, 0.f, 0.f, 0.f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
    ProcessOpenGLStruct pogl;
    pogl.numInputTextures = (FFUInt32)ptrs.size();
    pogl.inputTextures = ptrs.empty() ? nullptr : ptrs.data();
    pogl.HostFBO = S.outTex.fbo;
    S.gpu.begin(1);
    FFUInt32 rc = M.callP(FF_PROCESS_OPENGL, &pogl, S.id).UIntValue;
    S.gpu.end();  // (a plugin that leaves its own query active would make this a no-op error; harmless)

    // whatever the plugin did, put the context back in order before we blit
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    sanitizeState();
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    // 4. result -> IOSurface for the caller
    S.gpu.begin(2);
    blit(S.outTex.fbo, S.outRect.fbo, S.w, S.h);
    S.gpu.end();
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glFlush();
    ++S.frames;
    S.gpu.collect(module_->info().name, S.w, S.h);

    // 5. plugin-initiated parameter changes
    ParamEvent evbuf[32];
    ParamEventStruct raw[32];
    GetParamEventsStruct ge{32, raw};
    if (M.callP(FF_GET_PARAMETER_EVENTS, &ge, S.id).UIntValue == FF_SUCCESS) {
        for (FFUInt32 e = 0; e < ge.numEvents && e < 32; ++e) {
            const uint32_t idx = raw[e].ParameterNumber;
            if (idx >= S.live.size()) continue;
            ParamEvent ev{idx, false, false, false, false};
            std::lock_guard<std::mutex> lk(S.pmtx);
            ParamInfo& p = S.live[idx];
            if (raw[e].eventFlags & FF_EVENT_FLAG_VALUE) {
                ev.valueChanged = true;
                FFMixed v = M.callU(FF_GET_PARAMETER, idx, S.id);
                if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
                    S.tvals[idx] = safeString((const char*)v.PointerValue, 4096);
                else
                    S.fvals[idx] = bitsToFloat(v.UIntValue);
            }
            if (raw[e].eventFlags & FF_EVENT_FLAG_VISIBILITY) {
                ev.visibilityChanged = true;
                FFUInt32 vis = M.callU(FF_GET_PRAMETER_VISIBILITY, idx, S.id).UIntValue;
                p.visible = vis != 0 && vis != FF_FAIL;
            }
            if (raw[e].eventFlags & FF_EVENT_FLAG_DISPLAY_NAME) {
                ev.displayNameChanged = true;
                char buf[128] = {0};
                GetStringStruct gs{};
                gs.parameterNumber = idx;
                gs.stringBuffer.address = buf;
                gs.stringBuffer.maxToWrite = sizeof buf - 1;
                if (M.callP(FF_GET_PARAM_DISPLAY_NAME, &gs, S.id).UIntValue != FF_FAIL && buf[0])
                    p.displayName = buf;
            }
            if (raw[e].eventFlags & FF_EVENT_FLAG_ELEMENTS) ev.optionsChanged = true;
            if (events) events->push_back(ev);
        }
    }
    (void)evbuf;
    return rc != FF_FAIL;
}

void Instance::finish() {
    ScopedContext sc;
    if (sc.ok) glFinish();
}

bool readSurface(IOSurfaceRef s, std::vector<uint8_t>& bgra, uint32_t& w, uint32_t& h) {
    if (!s) return false;
    w = (uint32_t)IOSurfaceGetWidth(s);
    h = (uint32_t)IOSurfaceGetHeight(s);
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) return false;
    const uint8_t* base = (const uint8_t*)IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    bgra.resize((size_t)w * h * 4);
    for (uint32_t y = 0; y < h; ++y) std::memcpy(&bgra[(size_t)y * w * 4], base + y * bpr, (size_t)w * 4);
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, nullptr);
    return true;
}

}  // namespace ffgl_host

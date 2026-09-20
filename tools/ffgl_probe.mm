// ffgl_probe — exercise the FFGL host without Max.
//
//   ffgl_probe --list
//   ffgl_probe <plugin> [--size WxH] [--frames N] [--fps F]
//                       [--set name=value]... [--text name=string]...
//                       [--input gradient|checker|noise|noise-opaque] [--rect|--2d] [--out file.png] [--quiet]
//                       [--hold SECONDS]   keep rendering in real time (so a plugin's servers stay up)
//
// Prints the plugin's parameters, renders N frames, and reports simple
// statistics of the last frame so a broken bridge / blank output is obvious.

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "ffgl_host.h"

using namespace ffgl_host;

static const char* kindName(ParamKind k) {
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

static void fillPattern(IOSurfaceRef s, const std::string& pattern) {
    IOSurfaceLock(s, 0, nullptr);
    uint8_t* base = (uint8_t*)IOSurfaceGetBaseAddress(s);
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s);
    // BGRA. Row 0 is the *top* row in memory; GL row 0 is the bottom, so the
    // gradient below is red-dark-at-bottom in GL terms.
    for (size_t y = 0; y < h; ++y) {
        uint8_t* row = base + y * bpr;
        for (size_t x = 0; x < w; ++x) {
            uint8_t r, g, b, a = 255;
            if (pattern == "noise" || pattern == "noise-opaque") {  // like jit.noise 4 char: random alpha
                r = (uint8_t)rand(); g = (uint8_t)rand(); b = (uint8_t)rand();
                if (pattern == "noise") a = (uint8_t)rand();
            } else if (pattern == "checker") {
                bool on = ((x / 32) + (y / 32)) & 1;
                r = g = b = on ? 255 : 30;
            } else {
                r = (uint8_t)(255 * x / (w - 1));
                g = (uint8_t)(255 * (h - 1 - y) / (h - 1));  // grows towards GL top
                b = 128;
            }
            row[x * 4 + 0] = b;
            row[x * 4 + 1] = g;
            row[x * 4 + 2] = r;
            row[x * 4 + 3] = a;
        }
    }
    IOSurfaceUnlock(s, 0, nullptr);
}

static bool writePNG(const char* path, const std::vector<uint8_t>& bgra, uint32_t w, uint32_t h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(nullptr, bgra.data(), bgra.size(), nullptr);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dp,
                                   nullptr, false, kCGRenderingIntentDefault);
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    CGImageDestinationAddImage(dest, img, nullptr);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return ok;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) {
            std::fprintf(stderr, "usage: ffgl_probe --list | <plugin> [options]\n");
            return 2;
        }
        if (!std::strcmp(argv[1], "--list")) {
            for (auto& p : scanPlugins()) std::printf("%-24s %s\n", p.name.c_str(), p.path.c_str());
            return 0;
        }

        std::string plugin = argv[1];
        uint32_t W = 640, H = 360;
        int frames = 30;
        double fps = 60;
        double hold = 0;
        std::string inputPattern = "gradient", outPath;
        bool quiet = false, rect = false;
        std::vector<std::pair<std::string, std::string>> sets, texts;
        for (int i = 2; i < argc; ++i) {
            std::string a = argv[i];
            auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
            if (a == "--size") std::sscanf(next().c_str(), "%ux%u", &W, &H);
            else if (a == "--frames") frames = std::atoi(next().c_str());
            else if (a == "--fps") fps = std::atof(next().c_str());
            else if (a == "--hold") hold = std::atof(next().c_str());
            else if (a == "--input") inputPattern = next();
            else if (a == "--out") outPath = next();
            else if (a == "--quiet") quiet = true;
            else if (a == "--rect") rect = true;
            else if (a == "--2d") rect = false;
            else if (a == "--set" || a == "--text") {
                std::string kv = next();
                auto eq = kv.find('=');
                if (eq == std::string::npos) { std::fprintf(stderr, "expected name=value: %s\n", kv.c_str()); return 2; }
                (a == "--set" ? sets : texts).push_back({kv.substr(0, eq), kv.substr(eq + 1)});
            }
        }

        std::string err;
        auto mod = Module::open(plugin, err);
        if (!mod) { std::fprintf(stderr, "open failed: %s\n", err.c_str()); return 1; }
        const PluginInfo& pi = mod->info();
        std::printf("plugin   : %s  [%s]  FFGL %u.%u  type=%u  inputs=%u  time=%d\n", pi.name.c_str(),
                    pi.id.c_str(), pi.apiMajor, pi.apiMinor, pi.type, pi.numInputs, pi.wantsTime);
        if (!pi.description.empty()) std::printf("about    : %s\n", pi.description.c_str());
        std::printf("gl       : %s\n", glInfo().c_str());
        std::printf("params   : %zu\n", mod->params().size());
        for (auto& p : mod->params()) {
            std::printf("  [%2u] %-24s %-6s type=%-3u ", p.index, p.name.c_str(), kindName(p.kind), p.ffType);
            if (p.kind == ParamKind::Text || p.kind == ParamKind::File)
                std::printf("default=\"%.40s\"", p.defText.c_str());
            else
                std::printf("default=%g range=[%g, %g]", p.def, p.min, p.max);
            if (!p.group.empty()) std::printf(" group=%s", p.group.c_str());
            std::printf("\n");
            for (auto& o : p.options) std::printf("        option %g = %s\n", o.value, o.name.c_str());
        }

        auto inst = Instance::create(mod, W, H, err);
        if (!inst) { std::fprintf(stderr, "instantiate failed: %s\n", err.c_str()); return 1; }

        inst->setInputTarget(rect ? InputTarget::Rectangle : InputTarget::Texture2D);
        for (auto& [k, v] : sets) {
            int idx = mod->findParam(k);
            if (idx < 0) { std::fprintf(stderr, "no such param: %s\n", k.c_str()); return 1; }
            inst->setFloat((uint32_t)idx, (float)std::atof(v.c_str()));
        }
        for (auto& [k, v] : texts) {
            int idx = mod->findParam(k);
            if (idx < 0) { std::fprintf(stderr, "no such param: %s\n", k.c_str()); return 1; }
            inst->setText((uint32_t)idx, v);
        }
        for (uint32_t i = 0; i < inst->numInputs(); ++i) fillPattern(inst->inputSurface(i), inputPattern);

        std::vector<ParamEvent> events;
        auto t0 = std::chrono::steady_clock::now();
        bool ok = true;
        for (int f = 0; f < frames; ++f) {
            ok = inst->render(f / fps, true, &events) && ok;
        }
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (hold > 0) {
            // Real-time loop: pace to fps, render into the same instance.
            std::printf("hold     : rendering in real time for %.0f s ...\n", hold);
            std::fflush(stdout);
            auto t0 = std::chrono::steady_clock::now();
            uint64_t n = 0;
            for (;;) {
                double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                if (t >= hold) break;
                ok = inst->render(t, true, &events) && ok;
                ++n;
                std::this_thread::sleep_until(t0 + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                                       std::chrono::duration<double>((double)n / fps)));
            }
        }
        std::printf("render   : %d frames in %.1f ms (%.2f ms/frame) rc=%s events=%zu\n", frames, ms,
                    ms / std::max(1, frames), ok ? "ok" : "FAIL", events.size());

        std::vector<uint8_t> px;
        uint32_t w = 0, h = 0;
        // give the GPU a moment: flush was issued inside render(); a CPU read needs it retired
        inst->finish();
        if (!readSurface(inst->outputSurface(), px, w, h)) { std::fprintf(stderr, "readback failed\n"); return 1; }
        double sum[4] = {0, 0, 0, 0};
        size_t nonBlack = 0;
        for (size_t i = 0; i < (size_t)w * h; ++i) {
            const uint8_t* p = &px[i * 4];
            sum[0] += p[2]; sum[1] += p[1]; sum[2] += p[0]; sum[3] += p[3];
            if (p[0] | p[1] | p[2]) ++nonBlack;
        }
        const double n = (double)w * h;
        std::printf("output   : %ux%u  mean RGBA = %.1f %.1f %.1f %.1f   non-black = %.1f%%\n", w, h,
                    sum[0] / n, sum[1] / n, sum[2] / n, sum[3] / n, 100.0 * nonBlack / n);
        // GL-origin corners (memory row 0 is the top row of the IOSurface = GL top)
        auto px_at = [&](uint32_t x, uint32_t y) { const uint8_t* p = &px[((size_t)y * w + x) * 4]; return std::string("(") + std::to_string(p[2]) + "," + std::to_string(p[1]) + "," + std::to_string(p[0]) + "," + std::to_string(p[3]) + ")"; };
        if (!quiet)
            std::printf("corners  : memTL=%s memTR=%s memBL=%s memBR=%s\n", px_at(0, 0).c_str(),
                        px_at(w - 1, 0).c_str(), px_at(0, h - 1).c_str(), px_at(w - 1, h - 1).c_str());
        if (!outPath.empty()) {
            std::printf("png      : %s (%s)\n", outPath.c_str(), writePNG(outPath.c_str(), px, w, h) ? "written" : "FAILED");
        }
        return ok ? 0 : 1;
    }
}

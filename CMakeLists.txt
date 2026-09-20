cmake_minimum_required(VERSION 3.19)

# Apple Silicon by default. For a universal build:  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "macOS architectures")
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version")
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

project(ffgl_for_max LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
add_compile_definitions(GL_SILENCE_DEPRECATION)

# --- Max-independent FFGL host ------------------------------------------------
add_library(ffgl_host STATIC source/host/ffgl_host.mm)
target_include_directories(ffgl_host PUBLIC source/host PRIVATE third_party/ffgl)
target_compile_options(ffgl_host PRIVATE -fobjc-arc -Wall -Wno-unused-function)
target_link_libraries(ffgl_host PUBLIC
  "-framework OpenGL" "-framework IOSurface" "-framework CoreFoundation" "-framework AppKit")
set_target_properties(ffgl_host PROPERTIES POSITION_INDEPENDENT_CODE ON)

# --- command line probe: load a plugin, dump params, render frames ------------
add_executable(ffgl_probe tools/ffgl_probe.mm)
target_link_libraries(ffgl_probe PRIVATE ffgl_host
  "-framework Foundation" "-framework ImageIO" "-framework CoreGraphics" "-framework UniformTypeIdentifiers")

# --- the Max external ---------------------------------------------------------
option(FFGL_BUILD_EXTERNAL "Build the jit.gl.ffgl Max external" ON)
set(FFGL_MAX_SDK "${CMAKE_CURRENT_SOURCE_DIR}/third_party/max-sdk/source/max-sdk-base"
    CACHE PATH "Path to max-sdk-base")
if(FFGL_BUILD_EXTERNAL)
  add_subdirectory(source/jit.gl.ffgl)
endif()

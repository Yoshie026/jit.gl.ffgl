# jit.gl.ffgl — the Max external. Uses the Max SDK's own pre/post-target scripts so the
# result is a correctly named, signed .mxo. The project name comes from this folder's
# name (see max-pretarget.cmake), which is why the folder is called jit.gl.ffgl.
cmake_minimum_required(VERSION 3.19)

set(C74_SUPPORT_DIR "${FFGL_MAX_SDK}/c74support")
set(C74_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/package/externals")
include(${FFGL_MAX_SDK}/script/max-pretarget.cmake)

include_directories(${C74_INCLUDES})

add_library(${PROJECT_NAME} MODULE jit.gl.ffgl.mm)
target_include_directories(${PROJECT_NAME} PRIVATE ${CMAKE_SOURCE_DIR}/source/host)
target_compile_options(${PROJECT_NAME} PRIVATE -fobjc-arc -Wall -Wno-unused-function
                       -Wno-deprecated-declarations)
target_link_libraries(${PROJECT_NAME} PRIVATE ffgl_host
  "-framework OpenGL" "-framework IOSurface" "-framework CoreFoundation" "-framework AppKit")

include(${FFGL_MAX_SDK}/script/max-posttarget.cmake)

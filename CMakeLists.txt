cmake_minimum_required(VERSION 3.16)
project(v8dasm)

set(CMAKE_CXX_STANDARD 17)

include_directories(./v8/v8/include)
add_executable(v8dasm v8dasm.cpp)

# V8_COMPRESS_POINTERS is enabled by default on x64 V8 builds.
# V8_ENABLE_SANDBOX only exists in V8 11+; uncomment if targeting that version.
add_definitions(-DV8_COMPRESS_POINTERS)
# add_definitions(-DV8_ENABLE_SANDBOX)

if(WIN32)
    add_definitions(-D_ITERATOR_DEBUG_LEVEL=0)
    set_property(TARGET v8dasm PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_link_directories(v8dasm PRIVATE "./v8/v8/out/x64.$<IF:$<CONFIG:DEBUG>,debug,release>/obj")
    target_link_libraries(v8dasm v8_libbase.lib v8_libplatform.lib wee8.lib)
    target_link_libraries(v8dasm secur32.lib winmm.lib dmoguids.lib wmcodecdspuuid.lib msdmo.lib Strmiids.lib DbgHelp.lib)
else()
    # Linux build - link against V8 static libraries
    set(V8_OUT_DIR "./v8/v8/out/x64.release" CACHE PATH "V8 build output directory")
    target_link_directories(v8dasm PRIVATE "${V8_OUT_DIR}/obj" "${V8_OUT_DIR}/obj/third_party/icu")

    target_link_libraries(v8dasm
        -Wl,--start-group
        wee8
        v8_libbase
        v8_libplatform
        -Wl,--end-group
    )
    target_link_libraries(v8dasm pthread dl)
endif()


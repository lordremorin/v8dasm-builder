cmake_minimum_required(VERSION 3.16)
project(v8dasm)

set(CMAKE_CXX_STANDARD 17)

include_directories(./v8/v8/include)
add_executable(v8dasm v8dasm.cpp)

# Auto-detect V8 major version from headers to set correct compile-time defines.
# These MUST match the V8 build that produced the .jsc file, or deserialization
# crashes with "unreachable code".
set(V8_INCLUDE_DIR "./v8/v8/include")
set(V8_MAJOR 9)
foreach(_header "v8-version.h" "v8.h")
    if(EXISTS "${V8_INCLUDE_DIR}/${_header}")
        file(STRINGS "${V8_INCLUDE_DIR}/${_header}" _v8_major_line REGEX "#define V8_MAJOR_VERSION")
        if(_v8_major_line)
            string(REGEX MATCH "[0-9]+" V8_MAJOR "${_v8_major_line}")
            break()
        endif()
    endif()
endforeach()
message(STATUS "Detected V8 major version: ${V8_MAJOR}")

# V8 8+: pointer compression on x64
add_definitions(-DV8_COMPRESS_POINTERS)

# V8 10+: shared cage and external code space (used by Node 18 / pkg)
if(V8_MAJOR GREATER_EQUAL 10)
    add_definitions(-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE)
    add_definitions(-DV8_EXTERNAL_CODE_SPACE)
endif()

# V8 11+: full sandbox
if(V8_MAJOR GREATER_EQUAL 11)
    add_definitions(-DV8_ENABLE_SANDBOX)
endif()

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


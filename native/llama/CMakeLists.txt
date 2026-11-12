cmake_minimum_required(VERSION 3.22)
project(nexus_llama_android LANGUAGES C CXX)

if(NOT DEFINED LLAMA_CPP_SOURCE_DIR OR NOT EXISTS "${LLAMA_CPP_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "LLAMA_CPP_SOURCE_DIR must point to the pinned llama.cpp source checkout")
endif()

# Build upstream components as PIC static libraries and fold them into one
# Android-loadable adapter. This avoids fragile versioned .so dependency chains
# inside jniLibs while retaining the upstream C API behind our own ABI.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build upstream llama.cpp as static libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(LLAMA_BUILD_IS_DEV OFF CACHE BOOL "Use the pinned upstream release version" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "Link the CPU backend into the runtime" FORCE)
set(GGML_CPU ON CACHE BOOL "Build the portable CPU backend" FORCE)
set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "Avoid extra CPU backend variants" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "Avoid host-specific CPU instructions" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "Avoid OpenMP runtime dependency on Android" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "Disable unsupported Android backend" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "Avoid Android OpenSSL dependency" FORCE)

add_subdirectory("${LLAMA_CPP_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/llama.cpp" EXCLUDE_FROM_ALL)

# The JNI-visible shared object is the only NEXUS-owned native library.
# llama.cpp and ggml are statically linked into it with PIC enabled above.
add_library(nexus_llama_probe SHARED src/llama_probe.cpp)
target_compile_features(nexus_llama_probe PRIVATE cxx_std_17)
target_include_directories(nexus_llama_probe PRIVATE "${LLAMA_CPP_SOURCE_DIR}/include")
target_link_libraries(nexus_llama_probe PRIVATE llama)
set_target_properties(nexus_llama_probe PROPERTIES
    OUTPUT_NAME "nexus_llama_probe"
    INSTALL_RPATH "$ORIGIN"
)

install(TARGETS nexus_llama_probe LIBRARY DESTINATION lib)

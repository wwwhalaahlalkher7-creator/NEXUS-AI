#include "llama.h"

#include <cstdint>
#include <mutex>

#if defined(__GNUC__)
#define NEXUS_EXPORT __attribute__((visibility("default")))
#else
#define NEXUS_EXPORT
#endif

extern "C" {

// Initializes llama.cpp once per process. It does not load a model or create
// an inference context; those operations belong to the next integration stage.
NEXUS_EXPORT std::int32_t nexus_llama_backend_init() noexcept {
    static std::once_flag initialized;
    try {
        std::call_once(initialized, []() { llama_backend_init(); });
        return 1;
    } catch (...) {
        return 0;
    }
}

// llama_version() returns a process-lifetime string owned by llama.cpp.
NEXUS_EXPORT const char *nexus_llama_version() noexcept {
    return llama_version();
}

}  // extern "C"

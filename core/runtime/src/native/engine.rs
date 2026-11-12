//! Narrow, runtime-loaded boundary to the Android llama.cpp adapter.
//!
//! The adapter is packaged as an Android shared library. Keeping it dynamically
//! loaded means host Rust tests do not need the Android NDK or native binaries.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeEngineStatus {
    pub available: bool,
    pub version: Option<String>,
    pub message: String,
}

impl NativeEngineStatus {
    #[cfg(not(target_os = "android"))]
    fn unavailable(message: impl Into<String>) -> Self {
        Self {
            available: false,
            version: None,
            message: message.into(),
        }
    }
}

#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android {
    use super::NativeEngineStatus;
    use libloading::Library;
    use std::ffi::{c_char, CStr};
    use std::sync::OnceLock;

    type InitializeFn = unsafe extern "C" fn() -> i32;
    type VersionFn = unsafe extern "C" fn() -> *const c_char;

    struct LoadedBackend {
        // Keeping the handle alive keeps the function pointers and llama.cpp
        // process state valid for the lifetime of the application.
        _library: Library,
        version: String,
    }

    static BACKEND: OnceLock<Result<LoadedBackend, String>> = OnceLock::new();

    pub(super) fn status() -> NativeEngineStatus {
        match BACKEND.get_or_init(load_backend) {
            Ok(backend) => NativeEngineStatus {
                available: true,
                version: Some(backend.version.clone()),
                message: "تم تحميل مكتبة llama.cpp وتهيئة النواة الأصلية؛ لم يتم تحميل نموذج بعد.".to_owned(),
            },
            Err(error) => NativeEngineStatus {
                available: false,
                version: None,
                message: format!("تعذر تحميل محول llama.cpp الأصلي: {error}"),
            },
        }
    }

    fn load_backend() -> Result<LoadedBackend, String> {
        // SAFETY: the CI native-build step packages this exact adapter and its
        // llama.cpp dependencies in jniLibs/arm64-v8a for the Android target.
        let library = unsafe { Library::new("libnexus_llama_probe.so") }
            .map_err(|error| error.to_string())?;

        // SAFETY: both exported names and signatures are defined by
        // native/llama/src/llama_probe.cpp and use the C ABI.
        let initialize = unsafe {
            *library
                .get::<InitializeFn>(b"nexus_llama_backend_init\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: function signature matches the C++ adapter declaration.
        let version_fn = unsafe {
            *library
                .get::<VersionFn>(b"nexus_llama_version\0")
                .map_err(|error| error.to_string())?
        };

        // SAFETY: the adapter takes no arguments and returns a numeric status.
        if unsafe { initialize() } != 1 {
            return Err("فشلت تهيئة llama_backend_init".to_owned());
        }

        // SAFETY: llama_version returns a null-terminated static string.
        let version_ptr = unsafe { version_fn() };
        if version_ptr.is_null() {
            return Err("أعاد llama.cpp إصداراً فارغاً".to_owned());
        }
        // SAFETY: the returned pointer is owned by the loaded library and
        // remains valid while _library is retained in LoadedBackend.
        let version = unsafe { CStr::from_ptr(version_ptr) }
            .to_string_lossy()
            .into_owned();
        if version.trim().is_empty() {
            return Err("تعذر قراءة إصدار llama.cpp".to_owned());
        }

        Ok(LoadedBackend {
            _library: library,
            version,
        })
    }
}

#[cfg(target_os = "android")]
pub fn native_engine_status() -> NativeEngineStatus {
    android::status()
}

#[cfg(not(target_os = "android"))]
pub fn native_engine_status() -> NativeEngineStatus {
    NativeEngineStatus::unavailable(
        "مكتبة llama.cpp الأصلية تُبنى حالياً لهواتف Android بمعمارية ARM64 فقط.",
    )
}

impl fmt::Display for NativeEngineStatus {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.available {
            write!(formatter, "llama.cpp {}", self.version.as_deref().unwrap_or(""))
        } else {
            formatter.write_str(&self.message)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(not(target_os = "android"))]
    #[test]
    fn host_build_does_not_claim_android_native_engine_availability() {
        let status = native_engine_status();
        assert!(!status.available);
        assert!(status.version.is_none());
        assert!(status.message.contains("Android"));
    }
}

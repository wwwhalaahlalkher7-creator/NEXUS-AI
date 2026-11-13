//! Narrow, runtime-loaded boundary to the Android llama.cpp adapter.
//!
//! The adapter is packaged as an Android shared library. Keeping the handle
//! alive means host Rust tests do not need the Android NDK or native binaries.

use std::ffi::{c_char, c_void};
use std::fmt;

/// C ABI callback used by the native decoder to stream token pieces.
pub type NativeTokenCallback =
    unsafe extern "C" fn(*const c_char, usize, u32, *mut c_void) -> i32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeEngineStatus {
    pub available: bool,
    pub version: Option<String>,
    pub model_loaded: bool,
    pub inference_available: bool,
    pub context_tokens: Option<u32>,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeGenerationOperation {
    pub success: bool,
    pub cancelled: bool,
    pub generated_tokens: u32,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeModelOperation {
    pub success: bool,
    pub model_loaded: bool,
    pub context_tokens: u32,
    pub message: String,
}

impl NativeEngineStatus {
    #[cfg(not(target_os = "android"))]
    fn unavailable(message: impl Into<String>) -> Self {
        Self {
            available: false,
            version: None,
            model_loaded: false,
            inference_available: false,
            context_tokens: None,
            message: message.into(),
        }
    }
}

#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android {
    use super::{
        NativeEngineStatus, NativeGenerationOperation, NativeModelOperation, NativeTokenCallback,
    };
    use libloading::Library;
    use std::ffi::{c_char, c_void, CStr, CString};
    use std::sync::OnceLock;

    type InitializeFn = unsafe extern "C" fn() -> i32;
    type VersionFn = unsafe extern "C" fn() -> *const c_char;
    type LoadModelFn = unsafe extern "C" fn(*const c_char, u32, i32, *mut u32) -> i32;
    type UnloadModelFn = unsafe extern "C" fn() -> i32;
    type IsLoadedFn = unsafe extern "C" fn() -> i32;
    type ContextTokensFn = unsafe extern "C" fn() -> u32;
    type LastErrorFn = unsafe extern "C" fn() -> *const c_char;
    type InferenceAvailableFn = unsafe extern "C" fn() -> i32;
    type CancelGenerationFn = unsafe extern "C" fn() -> i32;
    type GenerateFn = unsafe extern "C" fn(
        *const c_char,
        u32,
        f32,
        u32,
        f32,
        u32,
        NativeTokenCallback,
        *mut c_void,
        *mut u32,
    ) -> i32;

    struct LoadedBackend {
        // Keeping the handle alive keeps all function pointers valid for the
        // lifetime of this process-level backend.
        _library: Library,
        version: String,
        load_model: LoadModelFn,
        unload_model: UnloadModelFn,
        is_model_loaded: IsLoadedFn,
        context_tokens: ContextTokensFn,
        last_error: LastErrorFn,
        inference_available: InferenceAvailableFn,
        cancel_generation: CancelGenerationFn,
        generate: GenerateFn,
    }

    // The backend is immutable after load. Do not hold a Rust mutex while calling
    // generate: the native session mutex protects the model, while cancellation
    // must be able to enter the adapter concurrently.
    static BACKEND: OnceLock<Result<LoadedBackend, String>> = OnceLock::new();

    fn with_backend<T>(
        operation: impl FnOnce(&LoadedBackend) -> Result<T, String>,
    ) -> Result<T, String> {
        match BACKEND.get_or_init(load_backend) {
            Ok(backend) => operation(backend),
            Err(error) => Err(error.clone()),
        }
    }

    fn load_backend() -> Result<LoadedBackend, String> {
        // SAFETY: CI packages this adapter for the Android arm64-v8a target.
        let library = unsafe { Library::new("libnexus_llama_probe.so") }
            .map_err(|error| error.to_string())?;

        // SAFETY: symbol names and signatures are defined by the NEXUS C ABI.
        let initialize = unsafe {
            *library
                .get::<InitializeFn>(b"nexus_llama_backend_init\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: the returned version pointer is a null-terminated static string.
        let version_fn = unsafe {
            *library
                .get::<VersionFn>(b"nexus_llama_version\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: the following symbols use the signatures declared in llama_probe.cpp.
        let load_model = unsafe {
            *library
                .get::<LoadModelFn>(b"nexus_llama_load_model\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: function signature matches the exported C ABI.
        let unload_model = unsafe {
            *library
                .get::<UnloadModelFn>(b"nexus_llama_unload_model\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: function signature matches the exported C ABI.
        let is_model_loaded = unsafe {
            *library
                .get::<IsLoadedFn>(b"nexus_llama_is_model_loaded\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: function signature matches the exported C ABI.
        let context_tokens = unsafe {
            *library
                .get::<ContextTokensFn>(b"nexus_llama_loaded_context_tokens\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: function signature matches the exported C ABI.
        let last_error = unsafe {
            *library
                .get::<LastErrorFn>(b"nexus_llama_last_error\0")
                .map_err(|error| error.to_string())?
        };
        // SAFETY: all three signatures mirror the pinned NEXUS native C ABI.
        let inference_available = unsafe {
            *library
                .get::<InferenceAvailableFn>(b"nexus_llama_inference_available\0")
                .map_err(|error| error.to_string())?
        };
        let cancel_generation = unsafe {
            *library
                .get::<CancelGenerationFn>(b"nexus_llama_cancel_generation\0")
                .map_err(|error| error.to_string())?
        };
        let generate = unsafe {
            *library
                .get::<GenerateFn>(b"nexus_llama_generate\0")
                .map_err(|error| error.to_string())?
        };

        // SAFETY: the adapter initializes its process-global backend once.
        if unsafe { initialize() } != 1 {
            return Err("فشلت تهيئة llama.cpp backend.".to_owned());
        }
        // SAFETY: llama_version returns a null-terminated static string.
        let version_ptr = unsafe { version_fn() };
        if version_ptr.is_null() {
            return Err("أعاد llama.cpp إصداراً فارغاً.".to_owned());
        }
        // SAFETY: the pointer remains valid while the library handle is retained.
        let version = unsafe { CStr::from_ptr(version_ptr) }
            .to_string_lossy()
            .into_owned();
        if version.trim().is_empty() {
            return Err("تعذر قراءة إصدار llama.cpp.".to_owned());
        }

        Ok(LoadedBackend {
            _library: library,
            version,
            load_model,
            unload_model,
            is_model_loaded,
            context_tokens,
            last_error,
            inference_available,
            cancel_generation,
            generate,
        })
    }

    fn read_last_error(backend: &LoadedBackend, fallback: &str) -> String {
        // SAFETY: the adapter returns thread-local, null-terminated text.
        let pointer = unsafe { (backend.last_error)() };
        if pointer.is_null() {
            return fallback.to_owned();
        }
        // SAFETY: the pointer is valid until the next adapter call on this thread.
        let message = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        if message.trim().is_empty() {
            fallback.to_owned()
        } else {
            message
        }
    }

    pub(super) fn status() -> NativeEngineStatus {
        match with_backend(|backend| {
            // SAFETY: query functions are process-safe and serialize session state internally.
            let model_loaded = unsafe { (backend.is_model_loaded)() == 1 };
            // SAFETY: the value is copied and does not expose native memory.
            let context_tokens = unsafe { (backend.context_tokens)() };
            // This becomes true after a full response and resets when the model is unloaded.
            let inference_available = unsafe { (backend.inference_available)() == 1 };
            Ok((
                backend.version.clone(),
                model_loaded,
                context_tokens,
                inference_available,
            ))
        }) {
            Ok((version, model_loaded, context_tokens, inference_available)) => {
                NativeEngineStatus {
                    available: true,
                    version: Some(version),
                    model_loaded,
                    inference_available,
                    context_tokens: if model_loaded {
                        Some(context_tokens)
                    } else {
                        None
                    },
                    message: if model_loaded && inference_available {
                        "تم تحميل GGUF والتحقق من نجاح توليد نص محلي.".to_owned()
                    } else if model_loaded {
                        "تم تحميل GGUF وإنشاء سياق CPU. لم يُتحقق من نجاح التوليد بعد."
                            .to_owned()
                    } else {
                        "تمت تهيئة llama.cpp؛ لا يوجد نموذج محمّل.".to_owned()
                    },
                }
            }
            Err(error) => NativeEngineStatus {
                available: false,
                version: None,
                model_loaded: false,
                inference_available: false,
                context_tokens: None,
                message: format!("تعذر تحميل محول llama.cpp الأصلي: {error}"),
            },
        }
    }

    pub(super) fn load_model(
        path: &str,
        context_tokens: u32,
        threads: u32,
    ) -> NativeModelOperation {
        if !(512..=4096).contains(&context_tokens) {
            return NativeModelOperation {
                success: false,
                model_loaded: false,
                context_tokens: 0,
                message: "حجم السياق يجب أن يكون بين 512 و4096.".to_owned(),
            };
        }
        if !(1..=8).contains(&threads) {
            return NativeModelOperation {
                success: false,
                model_loaded: false,
                context_tokens: 0,
                message: "عدد خيوط CPU يجب أن يكون بين 1 و8.".to_owned(),
            };
        }
        let path = match CString::new(path) {
            Ok(path) => path,
            Err(_) => {
                return NativeModelOperation {
                    success: false,
                    model_loaded: false,
                    context_tokens: 0,
                    message: "مسار النموذج يحتوي على محرف NUL.".to_owned(),
                };
            }
        };

        match with_backend(|backend| {
            let mut actual_context_tokens = 0_u32;
            // SAFETY: CString remains alive for the duration of the native call;
            // the adapter copies the path before returning.
            let result = unsafe {
                (backend.load_model)(
                    path.as_ptr(),
                    context_tokens,
                    threads as i32,
                    &mut actual_context_tokens,
                )
            };
            if result != 1 {
                return Err(read_last_error(backend, "فشل تحميل نموذج GGUF."));
            }
            // SAFETY: this reads a boolean-like integer and the copied context size.
            let loaded = unsafe { (backend.is_model_loaded)() == 1 };
            if !loaded || actual_context_tokens == 0 {
                return Err("لم يؤكد المحول تحميل النموذج.".to_owned());
            }
            Ok(actual_context_tokens)
        }) {
            Ok(actual_context_tokens) => NativeModelOperation {
                success: true,
                model_loaded: true,
                context_tokens: actual_context_tokens,
                message: format!(
                    "حُمّل GGUF على CPU بسياق {actual_context_tokens} رمزاً. يمكنك الآن تجربة التوليد من صفحة المحادثة."
                ),
            },
            Err(message) => NativeModelOperation {
                success: false,
                model_loaded: false,
                context_tokens: 0,
                message,
            },
        }
    }

    // The C ABI callback and user-data pointer are intentionally passed as one
    // synchronous pair; keeping them explicit avoids storing callback state globally.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn generate_text(
        prompt: &str,
        max_tokens: u32,
        temperature: f32,
        top_k: u32,
        top_p: f32,
        seed: u32,
        callback: NativeTokenCallback,
        user_data: *mut c_void,
    ) -> NativeGenerationOperation {
        if prompt.trim().is_empty() {
            return NativeGenerationOperation {
                success: false,
                cancelled: false,
                generated_tokens: 0,
                message: "أدخل سؤالاً أو تعليماً قبل بدء التوليد.".to_owned(),
            };
        }
        if prompt.len() > 16 * 1024
            || !(1..=1024).contains(&max_tokens)
            || !(0.05..=2.0).contains(&temperature)
            || !(1..=100).contains(&top_k)
            || !(0.1..=1.0).contains(&top_p)
        {
            return NativeGenerationOperation {
                success: false,
                cancelled: false,
                generated_tokens: 0,
                message: "إعدادات التوليد خارج الحدود الآمنة.".to_owned(),
            };
        }
        let prompt = match CString::new(prompt) {
            Ok(value) => value,
            Err(_) => {
                return NativeGenerationOperation {
                    success: false,
                    cancelled: false,
                    generated_tokens: 0,
                    message: "النص يحتوي على محرف NUL غير صالح.".to_owned(),
                };
            }
        };

        match with_backend(|backend| {
            let mut generated_tokens = 0_u32;
            // SAFETY: prompt and callback state remain alive for this synchronous call.
            let result = unsafe {
                (backend.generate)(
                    prompt.as_ptr(),
                    max_tokens,
                    temperature,
                    top_k,
                    top_p,
                    seed,
                    callback,
                    user_data,
                    &mut generated_tokens,
                )
            };
            match result {
                1 if generated_tokens > 0 => Ok(NativeGenerationOperation {
                    success: true,
                    cancelled: false,
                    generated_tokens,
                    message: "اكتمل التوليد المحلي بنجاح.".to_owned(),
                }),
                2 => Ok(NativeGenerationOperation {
                    success: false,
                    cancelled: true,
                    generated_tokens,
                    message: "أوقفت عملية التوليد.".to_owned(),
                }),
                _ => Err(read_last_error(backend, "فشل توليد النص عبر llama.cpp.")),
            }
        }) {
            Ok(result) => result,
            Err(message) => NativeGenerationOperation {
                success: false,
                cancelled: false,
                generated_tokens: 0,
                message,
            },
        }
    }

    pub(super) fn cancel_generation() -> bool {
        with_backend(|backend| {
            // SAFETY: sets an atomic cancellation flag without waiting on the session lock.
            Ok(unsafe { (backend.cancel_generation)() == 1 })
        })
        .unwrap_or(false)
    }

    pub(super) fn unload_model() -> NativeModelOperation {
        match with_backend(|backend| {
            // SAFETY: unloading is serialized inside the adapter and releases
            // the context before its owning model.
            if unsafe { (backend.unload_model)() } != 1 {
                return Err(read_last_error(backend, "تعذر تفريغ نموذج GGUF."));
            }
            // SAFETY: query confirms the process-global state after unloading.
            if unsafe { (backend.is_model_loaded)() } == 1 {
                return Err("ما زال GGUF محمّلاً بعد طلب التفريغ.".to_owned());
            }
            Ok(())
        }) {
            Ok(()) => NativeModelOperation {
                success: true,
                model_loaded: false,
                context_tokens: 0,
                message: "تم تفريغ سياق التشغيل وأوزان GGUF.".to_owned(),
            },
            Err(message) => NativeModelOperation {
                success: false,
                model_loaded: true,
                context_tokens: 0,
                message,
            },
        }
    }
}

#[cfg(target_os = "android")]
pub fn native_engine_status() -> NativeEngineStatus {
    android::status()
}

#[cfg(not(target_os = "android"))]
pub fn native_engine_status() -> NativeEngineStatus {
    NativeEngineStatus::unavailable(
        "محرك llama.cpp الأصلي متاح حالياً على Android ARM64 فقط.",
    )
}

#[cfg(target_os = "android")]
pub fn load_native_model(path: &str, context_tokens: u32, threads: u32) -> NativeModelOperation {
    android::load_model(path, context_tokens, threads)
}

#[cfg(not(target_os = "android"))]
pub fn load_native_model(
    _path: &str,
    _context_tokens: u32,
    _threads: u32,
) -> NativeModelOperation {
    NativeModelOperation {
        success: false,
        model_loaded: false,
        context_tokens: 0,
        message: "تحميل GGUF متاح على Android ARM64 فقط.".to_owned(),
    }
}

#[cfg(target_os = "android")]
// The callback/user-data pair is part of the narrow native adapter boundary.
#[allow(clippy::too_many_arguments)]
pub fn generate_native_text(
    prompt: &str,
    max_tokens: u32,
    temperature: f32,
    top_k: u32,
    top_p: f32,
    seed: u32,
    callback: NativeTokenCallback,
    user_data: *mut c_void,
) -> NativeGenerationOperation {
    android::generate_text(
        prompt,
        max_tokens,
        temperature,
        top_k,
        top_p,
        seed,
        callback,
        user_data,
    )
}

#[cfg(not(target_os = "android"))]
pub fn generate_native_text(
    _prompt: &str,
    _max_tokens: u32,
    _temperature: f32,
    _top_k: u32,
    _top_p: f32,
    _seed: u32,
    _callback: NativeTokenCallback,
    _user_data: *mut c_void,
) -> NativeGenerationOperation {
    NativeGenerationOperation {
        success: false,
        cancelled: false,
        generated_tokens: 0,
        message: "توليد النص المحلي متاح على Android ARM64 فقط.".to_owned(),
    }
}

#[cfg(target_os = "android")]
pub fn cancel_native_generation() -> bool {
    android::cancel_generation()
}

#[cfg(not(target_os = "android"))]
pub fn cancel_native_generation() -> bool {
    false
}

#[cfg(target_os = "android")]
pub fn unload_native_model() -> NativeModelOperation {
    android::unload_model()
}

#[cfg(not(target_os = "android"))]
pub fn unload_native_model() -> NativeModelOperation {
    NativeModelOperation {
        success: false,
        model_loaded: false,
        context_tokens: 0,
        message: "تفريغ GGUF متاح على Android ARM64 فقط.".to_owned(),
    }
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
        assert!(!status.model_loaded);
        assert!(!status.inference_available);
        assert!(status.version.is_none());
        assert!(status.message.contains("Android"));
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn host_build_rejects_native_model_loading_without_claiming_success() {
        let result = load_native_model("model.gguf", 2048, 4);
        assert!(!result.success);
        assert!(!result.model_loaded);
        assert!(result.message.contains("Android"));
    }

    #[cfg(not(target_os = "android"))]
    #[test]
    fn host_build_rejects_native_text_generation_without_claiming_success() {
        extern "C" fn unused_callback(
            _data: *const c_char,
            _length: usize,
            _generated_tokens: u32,
            _user_data: *mut c_void,
        ) -> i32 {
            1
        }

        let result = generate_native_text(
            "Hello",
            128,
            0.7,
            40,
            0.92,
            0,
            unused_callback,
            std::ptr::null_mut(),
        );
        assert!(!result.success);
        assert!(!result.cancelled);
        assert_eq!(result.generated_tokens, 0);
        assert!(result.message.contains("Android"));
        assert!(!cancel_native_generation());
    }
}

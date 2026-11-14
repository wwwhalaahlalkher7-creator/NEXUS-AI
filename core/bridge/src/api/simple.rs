//! Small, deterministic API exposed to Flutter through flutter_rust_bridge.
use crate::frb_generated::StreamSink;
use nexus_runtime::{get_core_info, gguf::inspect_gguf_file};
use std::ffi::c_void;

/// Bridge-friendly snapshot of the Rust core identity.
#[derive(Debug, Clone)]
pub struct CoreInfoDto {
    pub name: String,
    pub version: String,
    pub stage: String,
}

/// Strongly typed runtime snapshot returned across Flutter Rust Bridge.
#[derive(Debug, Clone)]
pub struct RuntimeDiagnosticsDto {
    pub core_name: String,
    pub core_version: String,
    pub stage: String,
    pub bridge_connected: bool,
    pub runtime_engine: String,
    pub native_engine_available: bool,
    pub native_engine_version: Option<String>,
    pub native_engine_message: String,
    pub inference_available: bool,
    pub model_registry: String,
    pub agent_registry: String,
    pub model_loaded: bool,
    pub model_context_tokens: Option<u32>,
    pub native_memory_available: bool,
    pub native_memory_readable: bool,
    pub native_context_loaded: bool,
    pub native_generation_active: bool,
    pub native_resident_bytes: u64,
    pub native_peak_resident_bytes: u64,
    pub native_virtual_bytes: u64,
    pub native_kv_cache_clear_count: u64,
    pub native_model_load_count: u64,
    pub native_model_unload_count: u64,
}

/// Result of a real native model load/unload operation.
#[derive(Debug, Clone)]
pub struct ModelRuntimeOperationDto {
    pub success: bool,
    pub model_loaded: bool,
    pub context_tokens: u32,
    pub message: String,
}

/// Outcome of clearing transient native KV cache without unloading the model.
#[derive(Debug, Clone)]
pub struct MemoryLifecycleOperationDto {
    pub success: bool,
    pub message: String,
}

/// A role-aware message supplied to the local chat-template formatter.
#[derive(Debug, Clone)]
pub struct ChatMessageInputDto {
    pub role: String,
    pub content: String,
}

/// One incremental piece (or terminal status) from a local generation request.
#[derive(Debug, Clone)]
pub struct InferenceEventDto {
    pub delta: String,
    pub started: bool,
    pub done: bool,
    pub cancelled: bool,
    pub generated_tokens: u32,
    pub trimmed_messages: u32,
    pub error: Option<String>,
}

/// Returns metadata compiled into the Rust core.
pub fn get_core_info_for_app() -> CoreInfoDto {
    let info = get_core_info();
    CoreInfoDto {
        name: info.name.to_owned(),
        version: info.version.to_owned(),
        stage: info.stage.to_owned(),
    }
}

/// Returns actual backend and model-session state without claiming inference.
pub fn runtime_diagnostics() -> RuntimeDiagnosticsDto {
    let info = get_core_info();
    let native = nexus_runtime::native_engine_status();
    let memory = nexus_runtime::native_memory_snapshot();
    RuntimeDiagnosticsDto {
        core_name: info.name.to_owned(),
        core_version: info.version.to_owned(),
        stage: info.stage.to_owned(),
        bridge_connected: true,
        runtime_engine: if native.available {
            "llama.cpp-native-initialized".to_owned()
        } else {
            "llama.cpp-native-unavailable".to_owned()
        },
        native_engine_available: native.available,
        native_engine_version: native.version,
        native_engine_message: native.message,
        // This becomes true only after the native adapter completes a full response.
        inference_available: native.inference_available,
        model_registry: "flutter_sqlite".to_owned(),
        agent_registry: "rust_in_memory".to_owned(),
        model_loaded: native.model_loaded,
        model_context_tokens: native.context_tokens,
        native_memory_available: memory.available,
        native_memory_readable: memory.memory_readable,
        native_context_loaded: memory.context_loaded,
        native_generation_active: memory.generation_active,
        native_resident_bytes: memory.resident_bytes,
        native_peak_resident_bytes: memory.peak_resident_bytes,
        native_virtual_bytes: memory.virtual_bytes,
        native_kv_cache_clear_count: memory.kv_cache_clear_count,
        native_model_load_count: memory.model_load_count,
        native_model_unload_count: memory.model_unload_count,
    }
}

/// Load one GGUF model and create a bounded CPU context.
pub fn load_gguf_model(
    path: String,
    context_tokens: u32,
    threads: u32,
) -> ModelRuntimeOperationDto {
    let result = nexus_runtime::load_native_model(&path, context_tokens, threads);
    ModelRuntimeOperationDto {
        success: result.success,
        model_loaded: result.model_loaded,
        context_tokens: result.context_tokens,
        message: result.message,
    }
}

/// Unload the active model context and its model weights.
pub fn unload_gguf_model() -> ModelRuntimeOperationDto {
    let result = nexus_runtime::unload_native_model();
    ModelRuntimeOperationDto {
        success: result.success,
        model_loaded: result.model_loaded,
        context_tokens: result.context_tokens,
        message: result.message,
    }
}

/// Clears transient KV state while retaining model weights and context.
pub fn clear_native_context_memory() -> MemoryLifecycleOperationDto {
    let result = nexus_runtime::clear_native_context_memory();
    MemoryLifecycleOperationDto {
        success: result.success,
        message: result.message,
    }
}

/// Generate text with the currently loaded GGUF model and stream decoded UTF-8
/// chunks to Dart. The native call is synchronous on an FRB worker thread.
pub fn generate_text(
    sink: StreamSink<InferenceEventDto>,
    messages: Vec<ChatMessageInputDto>,
    max_tokens: u32,
    temperature: f32,
    top_k: u32,
    top_p: f32,
    seed: u32,
) {
    let mut state = stream_callback::StreamCallbackState::new(sink);
    let native_messages: Vec<nexus_runtime::native::engine::NativeChatMessage> = messages
        .into_iter()
        .map(|message| nexus_runtime::native::engine::NativeChatMessage {
            role: message.role,
            content: message.content,
        })
        .collect();
    let result = nexus_runtime::generate_native_text(
        &native_messages,
        max_tokens,
        temperature,
        top_k,
        top_p,
        seed,
        stream_callback::on_native_token,
        (&mut state as *mut stream_callback::StreamCallbackState).cast::<c_void>(),
    );
    state.finish(result);
}

/// Requests cancellation of the active native generation without blocking on
/// the model/session lock. Returns false when no generation is active.
pub fn cancel_text_generation() -> bool {
    nexus_runtime::cancel_native_generation()
}

#[allow(unsafe_code)]
mod stream_callback {
    use super::InferenceEventDto;
    use crate::frb_generated::StreamSink;
    use nexus_runtime::native::engine::NativeGenerationOperation;
    use std::ffi::{c_char, c_void};
    use std::panic::{catch_unwind, AssertUnwindSafe};
    use std::slice;

    pub(super) struct StreamCallbackState {
        sink: StreamSink<InferenceEventDto>,
        pending_utf8: Vec<u8>,
    }

    impl StreamCallbackState {
        pub(super) fn new(sink: StreamSink<InferenceEventDto>) -> Self {
            Self {
                sink,
                pending_utf8: Vec::new(),
            }
        }

        fn emit_delta(&self, delta: String, generated_tokens: u32) -> bool {
            if delta.is_empty() {
                return true;
            }
            self.sink
                .add(InferenceEventDto {
                    delta,
                    started: false,
                    done: false,
                    cancelled: false,
                    generated_tokens,
                    trimmed_messages: 0,
                    error: None,
                })
                .is_ok()
        }

        fn push_bytes(&mut self, bytes: &[u8], generated_tokens: u32) -> bool {
            self.pending_utf8.extend_from_slice(bytes);
            loop {
                match std::str::from_utf8(&self.pending_utf8) {
                    Ok(text) => {
                        let delta = text.to_owned();
                        self.pending_utf8.clear();
                        return self.emit_delta(delta, generated_tokens);
                    }
                    Err(error) => {
                        let valid = error.valid_up_to();
                        if valid > 0 {
                            let delta = String::from_utf8_lossy(&self.pending_utf8[..valid])
                                .into_owned();
                            self.pending_utf8.drain(..valid);
                            if !self.emit_delta(delta, generated_tokens) {
                                return false;
                            }
                            continue;
                        }
                        if let Some(invalid_len) = error.error_len() {
                            self.pending_utf8.drain(..invalid_len);
                            if !self.emit_delta("�".to_owned(), generated_tokens) {
                                return false;
                            }
                            continue;
                        }
                        // Retain an incomplete multibyte character until the next piece.
                        return true;
                    }
                }
            }
        }

        pub(super) fn finish(&mut self, result: NativeGenerationOperation) {
            if !self.pending_utf8.is_empty() {
                let delta = String::from_utf8_lossy(&self.pending_utf8).into_owned();
                self.pending_utf8.clear();
                let _ = self.emit_delta(delta, result.generated_tokens);
            }
            let error = if result.success || result.cancelled {
                None
            } else {
                Some(result.message)
            };
            let _ = self.sink.add(InferenceEventDto {
                delta: String::new(),
                started: false,
                done: true,
                cancelled: result.cancelled,
                generated_tokens: result.generated_tokens,
                trimmed_messages: result.trimmed_messages,
                error,
            });
        }
    }

    /// C ABI callback; no Rust panic may unwind through native llama.cpp.
    pub(super) unsafe extern "C" fn on_native_token(
        data: *const c_char,
        length: usize,
        generated_tokens: u32,
        user_data: *mut c_void,
    ) -> i32 {
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            if user_data.is_null() || (length > 0 && data.is_null()) {
                return 0;
            }
            // SAFETY: the native adapter supplies a valid byte span (or a null
            // pointer for the zero-length start signal) and the stack-owned
            // callback state for the duration of generate_text().
            let state = unsafe { &mut *user_data.cast::<StreamCallbackState>() };
            if length == 0 && generated_tokens == 0 {
                return if state
                    .sink
                    .add(InferenceEventDto {
                        delta: String::new(),
                        started: true,
                        done: false,
                        cancelled: false,
                        generated_tokens: 0,
                        trimmed_messages: 0,
                        error: None,
                    })
                    .is_ok()
                {
                    1
                } else {
                    0
                };
            }
            let bytes = unsafe { slice::from_raw_parts(data.cast::<u8>(), length) };
            if state.push_bytes(bytes, generated_tokens) {
                1
            } else {
                0
            }
        }));
        outcome.unwrap_or(0)
    }
}

/// Result of a bounded GGUF header inspection. A valid header does not mean
/// the model weights have been loaded or inference is available.
#[derive(Debug, Clone)]
pub struct GgufInspectionDto {
    pub valid_header: bool,
    pub file_name: String,
    pub size_bytes: u64,
    pub format_version: u32,
    pub tensor_count: u64,
    pub metadata_count: u64,
    pub architecture: Option<String>,
    pub model_name: Option<String>,
    pub tokenizer_model: Option<String>,
    pub context_length: Option<u64>,
    pub block_count: Option<u64>,
    pub embedding_length: Option<u64>,
    pub attention_head_count: Option<u64>,
    pub attention_head_count_kv: Option<u64>,
    pub attention_key_length: Option<u64>,
    pub attention_value_length: Option<u64>,
    pub file_type: Option<u64>,
    pub parameter_count: Option<u64>,
    pub message: String,
}

/// Inspect a user-selected GGUF file without loading its tensor data into memory.
pub fn inspect_gguf_model_file(path: String) -> GgufInspectionDto {
    match inspect_gguf_file(&path) {
        Ok(info) => GgufInspectionDto {
            valid_header: true,
            file_name: info.file_name,
            size_bytes: info.size_bytes,
            format_version: info.format_version,
            tensor_count: info.tensor_count,
            metadata_count: info.metadata_count,
            architecture: info.metadata.architecture,
            model_name: info.metadata.model_name,
            tokenizer_model: info.metadata.tokenizer_model,
            context_length: info.metadata.context_length,
            block_count: info.metadata.block_count,
            embedding_length: info.metadata.embedding_length,
            attention_head_count: info.metadata.attention_head_count,
            attention_head_count_kv: info.metadata.attention_head_count_kv,
            attention_key_length: info.metadata.attention_key_length,
            attention_value_length: info.metadata.attention_value_length,
            file_type: info.metadata.file_type,
            parameter_count: info.metadata.parameter_count,
            message: "تم فحص GGUF؛ لم تُحمّل الأوزان.".to_owned(),
        },
        Err(error) => GgufInspectionDto {
            valid_header: false,
            file_name: String::new(),
            size_bytes: 0,
            format_version: 0,
            tensor_count: 0,
            metadata_count: 0,
            architecture: None,
            model_name: None,
            tokenizer_model: None,
            context_length: None,
            block_count: None,
            embedding_length: None,
            attention_head_count: None,
            attention_head_count_kv: None,
            attention_key_length: None,
            attention_value_length: None,
            file_type: None,
            parameter_count: None,
            message: error,
        },
    }
}

/// Deterministic response used to verify the native bridge.
pub fn health_check() -> String {
    "NEXUS Rust bridge is reachable".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_api_returns_core_metadata() {
        let info = get_core_info_for_app();
        assert_eq!(info.name, "NEXUS AI");
        assert_eq!(info.stage, "alpha-2.7.6-explainable-placement");
    }

    #[test]
    fn runtime_diagnostics_report_real_bridge_capabilities_without_claiming_inference() {
        let diagnostics = runtime_diagnostics();
        assert!(diagnostics.bridge_connected);
        assert!(!diagnostics.inference_available);
        assert!(!diagnostics.model_loaded);
        assert_eq!(diagnostics.stage, "alpha-2.7.6-explainable-placement");
        assert_eq!(diagnostics.model_registry, "flutter_sqlite");
        #[cfg(not(target_os = "android"))]
        {
            assert!(!diagnostics.inference_available);
            assert!(!diagnostics.native_memory_available);
            assert!(!diagnostics.native_memory_readable);
            assert!(!diagnostics.native_context_loaded);
            assert!(!diagnostics.native_generation_active);
        }
    }

    #[test]
    fn host_api_rejects_native_model_loading_without_a_false_loaded_state() {
        let result = load_gguf_model("model.gguf".to_owned(), 2048, 4);
        #[cfg(not(target_os = "android"))]
        {
            assert!(!result.success);
            assert!(!result.model_loaded);
            assert!(result.message.contains("Android"));
        }
    }

    #[test]
    fn host_memory_clear_fails_without_claiming_native_resources_were_released() {
        let result = clear_native_context_memory();
        #[cfg(not(target_os = "android"))]
        {
            assert!(!result.success);
            assert!(result.message.contains("Android"));
        }
    }

    #[test]
    fn bridge_health_check_is_deterministic() {
        assert_eq!(health_check(), "NEXUS Rust bridge is reachable");
    }
}

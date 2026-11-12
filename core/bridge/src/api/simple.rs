//! Small, deterministic API exposed to Flutter through flutter_rust_bridge.
use nexus_runtime::{get_core_info, gguf::inspect_gguf_file};

/// Bridge-friendly snapshot of the Rust core identity.
#[derive(Debug, Clone)]
pub struct CoreInfoDto {
    pub name: String,
    pub version: String,
    pub stage: String,
}

/// Returns metadata compiled into the Rust core. This does not imply AI inference is running.
pub fn get_core_info_for_app() -> CoreInfoDto {
    let info = get_core_info();
    CoreInfoDto {
        name: info.name.to_owned(),
        version: info.version.to_owned(),
        stage: info.stage.to_owned(),
    }
}

/// Returns a machine-readable snapshot of the runtime capabilities.
/// A successful response proves the Flutter-to-Rust bridge is reachable; it
/// deliberately does not claim that an inference backend or model is loaded.
pub fn runtime_diagnostics_json() -> String {
    let info = get_core_info();
    let native = nexus_runtime::native_engine_status();
    let version = native
        .version
        .as_deref()
        .map(|value| format!("\"{}\"", json_escape(value)))
        .unwrap_or_else(|| "null".to_owned());
    let message = json_escape(&native.message);
    let native_available = if native.available { "true" } else { "false" };
    let runtime_engine = if native.available {
        "llama.cpp-native-initialized"
    } else {
        "llama.cpp-native-unavailable"
    };
    format!(
        r#"{{"core_name":"{}","core_version":"{}","stage":"{}","bridge_connected":true,"runtime_engine":"{}","native_engine_available":{},"native_engine_version":{},"native_engine_message":"{}","inference_available":false,"model_registry":"flutter_sqlite","agent_registry":"rust_in_memory","model_loaded":false}}"#,
        info.name, info.version, info.stage, runtime_engine, native_available, version, message
    )
}

fn json_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}


/// Result of a bounded GGUF header inspection. A valid header does not mean
/// that tensors were fully checked or that an inference backend is available.
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
            file_type: info.metadata.file_type,
            parameter_count: info.metadata.parameter_count,
            message: "تم فحص الترويسة والبيانات الوصفية؛ لم يتم فحص أوزان الموترات أو تحميل النموذج.".to_owned(),
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
        assert_eq!(info.stage, "alpha-1.4-llama-native-foundation");
    }

    #[test]
    fn runtime_diagnostics_report_real_bridge_capabilities_without_claiming_inference() {
        let diagnostics = runtime_diagnostics_json();
        assert!(diagnostics.contains("\"bridge_connected\":true"));
        assert!(diagnostics.contains("\"inference_available\":false"));
        assert!(diagnostics.contains("\"model_loaded\":false"));
        assert!(diagnostics.contains("alpha-1.4-llama-native-foundation"));
    }

    #[test]
    fn bridge_health_check_is_deterministic() {
        assert_eq!(health_check(), "NEXUS Rust bridge is reachable");
    }
}

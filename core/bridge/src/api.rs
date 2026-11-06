//! Small, deterministic API exposed to Flutter through flutter_rust_bridge.
use nexus_runtime::get_core_info;

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
        assert_eq!(info.stage, "alpha-0.1-foundation");
    }

    #[test]
    fn bridge_health_check_is_deterministic() {
        assert_eq!(health_check(), "NEXUS Rust bridge is reachable");
    }
}

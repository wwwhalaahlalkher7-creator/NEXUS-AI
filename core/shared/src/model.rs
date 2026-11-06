/// Describes a model known to the local registry.
/// This is metadata only; it does not imply that a model is installed or loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelDescriptor {
    pub id: String,
    pub display_name: String,
    pub runtime: ModelRuntime,
    pub local_path: Option<String>,
    pub is_loaded: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelRuntime {
    LlamaCpp,
    External,
}

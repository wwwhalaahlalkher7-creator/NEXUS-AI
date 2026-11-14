//! NEXUS runtime foundation.
//! The Android llama.cpp adapter can load one GGUF model, create one CPU
//! context, and stream bounded text generation through the pinned native ABI.

pub mod gguf;
pub mod native;

use std::collections::BTreeMap;

use nexus_shared::agent::Agent;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreInfo {
    pub name: &'static str,
    pub version: &'static str,
    pub stage: &'static str,
}

/// Reports native availability and the actual model/context state.
pub fn native_engine_status() -> native::engine::NativeEngineStatus {
    native::engine::native_engine_status()
}

/// Loads one local GGUF model and creates a bounded CPU context.
pub fn load_native_model(
    path: &str,
    context_tokens: u32,
    threads: u32,
) -> native::engine::NativeModelOperation {
    native::engine::load_native_model(path, context_tokens, threads)
}

/// Releases the context before releasing the model weights.
pub fn unload_native_model() -> native::engine::NativeModelOperation {
    native::engine::unload_native_model()
}

/// Streams generated token pieces to the bridge callback. The native adapter
/// serializes model access while keeping cancellation independent of that lock.
// The callback and user-data pair stays explicit across the internal Rust boundary.
#[allow(clippy::too_many_arguments)]
pub fn generate_native_text(
    messages: &[native::engine::NativeChatMessage],
    max_tokens: u32,
    temperature: f32,
    top_k: u32,
    top_p: f32,
    seed: u32,
    callback: native::engine::NativeTokenCallback,
    user_data: *mut std::ffi::c_void,
) -> native::engine::NativeGenerationOperation {
    native::engine::generate_native_text(
        messages,
        max_tokens,
        temperature,
        top_k,
        top_p,
        seed,
        callback,
        user_data,
    )
}

/// Reports native process memory and model/KV lifecycle counters.
pub fn native_memory_snapshot() -> native::engine::NativeMemorySnapshot {
    native::engine::native_memory_snapshot()
}

/// Clears transient KV cache while retaining model weights and context.
pub fn clear_native_context_memory() -> native::engine::NativeMemoryOperation {
    native::engine::clear_native_context_memory()
}

/// Requests cancellation without waiting for the native generation session lock.
pub fn cancel_native_generation() -> bool {
    native::engine::cancel_native_generation()
}

pub fn get_core_info() -> CoreInfo {
    CoreInfo {
        name: "NEXUS AI",
        version: env!("CARGO_PKG_VERSION"),
        stage: "alpha-2.7.6-explainable-placement",
    }
}

#[derive(Debug, Default)]
pub struct AgentRegistry {
    agents: BTreeMap<String, Agent>,
}

impl AgentRegistry {
    pub fn register(&mut self, agent: Agent) -> Result<(), &'static str> {
        if self.agents.contains_key(&agent.id) {
            return Err("agent id already exists");
        }
        self.agents.insert(agent.id.clone(), agent);
        Ok(())
    }

    pub fn get(&self, id: &str) -> Option<&Agent> {
        self.agents.get(id)
    }

    pub fn list(&self) -> Vec<&Agent> {
        self.agents.values().collect()
    }

    pub fn remove(&mut self, id: &str) -> Option<Agent> {
        self.agents.remove(id)
    }

    pub fn len(&self) -> usize {
        self.agents.len()
    }

    pub fn is_empty(&self) -> bool {
        self.agents.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nexus_shared::agent::Agent;

    #[test]
    fn core_info_has_expected_stage() {
        assert_eq!(get_core_info().stage, "alpha-2.7.6-explainable-placement");
    }

    #[test]
    fn registry_registers_lists_and_removes_agents() {
        let mut registry = AgentRegistry::default();
        let agent = Agent::new("agent-1", "Researcher", "Research tasks").unwrap();

        registry.register(agent).unwrap();
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.list().len(), 1);
        assert!(registry.remove("agent-1").is_some());
        assert!(registry.is_empty());
    }

    #[test]
    fn registry_rejects_duplicate_ids() {
        let mut registry = AgentRegistry::default();
        let first = Agent::new("same-id", "One", "").unwrap();
        let second = Agent::new("same-id", "Two", "").unwrap();

        registry.register(first).unwrap();
        assert_eq!(registry.register(second), Err("agent id already exists"));
    }
}

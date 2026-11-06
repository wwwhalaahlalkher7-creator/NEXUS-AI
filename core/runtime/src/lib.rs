//! NEXUS runtime foundation.
//! The current registry is process-local and intentionally not presented as
//! persistent storage. SQLite is scheduled for the next implementation phase.

use std::collections::BTreeMap;

use nexus_shared::agent::Agent;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreInfo {
    pub name: &'static str,
    pub version: &'static str,
    pub stage: &'static str,
}

pub fn get_core_info() -> CoreInfo {
    CoreInfo {
        name: "NEXUS AI",
        version: env!("CARGO_PKG_VERSION"),
        stage: "alpha-0.1-foundation",
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
        assert_eq!(get_core_info().stage, "alpha-0.1-foundation");
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

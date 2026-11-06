use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentStatus {
    Draft,
    Ready,
    Paused,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub description: String,
    pub status: AgentStatus,
    pub model_id: Option<String>,
    pub created_at_unix_ms: u128,
}

impl Agent {
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        description: impl Into<String>,
    ) -> Result<Self, &'static str> {
        let id = id.into();
        let name = name.into().trim().to_owned();
        let description = description.into().trim().to_owned();

        if id.trim().is_empty() {
            return Err("agent id must not be empty");
        }
        if name.is_empty() {
            return Err("agent name must not be empty");
        }

        let created_at_unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "system clock is before UNIX epoch")?
            .as_millis();

        Ok(Self {
            id,
            name,
            description,
            status: AgentStatus::Draft,
            model_id: None,
            created_at_unix_ms,
        })
    }
}

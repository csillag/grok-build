//! `_session/steering` for ACP clients such as Agent of Empires.
//!
//! A message that arrives during a turn is buffered and drained at the next
//! safe point (after a tool batch). If no turn is running, the content is
//! left untouched and the client is told to send a normal `session/prompt`.

use agent_client_protocol as acp;

use super::{ExtResult, parse_params};
use crate::agent::MvpAgent;
use crate::session::SessionCommand;

pub const STEER_METHOD: &str = "_session/steering";

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SteerParams {
    session_id: String,
    #[serde(default)]
    prompt: Vec<acp::ContentBlock>,
}

pub async fn handle(agent: &MvpAgent, args: &acp::ExtRequest) -> ExtResult {
    let req: SteerParams = parse_params(args)?;
    let (text, images) = super::content::split_content(req.prompt);
    let text = text.unwrap_or_default();
    if text.trim().is_empty() && images.is_empty() {
        return Err(acp::Error::invalid_params().data("steering prompt is empty"));
    }
    let sid: acp::SessionId = req.session_id.clone().into();
    let Some(session) = agent.session_handle_waiting_for_load(&sid).await else {
        return Err(
            acp::Error::invalid_params().data(format!("session not found: {}", req.session_id)),
        );
    };
    let (tx, rx) = tokio::sync::oneshot::channel();
    if session
        .cmd_tx
        .send(SessionCommand::SteerAcp {
            text,
            images,
            respond_to: tx,
        })
        .is_err()
    {
        return Err(acp::Error::internal_error().data("session is not accepting steering"));
    }
    let injected = rx.await.unwrap_or(false);
    let body = if injected {
        serde_json::json!({ "outcome": "injected" })
    } else {
        serde_json::json!({ "outcome": "promptRequired", "reason": "noRunningTurn" })
    };
    super::to_ext_response(Ok(body))
}

#[cfg(test)]
mod tests {
    use super::SteerParams;

    #[test]
    fn aoe_wire_shape_parses() {
        let req: SteerParams = serde_json::from_value(serde_json::json!({
            "sessionId": "sess-1",
            "prompt": [{ "type": "text", "text": "also check the tests" }],
            "_meta": { "steering": { "idleBehavior": "promptRequired" } }
        }))
        .expect("AoE steer params must parse");
        assert_eq!(req.session_id, "sess-1");
        assert_eq!(req.prompt.len(), 1);
    }
}

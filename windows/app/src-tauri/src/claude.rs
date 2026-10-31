//! Onde está o Claude Code, e como rodá-lo sem piscar uma janela de console no Windows.

use std::path::PathBuf;
use std::process::Command;

/// O instalador oficial põe o `claude` em ~/.local/bin; senão, o primeiro do PATH.
pub fn executable() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "claude.exe" } else { "claude" };
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from);
    let local = home.map(|h| h.join(".local").join("bin").join(exe));
    if let Some(path) = local.filter(|p| p.is_file()) {
        return Some(path);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(exe)).find(|p| p.is_file())
}

/// No Windows, um processo de console lançado por um app de janela abre um console visível: isto esconde.
pub fn hide_console(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = command;
}

#[derive(Clone, serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ModelOption {
    /// O que vai em `--model` ("default", "opus", "claude-fable-5-1[1m]"…).
    pub value: String,
    /// Nome curto com a versão, ex.: "Opus 5.5".
    pub name: String,
    pub detail: String,
    pub efforts: Vec<String>,
}

/// Modelos que a conta oferece, lidos do próprio Claude Code (`initialize` do modo stream-json), para o seletor
/// acompanhar modelos novos sem atualizar o Cawde.
pub fn fetch_models() -> Option<Vec<ModelOption>> {
    use std::io::{BufRead, BufReader, Write};
    let mut command = Command::new(executable()?);
    command
        .args(["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    hide_console(&mut command);
    let mut child = command.spawn().ok()?;
    let mut stdin = child.stdin.take()?;
    let _ = stdin.write_all(b"{\"type\":\"control_request\",\"request_id\":\"init\",\"request\":{\"subtype\":\"initialize\"}}\n");
    let reader = BufReader::new(child.stdout.take()?);
    let mut response = None;
    for line in reader.lines().take(400) {
        let Ok(line) = line else { break };
        let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
        if event.get("type").and_then(|t| t.as_str()) == Some("control_response") {
            response = event.pointer("/response/response").cloned();
            break;
        }
    }
    let _ = child.kill();
    let models = response?.get("models")?.as_array()?.clone();
    // Apelidos ("opus") primeiro; IDs completos que apontam para o mesmo modelo saem.
    let mut seen = std::collections::HashSet::new();
    Some(
        models
            .iter()
            .filter_map(|m| {
                let value = m.get("value")?.as_str()?.to_string();
                let resolved = m.get("resolvedModel").and_then(|v| v.as_str()).unwrap_or(&value).to_string();
                if value != "default" && !seen.insert(resolved.clone()) {
                    return None;
                }
                let name = display_name(&resolved);
                let description = m.get("description").and_then(|v| v.as_str()).unwrap_or_default();
                let detail = description.split_once(" · ").map_or(description, |(_, rest)| rest).to_string();
                let efforts = m.get("supportedEffortLevels").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|e| e.as_str().map(str::to_string)).collect()).unwrap_or_default();
                Some(ModelOption { name: if value == "default" { format!("Padrão ({name})") } else { name }, value, detail, efforts })
            })
            .collect(),
    )
}

/// "claude-opus-5-5[1m]" → "Opus 5.5 · 1M"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
pub fn display_name(resolved: &str) -> String {
    let long_context = resolved.ends_with("[1m]");
    let base = resolved.trim_end_matches("[1m]").trim_start_matches("claude-");
    let mut parts = base.split('-').filter(|p| !(p.len() == 8 && p.chars().all(|c| c.is_ascii_digit())));
    let Some(family) = parts.next() else { return resolved.to_string() };
    let version: Vec<&str> = parts.collect();
    let mut name = family[..1].to_uppercase() + &family[1..];
    if !version.is_empty() {
        name = format!("{name} {}", version.join("."));
    }
    if long_context { format!("{name} · 1M") } else { name }
}

#[cfg(test)]
mod tests {
    #[test]
    fn model_names() {
        assert_eq!(super::display_name("claude-opus-5-5[1m]"), "Opus 5.5 · 1M");
        assert_eq!(super::display_name("claude-haiku-4-5-20251001"), "Haiku 4.5");
        assert_eq!(super::display_name("claude-sonnet-5-5"), "Sonnet 5.5");
    }
}

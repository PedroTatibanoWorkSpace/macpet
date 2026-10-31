//! Itens de uma conversa (o que a interface desenha) e a leitura do histórico a partir do transcript.
//! Mesma lógica do ChatSession.swift do MacPet.

use serde::Serialize;
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// Uma linha: comando, arquivo, padrão buscado…
    pub summary: String,
    /// Conteúdo principal (comando completo, conteúdo escrito, plano…).
    pub detail: Option<String>,
    /// Edit/MultiEdit: trechos antigo e novo.
    pub edits: Vec<(String, String)>,
    pub result: Option<String>,
    pub is_error: bool,
    /// Progresso de um subagente disparado por esta chamada.
    pub child_steps: u32,
    pub child_last: Option<String>,
}

#[derive(Clone, Copy, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum PermissionStatus {
    Pending,
    Allowed,
    Denied,
}

#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Permission {
    pub request_id: String,
    pub tool: ToolCall,
    #[serde(skip)]
    pub input: Value,
    #[serde(skip)]
    pub suggestions: Option<Value>,
    /// Sugestão do Claude Code, ex.: "Aceitar edições nesta sessão".
    pub suggestion_label: Option<String>,
    pub status: PermissionStatus,
}

#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Item {
    User { text: String, images: u32 },
    Assistant { text: String },
    Tool { call: ToolCall },
    Permission { request: Permission },
    #[serde(rename_all = "camelCase")]
    Result { cost: f64, seconds: f64, is_error: bool },
    Notice { text: String },
}

pub fn tool_call(id: &str, name: &str, input: &Value) -> ToolCall {
    let string = |key: &str| input.get(key).and_then(Value::as_str).map(str::to_string);
    let file = string("file_path").or_else(|| string("notebook_path")).or_else(|| string("path")).map(|p| {
        Path::new(&p.replace('\\', "/")).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or(p)
    });
    let summary;
    let mut detail = None;
    let mut edits = Vec::new();
    match name {
        "Bash" | "PowerShell" => {
            summary = string("description").or_else(|| string("command")).unwrap_or_default();
            detail = string("command");
        }
        "Edit" => {
            summary = file.unwrap_or_default();
            edits.push((string("old_string").unwrap_or_default(), string("new_string").unwrap_or_default()));
        }
        "MultiEdit" => {
            summary = file.unwrap_or_default();
            for edit in input.get("edits").and_then(Value::as_array).into_iter().flatten() {
                let s = |k| edit.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
                edits.push((s("old_string"), s("new_string")));
            }
        }
        "Write" => {
            summary = file.unwrap_or_default();
            detail = string("content");
        }
        "Read" => summary = file.unwrap_or_default(),
        "Grep" | "Glob" => summary = string("pattern").unwrap_or_default(),
        "WebFetch" => summary = string("url").unwrap_or_default(),
        "WebSearch" => summary = string("query").unwrap_or_default(),
        "Task" | "Agent" => {
            summary = string("description").unwrap_or_default();
            detail = string("prompt");
        }
        "TodoWrite" => {
            let todos = input.get("todos").and_then(Value::as_array).cloned().unwrap_or_default();
            summary = format!("{} tarefas", todos.len());
            detail = Some(
                todos
                    .iter()
                    .map(|t| {
                        let mark = match t.get("status").and_then(Value::as_str) {
                            Some("completed") => "✓",
                            Some("in_progress") => "▸",
                            _ => "○",
                        };
                        format!("{mark} {}", t.get("content").and_then(Value::as_str).unwrap_or_default())
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
        }
        "ExitPlanMode" => {
            summary = "Plano pronto para aprovação".into();
            detail = string("plan");
        }
        _ => {
            summary = file.unwrap_or_else(|| {
                input.as_object().and_then(|o| o.iter().find_map(|(_, v)| v.as_str().map(str::to_string))).unwrap_or_default()
            });
            detail = serde_json::to_string_pretty(input).ok();
        }
    }
    ToolCall { id: id.into(), name: name.into(), summary, detail, edits, result: None, is_error: false, child_steps: 0, child_last: None }
}

/// Para o cartão de permissão: o caminho inteiro (o card da ferramenta mostra só o nome do arquivo) e a edição
/// em si. É o que separa uma edição de rotina no projeto de uma em ~/.claude ou na pasta de inicialização.
pub fn permission_call(id: &str, name: &str, input: &Value) -> ToolCall {
    let mut call = tool_call(id, name, input);
    let string = |key: &str| input.get(key).and_then(Value::as_str);
    if let Some(path) = string("file_path").or_else(|| string("notebook_path")).or_else(|| string("path")) {
        call.summary = match name {
            "Grep" | "Glob" => format!("{} em {path}", call.summary),
            _ => path.to_string(),
        };
    }
    if call.detail.is_none() && !call.edits.is_empty() {
        let diff = |(old, new): &(String, String)| format!("- {}\n+ {}", old.replace('\n', "\n- "), new.replace('\n', "\n+ "));
        call.detail = Some(call.edits.iter().map(diff).collect::<Vec<_>>().join("\n\n"));
    }
    call
}

pub fn result_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

/// Transcript de uma sessão, na mesma codificação de pasta do Claude Code (tudo que não é letra/número vira "-").
pub fn transcript_path(session_id: &str, cwd: &str) -> PathBuf {
    let encoded: String = cwd.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default();
    home.join(".claude").join("projects").join(encoded).join(format!("{session_id}.jsonl"))
}

/// Quanto do fim do transcript é lido: conversas longas passam de 900 MB; a tela só mostra o final.
const HISTORY_TAIL: u64 = 8_000_000;

/// Reconstrói a conversa a partir do transcript (só a conversa principal, sem subagentes).
pub fn load_history(path: &Path) -> Vec<Item> {
    let Ok(mut file) = std::fs::File::open(path) else { return Vec::new() };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    let offset = size.saturating_sub(HISTORY_TAIL);
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return Vec::new();
    }
    let mut data = Vec::new();
    if file.read_to_end(&mut data).is_err() {
        return Vec::new();
    }
    // Começou no meio de uma linha: descarta até a próxima.
    let start = if offset > 0 { data.iter().position(|&b| b == b'\n').map_or(data.len(), |i| i + 1) } else { 0 };
    let mut items: Vec<Item> = Vec::new();
    let mut tool_index = std::collections::HashMap::new();
    for line in data[start..].split(|&b| b == b'\n') {
        let Ok(json) = serde_json::from_slice::<Value>(line) else { continue };
        if json.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(message) = json.get("message") else { continue };
        match json.get("type").and_then(Value::as_str) {
            Some("user") => {
                if json.get("isMeta").and_then(Value::as_bool) == Some(true) {
                    continue;
                }
                match message.get("content") {
                    Some(Value::String(text)) if !text.starts_with('<') => items.push(Item::User { text: text.clone(), images: 0 }),
                    Some(Value::Array(blocks)) => {
                        let mut texts = Vec::new();
                        let mut images = 0;
                        for block in blocks {
                            match block.get("type").and_then(Value::as_str) {
                                Some("tool_result") => {
                                    let id = block.get("tool_use_id").and_then(Value::as_str).unwrap_or_default();
                                    if let Some(&i) = tool_index.get(id) {
                                        if let Some(Item::Tool { call }) = items.get_mut(i) {
                                            call.result = Some(result_text(block.get("content").unwrap_or(&Value::Null)));
                                            call.is_error = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                                        }
                                    }
                                }
                                Some("text") => {
                                    let text = block.get("text").and_then(Value::as_str).unwrap_or_default();
                                    if !text.starts_with('<') {
                                        texts.push(text.to_string());
                                    }
                                }
                                Some("image") => images += 1,
                                _ => {}
                            }
                        }
                        if !texts.is_empty() || images > 0 {
                            items.push(Item::User { text: texts.join("\n\n"), images });
                        }
                    }
                    _ => {}
                }
            }
            Some("assistant") => {
                for block in message.get("content").and_then(Value::as_array).into_iter().flatten() {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            let text = block.get("text").and_then(Value::as_str).unwrap_or_default();
                            if !text.is_empty() {
                                items.push(Item::Assistant { text: text.into() });
                            }
                        }
                        Some("tool_use") => {
                            let call = tool_call(
                                block.get("id").and_then(Value::as_str).unwrap_or_default(),
                                block.get("name").and_then(Value::as_str).unwrap_or("?"),
                                block.get("input").unwrap_or(&Value::Null),
                            );
                            tool_index.insert(call.id.clone(), items.len());
                            items.push(Item::Tool { call });
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    // Conversas longas: mantém o final, que é o que importa para continuar.
    if items.len() > 400 {
        items.drain(..items.len() - 400);
    }
    items
}

/// Último custo acumulado gravado no transcript (linhas `cost-state`), lendo só o final do arquivo. Ao retomar
/// uma conversa, o custo que o Claude informa é o da sessão inteira: este é o ponto de partida.
pub fn session_cost(path: &Path) -> f64 {
    let Ok(mut file) = std::fs::File::open(path) else { return 0.0 };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = file.seek(SeekFrom::Start(size.saturating_sub(4_000_000)));
    let mut data = Vec::new();
    let _ = file.read_to_end(&mut data);
    for line in data.split(|&b| b == b'\n').rev() {
        if line.len() > 200_000 || !line.windows(12).any(|w| w == b"\"cost-state\"") {
            continue;
        }
        if let Some(cost) = serde_json::from_slice::<Value>(line).ok().and_then(|j| j.get("totalCostUSD").and_then(Value::as_f64)) {
            return cost;
        }
    }
    0.0
}

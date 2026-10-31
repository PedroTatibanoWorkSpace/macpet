//! Uma conversa com o Claude Code num projeto. O `claude` roda no modo stream-json dentro do `cawde-relay`
//! (que o mantém vivo se o Cawde fechar); a sessão escreve em `input.jsonl` e acompanha `out.jsonl`.
//! Pedidos de permissão chegam como `control_request` (`--permission-prompt-tool stdio`). Mesma lógica do
//! ChatSession.swift do MacPet. Não depende do Tauri: quem acompanha a conversa recebe `Update`s.

use super::model::{self, Item, Permission, PermissionStatus};
use serde::Serialize;
use serde_json::{json, Value};
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BackgroundTask {
    pub id: String,
    pub description: String,
    pub is_agent: bool,
}

#[derive(Clone, Serialize, serde::Deserialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// default, acceptEdits, auto, plan
    pub mode: String,
    /// Valor de `--model` ("default" usa o da configuração do Claude Code).
    pub model: String,
    pub effort: Option<String>,
    /// Servidores MCP desligados deixam cada mensagem bem mais leve (o Sonnet carrega todas as ferramentas deles).
    pub uses_mcp: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { mode: "default".into(), model: "default".into(), effort: None, uses_mcp: true }
    }
}

/// O que a interface precisa além dos itens.
#[derive(Clone, Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub running: bool,
    pub stopping: bool,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    pub total_cost: f64,
    pub settings: Settings,
    pub background_tasks: Vec<BackgroundTask>,
    pub pending_permissions: usize,
    pub loading_history: bool,
}

/// Mudanças desde a última atualização: itens novos ou alterados, o estado, ou a conversa inteira de novo.
#[derive(Default, Debug)]
pub struct Update {
    pub items: Vec<(usize, Item)>,
    pub status: Option<Status>,
    pub reset: Option<Vec<Item>>,
    /// `rate_limit_event` da resposta (limites do plano).
    pub rate_limits: Option<Value>,
    /// O Claude pediu permissão (para avisar).
    pub attention: Option<String>,
    /// Terminou um turno (para comemorar).
    pub finished: bool,
    /// Sessão do Claude mudou (para lembrar e retomar depois).
    pub session_changed: bool,
    /// Ordem das atualizações da conversa: a interface descarta as que o retrato de `open` já inclui.
    pub seq: u64,
}

impl Update {
    pub fn is_empty(&self) -> bool {
        self.items.is_empty() && self.status.is_none() && self.reset.is_none() && self.rate_limits.is_none()
            && self.attention.is_none() && !self.finished && !self.session_changed
    }
}

pub type Sink = Arc<dyn Fn(&str, Update) + Send + Sync>;

/// Há um claude rodando (no relay) para esta conversa.
struct Process;

pub struct Session {
    pub project_id: String,
    pub cwd: String,
    dir: PathBuf,
    relay: PathBuf,
    pub items: Vec<Item>,
    pub running: bool,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    pub total_cost: f64,
    pub settings: Settings,
    pub background: Vec<BackgroundTask>,
    pub last_finished: Option<Instant>,
    pub loading_history: bool,
    last_process_cost: f64,
    streaming: Option<usize>,
    turn_started: Option<Instant>,
    stopping: bool,
    stop_token: u64,
    restart_after_turn: bool,
    process: Option<Process>,
    generation: u64,
    history_loaded: bool,
    /// Mudanças acumuladas desde o último envio para a interface.
    pending: Update,
    /// Última atualização entregue (ver `Update::seq`).
    pub seq: u64,
}

pub type Shared = Arc<Mutex<Session>>;

impl Session {
    pub fn new(project_id: &str, cwd: &str, chats_dir: &Path, relay: PathBuf, session_id: Option<String>, settings: Settings) -> Self {
        Session {
            project_id: project_id.into(),
            cwd: cwd.into(),
            dir: chats_dir.join(project_id),
            relay,
            items: Vec::new(),
            running: false,
            session_id,
            model_name: None,
            total_cost: 0.0,
            settings,
            background: Vec::new(),
            last_finished: None,
            loading_history: false,
            last_process_cost: 0.0,
            streaming: None,
            turn_started: None,
            stopping: false,
            stop_token: 0,
            restart_after_turn: false,
            process: None,
            generation: 0,
            history_loaded: false,
            pending: Update::default(),
            seq: 0,
        }
    }

    pub fn status(&self) -> Status {
        Status {
            running: self.running,
            stopping: self.stopping,
            session_id: self.session_id.clone(),
            model_name: self.model_name.clone(),
            total_cost: self.total_cost,
            settings: self.settings.clone(),
            background_tasks: self.background.clone(),
            pending_permissions: self.pending_permissions(),
            loading_history: self.loading_history,
        }
    }

    pub fn pending_permissions(&self) -> usize {
        self.items.iter().filter(|i| matches!(i, Item::Permission { request } if request.status == PermissionStatus::Pending)).count()
    }

    /// Trabalhando, esperando você ou com agentes em segundo plano: o processo precisa continuar vivo.
    pub fn is_busy(&self) -> bool {
        self.running || self.pending_permissions() > 0 || !self.background.is_empty()
    }

    pub fn has_process(&self) -> bool {
        self.process.is_some()
    }

    // MARK: Mudanças para a interface

    fn push(&mut self, item: Item) -> usize {
        self.items.push(item);
        let index = self.items.len() - 1;
        self.changed(index);
        index
    }

    fn changed(&mut self, index: usize) {
        self.pending.items.retain(|(i, _)| *i != index);
        self.pending.items.push((index, self.items[index].clone()));
    }

    fn status_changed(&mut self) {
        self.pending.status = Some(self.status());
    }

    fn notice(&mut self, text: impl Into<String>) {
        self.push(Item::Notice { text: text.into() });
    }

    /// Entrega as mudanças acumuladas.
    pub fn take_update(&mut self) -> Update {
        let mut update = std::mem::take(&mut self.pending);
        if update.status.is_some() {
            update.status = Some(self.status());
        }
        self.seq += 1;
        update.seq = self.seq;
        update
    }

    // MARK: Histórico

    /// Carrega o histórico da conversa (uma vez). Lê o transcript fora da trava, porque pode demorar.
    pub fn load_history_if_needed(shared: &Shared, sink: &Sink) {
        let (path, project) = {
            let mut session = shared.lock().unwrap();
            if session.history_loaded {
                return;
            }
            session.history_loaded = true;
            let Some(id) = session.session_id.clone() else { return };
            session.loading_history = true;
            session.status_changed();
            let update = session.take_update();
            let project = session.project_id.clone();
            let path = model::transcript_path(&id, &session.cwd);
            drop(session);
            sink(&project, update);
            (path, project)
        };
        let shared = shared.clone();
        let sink = sink.clone();
        std::thread::spawn(move || {
            let history = model::load_history(&path);
            let mut session = shared.lock().unwrap();
            // O que chegou enquanto lia fica depois do histórico.
            let mut items = history;
            items.append(&mut session.items);
            session.items = items;
            session.streaming = None;
            session.loading_history = false;
            session.pending.reset = Some(session.items.clone());
            session.pending.items.clear();
            session.status_changed();
            let update = session.take_update();
            drop(session);
            sink(&project, update);
        });
    }

    // MARK: Processo

    fn file(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    fn claude_args(&self) -> Vec<String> {
        let mut args: Vec<String> = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        args.push(self.settings.mode.clone());
        // Perguntas de múltipla escolha não têm interface aqui; o Claude pergunta em texto.
        args.extend(["--disallowedTools".into(), "AskUserQuestion".into()]);
        if self.settings.model != "default" {
            args.extend(["--model".into(), self.settings.model.clone()]);
        }
        if let Some(effort) = &self.settings.effort {
            args.extend(["--effort".into(), effort.clone()]);
        }
        if !self.settings.uses_mcp {
            args.push("--strict-mcp-config".into());
        }
        if let Some(id) = &self.session_id {
            args.extend(["--resume".into(), id.clone()]);
        }
        args
    }

    fn start(shared: &Shared, sink: &Sink) -> Result<(), String> {
        let mut session = shared.lock().unwrap();
        let claude = crate::claude::executable().ok_or("Não encontrei o comando `claude`. Instale o Claude Code e reabra o Cawde.")?;
        // O relay anterior ainda pode estar terminando nesta pasta: o exit.json dele cairia na conversa nova.
        if let Some((pid, written)) = session.meta_pid("relayPid") {
            let deadline = Instant::now() + Duration::from_secs(2);
            while crate::proc::is_alive_since(pid, written) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            if crate::proc::is_alive_since(pid, written) {
                crate::proc::terminate_tree(pid, written);
            }
        }
        let _ = fs::remove_dir_all(&session.dir);
        fs::create_dir_all(&session.dir).map_err(|e| e.to_string())?;
        fs::write(session.file("input.jsonl"), b"").map_err(|e| e.to_string())?;
        let mut args = vec![session.dir.to_string_lossy().into_owned(), session.cwd.clone(), "--".into(), claude.to_string_lossy().into_owned()];
        args.extend(session.claude_args());
        crate::proc::launch_detached(&session.relay, &args).map_err(|e| format!("Falha ao iniciar o Claude: {e}"))?;
        // Ao retomar, o custo que o Claude informa é o acumulado da sessão inteira: parte daí.
        session.last_process_cost = session.session_id.as_ref().map(|id| model::session_cost(&model::transcript_path(id, &session.cwd))).unwrap_or(0.0);
        session.generation += 1;
        let generation = session.generation;
        session.process = Some(Process);
        drop(session);
        Self::follow(shared.clone(), sink.clone(), generation, 0);
        Ok(())
    }

    /// Acompanha `out.jsonl`: lê o que cresceu, atualiza a conversa e manda as mudanças de uma vez por leitura.
    /// Com dados chegando, olha a cada 40 ms; parado, vai espaçando até 400 ms.
    fn follow(shared: Shared, sink: Sink, generation: u64, mut offset: u64) {
        std::thread::spawn(move || {
            let (out, exit) = {
                let s = shared.lock().unwrap();
                (s.file("out.jsonl"), s.file("exit.json"))
            };
            let mut partial: Vec<u8> = Vec::new();
            let mut wait = Duration::from_millis(40);
            loop {
                if shared.lock().unwrap().generation != generation {
                    return;
                }
                let mut chunk = Vec::new();
                if let Ok(mut file) = fs::File::open(&out) {
                    if file.seek(SeekFrom::Start(offset)).is_ok() && file.read_to_end(&mut chunk).is_ok() {
                        offset += chunk.len() as u64;
                    }
                }
                let ended = chunk.is_empty() && exit.exists();
                if !chunk.is_empty() {
                    partial.extend_from_slice(&chunk);
                    let mut session = shared.lock().unwrap();
                    if session.generation != generation {
                        return;
                    }
                    while let Some(end) = partial.iter().position(|&b| b == b'\n') {
                        let line: Vec<u8> = partial.drain(..=end).collect();
                        if let Ok(event) = serde_json::from_slice::<Value>(&line) {
                            session.handle(&event);
                        }
                    }
                    let update = session.take_update();
                    let project = session.project_id.clone();
                    drop(session);
                    if !update.is_empty() {
                        sink(&project, update);
                    }
                    wait = Duration::from_millis(40);
                } else if ended {
                    let mut session = shared.lock().unwrap();
                    if session.generation == generation {
                        let errors = fs::read_to_string(session.file("err.log")).unwrap_or_default();
                        session.process_ended(&errors);
                        let update = session.take_update();
                        let project = session.project_id.clone();
                        drop(session);
                        sink(&project, update);
                    }
                    return;
                } else {
                    wait = (wait * 2).min(Duration::from_millis(400));
                }
                std::thread::sleep(wait);
            }
        });
    }

    fn process_ended(&mut self, errors: &str) {
        if self.running {
            let reason = errors.trim();
            let tail: String = reason.chars().rev().take(600).collect::<Vec<_>>().into_iter().rev().collect();
            self.notice(if reason.is_empty() { "O Claude encerrou.".to_string() } else { format!("O Claude encerrou: {tail}") });
        }
        self.process = None;
        self.running = false;
        self.stopping = false;
        self.streaming = None;
        self.background.clear();
        self.cancel_pending_permissions();
        self.status_changed();
    }

    fn write(&self, object: &Value) {
        if let Ok(mut file) = OpenOptions::new().append(true).create(true).open(self.file("input.jsonl")) {
            let mut line = serde_json::to_vec(object).unwrap_or_default();
            line.push(b'\n');
            let _ = file.write_all(&line);
        }
    }

    fn control(&self, request: Value) {
        self.write(&json!({ "type": "control_request", "request_id": crate::proc::new_id(), "request": request }));
    }

    /// pid do relay ou do claude, lido do meta.json que o relay grava, e quando ele foi gravado (os dois
    /// processos já existiam então; um pid reaproveitado depois é de outro programa).
    fn meta_pid(&self, key: &str) -> Option<(u32, SystemTime)> {
        let path = self.file("meta.json");
        let written = fs::metadata(&path).and_then(|m| m.modified()).ok()?;
        let meta: Value = serde_json::from_str(&fs::read_to_string(&path).ok()?).ok()?;
        meta.get(key).and_then(Value::as_u64).map(|p| (p as u32, written))
    }

    /// Pedidos que ninguém mais vai responder (o processo parou ou o turno foi interrompido) saem de "esperando".
    fn cancel_pending_permissions(&mut self) {
        let pending: Vec<usize> = (0..self.items.len())
            .filter(|&i| matches!(&self.items[i], Item::Permission { request } if request.status == PermissionStatus::Pending))
            .collect();
        for index in pending {
            if let Item::Permission { request } = &mut self.items[index] {
                request.status = PermissionStatus::Denied;
            }
            self.changed(index);
        }
    }

    /// Encerra o claude desta conversa (e os agentes em segundo plano dele). A conversa continua com --resume.
    pub fn stop(&mut self) {
        // Sem processo nosso ou com exit.json, o pid do meta.json é de uma execução que já acabou.
        if self.process.is_some() && !self.file("exit.json").exists() {
            if let Some((pid, written)) = self.meta_pid("claudePid") {
                crate::proc::terminate_tree(pid, written);
            }
        }
        self.cancel_pending_permissions();
        self.generation += 1;
        self.process = None;
        self.running = false;
        self.stopping = false;
        self.streaming = None;
        self.background.clear();
        self.status_changed();
    }

    // MARK: Ações

    /// Também com o Claude trabalhando: o Claude Code lê a mensagem no próximo passo, no mesmo turno.
    pub fn send(shared: &Shared, sink: &Sink, text: &str) {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }
        if trimmed == "/clear" {
            let mut session = shared.lock().unwrap();
            session.new_conversation();
            Self::deliver(session, sink);
            return;
        }
        let needs_start = !shared.lock().unwrap().has_process();
        if needs_start {
            if let Err(message) = Self::start(shared, sink) {
                let mut session = shared.lock().unwrap();
                session.notice(message);
                Self::deliver(session, sink);
                return;
            }
        }
        let mut session = shared.lock().unwrap();
        session.push(Item::User { text: trimmed.into(), images: 0 });
        if !session.running {
            session.running = true;
            session.turn_started = Some(Instant::now());
        }
        session.write(&json!({ "type": "user", "message": { "role": "user", "content": trimmed } }));
        session.status_changed();
        Self::deliver(session, sink);
    }

    /// Entrega as mudanças fora da trava da sessão: o sink trava a lista de projetos, e quem lista os projetos
    /// trava as sessões (ordens opostas travariam as duas threads).
    fn deliver(mut session: std::sync::MutexGuard<'_, Session>, sink: &Sink) {
        let update = session.take_update();
        let project = session.project_id.clone();
        drop(session);
        sink(&project, update);
    }

    /// Parar: pede para o Claude interromper. Se em 6 s ele não parar, ou se apertar de novo, encerra o processo.
    pub fn interrupt(shared: &Shared, sink: &Sink) {
        let mut session = shared.lock().unwrap();
        if !session.running {
            return;
        }
        if session.stopping {
            session.force_stop();
        } else {
            session.stopping = true;
            session.stop_token += 1;
            let token = session.stop_token;
            session.control(json!({ "subtype": "interrupt" }));
            session.notice("Parando…");
            session.status_changed();
            let (shared, sink) = (shared.clone(), sink.clone());
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(6));
                let mut session = shared.lock().unwrap();
                if session.running && session.stopping && session.stop_token == token {
                    session.force_stop();
                    Self::deliver(session, &sink);
                }
            });
        }
        Self::deliver(session, sink);
    }

    fn force_stop(&mut self) {
        self.stop();
        self.notice("O Claude não respondeu ao pedido de parar, então encerrei. A conversa continua: é só mandar a próxima mensagem.");
    }

    pub fn respond(&mut self, request_id: &str, allow: bool, apply_suggestion: bool) {
        let Some(index) = self.items.iter().position(|i| matches!(i, Item::Permission { request } if request.request_id == request_id)) else { return };
        let Item::Permission { request } = &mut self.items[index] else { return };
        if request.status != PermissionStatus::Pending {
            return;
        }
        let mut response = if allow {
            json!({ "behavior": "allow", "updatedInput": request.input })
        } else {
            json!({ "behavior": "deny", "message": "O usuário negou esta ação. Pergunte como ele prefere seguir." })
        };
        let mut new_mode = None;
        if allow && apply_suggestion {
            if let Some(suggestions) = &request.suggestions {
                response["updatedPermissions"] = suggestions.clone();
                new_mode = suggestions.as_array().and_then(|list| {
                    list.iter().find(|s| s.get("type").and_then(Value::as_str) == Some("setMode")).and_then(|s| s.get("mode").and_then(Value::as_str)).map(str::to_string)
                });
            }
        }
        request.status = if allow { PermissionStatus::Allowed } else { PermissionStatus::Denied };
        let request_id = request.request_id.clone();
        if let Some(mode) = new_mode {
            self.settings.mode = mode;
        }
        self.write(&json!({ "type": "control_response", "response": { "subtype": "success", "request_id": request_id, "response": response } }));
        self.changed(index);
        self.status_changed();
    }

    pub fn set_mode(&mut self, mode: &str) {
        self.settings.mode = mode.into();
        if self.process.is_some() {
            self.control(json!({ "subtype": "set_permission_mode", "mode": mode }));
        }
        self.status_changed();
    }

    pub fn set_model(&mut self, model: &str) {
        if self.settings.model == model {
            return;
        }
        self.settings.model = model.into();
        if self.process.is_some() {
            if model == "default" { self.restart_for_new_settings() } else { self.control(json!({ "subtype": "set_model", "model": model })) }
        }
        self.status_changed();
    }

    pub fn set_effort(&mut self, effort: Option<String>) {
        if self.settings.effort == effort {
            return;
        }
        self.settings.effort = effort;
        self.restart_for_new_settings();
        self.status_changed();
    }

    pub fn set_uses_mcp(&mut self, enabled: bool) {
        if self.settings.uses_mcp == enabled {
            return;
        }
        self.settings.uses_mcp = enabled;
        self.restart_for_new_settings();
        self.status_changed();
    }

    /// Esforço e MCP são fixados ao iniciar o processo: reinicia com --resume (a conversa continua igual),
    /// depois do turno e dos agentes em segundo plano.
    fn restart_for_new_settings(&mut self) {
        if self.process.is_none() {
            return;
        }
        if self.is_busy() { self.restart_after_turn = true } else { self.stop() }
    }

    /// Começa do zero (a conversa anterior continua nas sessões do Claude Code).
    pub fn new_conversation(&mut self) {
        self.stop();
        self.items.clear();
        self.session_id = None;
        self.total_cost = 0.0;
        self.history_loaded = true;
        self.pending.reset = Some(Vec::new());
        self.pending.items.clear();
        self.pending.session_changed = true;
        self.status_changed();
    }

    /// Ao fechar o Cawde: conversa ocupada continua rodando (e é retomada na próxima abertura); ociosa é encerrada.
    pub fn shutdown(&mut self) {
        if self.is_busy() {
            self.generation += 1; // para de acompanhar; o relay segue sozinho
        } else if self.process.is_some() {
            self.stop();
        }
    }

    // MARK: Reconectar

    /// Reconecta a um relay que continuou rodando enquanto o Cawde estava fechado.
    pub fn attach_if_running(shared: &Shared, sink: &Sink) -> bool {
        let mut session = shared.lock().unwrap();
        let dir = session.dir.clone();
        if !dir.join("meta.json").exists() || dir.join("exit.json").exists() {
            return false;
        }
        // Depois de reiniciar o PC não há exit.json, e o pid do relay pode ser hoje de outro programa.
        let relay_alive = session.meta_pid("relayPid").is_some_and(|(pid, written)| crate::proc::is_alive_since(pid, written));
        if !relay_alive {
            return false;
        }
        let out = fs::read(dir.join("out.jsonl")).unwrap_or_default();
        let offset = out.len() as u64;
        let lines: Vec<Value> = out.split(|&b| b == b'\n').filter_map(|l| serde_json::from_slice(l).ok()).collect();
        if let Some(init) = lines.iter().find(|e| e.get("subtype").and_then(Value::as_str) == Some("init")) {
            session.model_name = init.get("model").and_then(Value::as_str).map(str::to_string);
            if let Some(id) = init.get("session_id").and_then(Value::as_str) {
                if session.session_id.as_deref() != Some(id) {
                    session.session_id = Some(id.into());
                    session.pending.session_changed = true;
                }
            }
        }
        let last_result = lines.iter().rposition(|e| e.get("type").and_then(Value::as_str) == Some("result"));
        let results = lines.iter().filter(|e| e.get("type").and_then(Value::as_str) == Some("result")).count();
        let inputs = fs::read_to_string(dir.join("input.jsonl")).unwrap_or_default();
        let users = inputs.lines().filter(|l| l.contains("\"type\":\"user\"")).count();
        let after = last_result.map_or(0, |i| i + 1);
        let auto_turn = lines[after..].iter().any(|e| e.get("subtype").and_then(Value::as_str) == Some("init"));
        session.last_process_cost = lines.iter().rev().find_map(|e| e.get("total_cost_usd").and_then(Value::as_f64)).unwrap_or(0.0);
        if let Some(tasks) = lines.iter().rev().find(|e| e.get("subtype").and_then(Value::as_str) == Some("background_tasks_changed")) {
            session.background = background_tasks(tasks);
        }
        session.running = users > results || auto_turn;
        session.generation += 1;
        let generation = session.generation;
        session.process = Some(Process);
        if session.running {
            session.turn_started = Some(Instant::now());
            session.notice("O Claude continuou trabalhando enquanto o Cawde estava fechado.");
        }
        // Pedidos de permissão feitos com o Cawde fechado (e ainda sem resposta).
        let answered: Vec<&str> = inputs.lines().filter(|l| l.contains("control_response")).collect();
        for event in &lines[after..] {
            if event.get("type").and_then(Value::as_str) == Some("control_request") {
                let id = event.get("request_id").and_then(Value::as_str).unwrap_or_default();
                if !answered.iter().any(|l| l.contains(id)) {
                    session.handle(event);
                }
            }
        }
        session.status_changed();
        let update = session.take_update();
        let project = session.project_id.clone();
        drop(session);
        sink(&project, update);
        Self::follow(shared.clone(), sink.clone(), generation, offset);
        true
    }

    // MARK: Eventos do Claude

    fn handle(&mut self, event: &Value) {
        let kind = event.get("type").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "system" => match event.get("subtype").and_then(Value::as_str) {
                Some("init") => {
                    if let Some(id) = event.get("session_id").and_then(Value::as_str) {
                        if self.session_id.as_deref() != Some(id) {
                            self.session_id = Some(id.into());
                            self.pending.session_changed = true;
                        }
                    }
                    // Turno sem mensagem sua: o Claude voltou sozinho (terminou um agente em segundo plano).
                    if !self.running {
                        self.running = true;
                        self.turn_started = Some(Instant::now());
                    }
                    self.model_name = event.get("model").and_then(Value::as_str).map(str::to_string);
                    self.status_changed();
                }
                Some("background_tasks_changed") => {
                    self.background = background_tasks(event);
                    self.status_changed();
                }
                Some("task_notification") => {
                    let id = event.get("task_id").and_then(Value::as_str);
                    let task = self.background.iter().find(|t| Some(t.id.as_str()) == id).cloned();
                    let what = task.as_ref().map_or("Tarefa em segundo plano", |t| if t.is_agent { "Agente em segundo plano" } else { "Comando em segundo plano" });
                    let verb = match event.get("status").and_then(Value::as_str) {
                        Some("completed") => "terminou",
                        Some("killed") | Some("stopped") => "foi interrompido",
                        _ => "falhou",
                    };
                    let name = task.map(|t| format!(": {}", t.description)).unwrap_or_default();
                    self.notice(format!("{what} {verb}{name}"));
                }
                _ => {}
            },
            "stream_event" => {
                let Some(inner) = event.get("event") else { return };
                if event.get("parent_tool_use_id").and_then(Value::as_str).is_some() {
                    return;
                }
                match inner.get("type").and_then(Value::as_str) {
                    Some("content_block_start") if inner.pointer("/content_block/type").and_then(Value::as_str) == Some("text") => {
                        self.streaming = Some(self.push(Item::Assistant { text: String::new() }));
                    }
                    Some("content_block_delta") => {
                        let Some(text) = inner.pointer("/delta/text").and_then(Value::as_str) else { return };
                        if let Some(index) = self.streaming {
                            if let Some(Item::Assistant { text: current }) = self.items.get_mut(index) {
                                current.push_str(text);
                                self.changed(index);
                            }
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                let content = event.pointer("/message/content").and_then(Value::as_array).cloned().unwrap_or_default();
                // Mensagens de subagentes viram progresso no card do agente que os disparou.
                if let Some(parent) = event.get("parent_tool_use_id").and_then(Value::as_str) {
                    self.record_child_activity(parent, &content);
                    return;
                }
                for block in &content {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            let text = block.get("text").and_then(Value::as_str).unwrap_or_default().to_string();
                            if let Some(index) = self.streaming.take() {
                                self.items[index] = Item::Assistant { text };
                                self.changed(index);
                            } else if !text.is_empty() {
                                self.push(Item::Assistant { text });
                            }
                        }
                        Some("tool_use") => {
                            let call = model::tool_call(
                                block.get("id").and_then(Value::as_str).unwrap_or_default(),
                                block.get("name").and_then(Value::as_str).unwrap_or("?"),
                                block.get("input").unwrap_or(&Value::Null),
                            );
                            if !self.items.iter().any(|i| matches!(i, Item::Tool { call: c } if c.id == call.id)) {
                                self.push(Item::Tool { call });
                            }
                        }
                        _ => {}
                    }
                }
            }
            "user" => {
                if event.get("parent_tool_use_id").and_then(Value::as_str).is_some() {
                    return;
                }
                for block in event.pointer("/message/content").and_then(Value::as_array).into_iter().flatten() {
                    if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                        continue;
                    }
                    let id = block.get("tool_use_id").and_then(Value::as_str).unwrap_or_default();
                    let text = model::result_text(block.get("content").unwrap_or(&Value::Null));
                    let is_error = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                    if let Some(index) = self.items.iter().rposition(|i| matches!(i, Item::Tool { call } if call.id == id)) {
                        if let Item::Tool { call } = &mut self.items[index] {
                            call.result = Some(text);
                            call.is_error = is_error;
                        }
                        self.changed(index);
                    }
                }
            }
            "rate_limit_event" => self.pending.rate_limits = event.get("rate_limit_info").cloned(),
            "control_request" => {
                let Some(request) = event.get("request") else { return };
                if request.get("subtype").and_then(Value::as_str) != Some("can_use_tool") {
                    return;
                }
                let request_id = event.get("request_id").and_then(Value::as_str).unwrap_or_default().to_string();
                let input = request.get("input").cloned().unwrap_or(Value::Null);
                let tool = model::permission_call(
                    request.get("tool_use_id").and_then(Value::as_str).unwrap_or(&request_id),
                    request.get("tool_name").and_then(Value::as_str).unwrap_or("?"),
                    &input,
                );
                let suggestions = request.get("permission_suggestions").cloned().filter(|s| s.as_array().is_some_and(|a| !a.is_empty()));
                let suggestion_label = suggestions.as_ref().map(|s| {
                    let accept_edits = s.as_array().into_iter().flatten().any(|x| x.get("type").and_then(Value::as_str) == Some("setMode") && x.get("mode").and_then(Value::as_str) == Some("acceptEdits"));
                    if accept_edits { "Aceitar edições nesta sessão".to_string() } else { "Sempre permitir isto".to_string() }
                });
                let attention = if tool.summary.is_empty() { tool.name.clone() } else { format!("{}: {}", tool.name, tool.summary) };
                self.push(Item::Permission { request: Permission { request_id, tool, input, suggestions, suggestion_label, status: PermissionStatus::Pending } });
                self.pending.attention = Some(attention);
                self.status_changed();
            }
            // O Claude desistiu de um pedido (ex.: o turno foi interrompido).
            "control_cancel_request" => {
                let id = event.get("request_id").and_then(Value::as_str).unwrap_or_default();
                let found = self.items.iter().position(|i| matches!(i, Item::Permission { request } if request.request_id == id && request.status == PermissionStatus::Pending));
                if let Some(index) = found {
                    if let Item::Permission { request } = &mut self.items[index] {
                        request.status = PermissionStatus::Denied;
                    }
                    self.changed(index);
                    self.status_changed();
                }
            }
            "result" => {
                self.running = false;
                if self.stopping {
                    // Interrompido: os pedidos abertos deste turno não serão mais respondidos.
                    self.cancel_pending_permissions();
                    self.notice("Parado.");
                }
                self.stopping = false;
                self.streaming = None;
                let total = event.get("total_cost_usd").and_then(Value::as_f64).unwrap_or(0.0);
                let cost = if total >= self.last_process_cost { total - self.last_process_cost } else { total };
                self.last_process_cost = total;
                self.total_cost += cost;
                let seconds = self.turn_started.map_or(0.0, |t| t.elapsed().as_secs_f64());
                let is_error = event.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                self.push(Item::Result { cost, seconds, is_error });
                if is_error {
                    if let Some(message) = event.get("result").and_then(Value::as_str) {
                        self.notice(message.to_string());
                    }
                }
                self.last_finished = Some(Instant::now());
                self.pending.finished = true;
                // Com agentes em segundo plano, espera: o Claude volta sozinho quando eles terminarem.
                if self.restart_after_turn && self.background.is_empty() {
                    self.restart_after_turn = false;
                    self.stop();
                }
                self.status_changed();
            }
            _ => {}
        }
    }

    fn record_child_activity(&mut self, parent: &str, content: &[Value]) {
        let Some(index) = self.items.iter().rposition(|i| matches!(i, Item::Tool { call } if call.id == parent)) else { return };
        if let Item::Tool { call } = &mut self.items[index] {
            for block in content {
                match block.get("type").and_then(Value::as_str) {
                    Some("tool_use") => {
                        let child = model::tool_call("", block.get("name").and_then(Value::as_str).unwrap_or("?"), block.get("input").unwrap_or(&Value::Null));
                        call.child_steps += 1;
                        call.child_last = Some(format!("{} {}", child.name, child.summary));
                    }
                    Some("text") => {
                        let text = block.get("text").and_then(Value::as_str).unwrap_or_default();
                        if !text.is_empty() {
                            call.child_last = Some(text.replace('\n', " ").chars().take(160).collect());
                        }
                    }
                    _ => {}
                }
            }
        }
        self.changed(index);
    }
}

fn background_tasks(event: &Value) -> Vec<BackgroundTask> {
    event
        .get("tasks")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        // "ambient" (ex.: o observador de um artefato publicado) nunca termina: não é trabalho pendente.
        .filter(|t| t.get("ambient").and_then(Value::as_bool) != Some(true))
        .filter_map(|t| {
            Some(BackgroundTask {
                id: t.get("task_id")?.as_str()?.into(),
                description: t.get("description").and_then(Value::as_str).unwrap_or_default().into(),
                is_agent: t.get("task_type").and_then(Value::as_str).is_some_and(|k| k.contains("agent")),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> (Shared, Sink) {
        let dir = std::env::temp_dir().join(format!("cawde-session-test-{}", crate::proc::new_id()));
        fs::create_dir_all(dir.join("p")).unwrap();
        let shared = Arc::new(Mutex::new(Session::new("p", "/tmp", &dir, PathBuf::from("relay"), None, Settings::default())));
        (shared, Arc::new(|_: &str, _: Update| {}))
    }

    fn feed(shared: &Shared, _sink: &Sink, lines: &[&str]) {
        let mut s = shared.lock().unwrap();
        for line in lines {
            s.handle(&serde_json::from_str(line).unwrap());
        }
    }

    #[test]
    fn streams_text_tools_permissions_and_cost() {
        let (shared, sink) = session();
        shared.lock().unwrap().running = true;
        feed(&shared, &sink, &[
            r#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5"}"#,
            r#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}"#,
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Vou "}}}"#,
            r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"olhar."}}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Vou olhar."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"Listar arquivos"}}]}}"#,
            r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"t1","input":{"command":"ls"},"permission_suggestions":[{"type":"addRules"}]}}"#,
        ]);
        {
            let s = shared.lock().unwrap();
            assert_eq!(s.session_id.as_deref(), Some("s1"));
            assert_eq!(s.items[0], Item::Assistant { text: "Vou olhar.".into() });
            assert!(matches!(&s.items[1], Item::Tool { call } if call.summary == "Listar arquivos"));
            assert_eq!(s.pending_permissions(), 1);
        }
        shared.lock().unwrap().respond("r1", true, false);
        feed(&shared, &sink, &[
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt\nb.txt"}]}}"#,
            r#"{"type":"result","total_cost_usd":0.25,"is_error":false}"#,
        ]);
        let s = shared.lock().unwrap();
        assert!(matches!(&s.items[1], Item::Tool { call } if call.result.as_deref() == Some("a.txt\nb.txt")));
        assert_eq!(s.pending_permissions(), 0);
        assert!(!s.running);
        assert!((s.total_cost - 0.25).abs() < 1e-9);
        let input = fs::read_to_string(s.file("input.jsonl")).unwrap_or_default();
        assert!(input.contains("\"behavior\":\"allow\""), "a resposta da permissão vai para o input do relay");
    }

    #[test]
    fn background_tasks_keep_the_process_busy() {
        let (shared, sink) = session();
        feed(&shared, &sink, &[
            r#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_agent","description":"Revisar"}]}"#,
        ]);
        assert!(shared.lock().unwrap().is_busy());
        feed(&shared, &sink, &[
            r#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_agent","description":"Revisar"},{"task_id":"w1","task_type":"monitor_ws","description":"live updates for artifact","ambient":true}]}"#,
        ]);
        assert_eq!(shared.lock().unwrap().background.len(), 1, "o observador de artefato não conta como segundo plano");
        feed(&shared, &sink, &[
            r#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed"}"#,
            r#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#,
        ]);
        let s = shared.lock().unwrap();
        assert!(!s.is_busy());
        assert_eq!(s.items.last(), Some(&Item::Notice { text: "Agente em segundo plano terminou: Revisar".into() }));
    }

    #[test]
    fn permission_card_shows_full_path_and_the_edit() {
        let (shared, sink) = session();
        feed(&shared, &sink, &[
            r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Edit","tool_use_id":"t1","input":{"file_path":"C:\\Users\\u\\.claude\\settings.json","old_string":"{}","new_string":"{\"hooks\":1}"}}}"#,
        ]);
        let s = shared.lock().unwrap();
        let Item::Permission { request } = &s.items[0] else { panic!("esperava um pedido de permissão") };
        assert_eq!(request.tool.summary, r"C:\Users\u\.claude\settings.json");
        assert_eq!(request.tool.detail.as_deref(), Some("- {}\n+ {\"hooks\":1}"));
        assert_eq!(model::tool_call("t1", "Edit", &request.input).summary, "settings.json", "o card comum segue curto");
    }

    #[test]
    fn stopping_resolves_open_permissions() {
        let (shared, sink) = session();
        let ask = |id: &str| format!(r#"{{"type":"control_request","request_id":"{id}","request":{{"subtype":"can_use_tool","tool_name":"Bash","input":{{"command":"ls"}}}}}}"#);
        shared.lock().unwrap().running = true;
        feed(&shared, &sink, &[&ask("r1"), &ask("r2"), r#"{"type":"control_cancel_request","request_id":"r1"}"#]);
        assert_eq!(shared.lock().unwrap().pending_permissions(), 1, "o Claude desistiu do r1");
        // Parar: o turno termina interrompido e o r2 não será mais respondido.
        shared.lock().unwrap().stopping = true;
        feed(&shared, &sink, &[r#"{"type":"result","total_cost_usd":0.1,"is_error":false}"#]);
        assert_eq!(shared.lock().unwrap().pending_permissions(), 0);
        assert!(!shared.lock().unwrap().is_busy());
        // Responder um cartão velho não manda nada ao Claude.
        shared.lock().unwrap().respond("r2", true, false);
        let s = shared.lock().unwrap();
        assert!(!fs::read_to_string(s.file("input.jsonl")).unwrap_or_default().contains("control_response"));
        drop(s);
        // E o processo encerrado também libera os pedidos.
        feed(&shared, &sink, &[&ask("r3")]);
        shared.lock().unwrap().stop();
        assert_eq!(shared.lock().unwrap().pending_permissions(), 0);
    }

    #[test]
    fn updates_are_numbered_in_order() {
        let (shared, _) = session();
        let mut s = shared.lock().unwrap();
        let first = s.take_update().seq;
        s.notice("oi");
        assert!(s.take_update().seq > first);
        assert_eq!(s.seq, first + 1);
    }

    /// De ponta a ponta com o Claude de verdade (Haiku, pasta temporária, pelo relay). Usa a conta: rode com
    /// `cargo build --release -p cawde-relay && cargo test -p cawde -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn real_claude_text_permission_and_cost() {
        let relay = std::env::current_dir().unwrap().join("../../target/release").join(if cfg!(windows) { "cawde-relay.exe" } else { "cawde-relay" });
        assert!(relay.exists(), "compile o relay antes: {relay:?}");
        let work = std::env::temp_dir().join(format!("cawde-e2e-{}", crate::proc::new_id()));
        fs::create_dir_all(&work).unwrap();
        let chats = work.join("chats");
        let settings = Settings { model: "haiku".into(), uses_mcp: false, ..Settings::default() };
        let shared = Arc::new(Mutex::new(Session::new("e2e", &work.to_string_lossy(), &chats, relay, None, settings)));
        let sink: Sink = Arc::new(|_: &str, _: Update| {});
        let wait = |what: &str, done: &dyn Fn(&Session) -> bool| {
            let deadline = Instant::now() + Duration::from_secs(90);
            while !done(&shared.lock().unwrap()) {
                assert!(Instant::now() < deadline, "tempo esgotado esperando {what}");
                std::thread::sleep(Duration::from_millis(200));
            }
        };
        Session::send(&shared, &sink, "Reply with exactly the word PONG.");
        wait("a primeira resposta", &|s| !s.running && s.items.iter().any(|i| matches!(i, Item::Result { .. })));
        assert!(shared.lock().unwrap().items.iter().any(|i| matches!(i, Item::Assistant { text } if text.contains("PONG"))));
        // Criar arquivo sempre pede permissão no modo padrão (um `echo` o Claude Code libera sozinho).
        Session::send(&shared, &sink, "Use the Write tool to create the file note.txt containing exactly CAWDE-OK. Then reply: done.");
        wait("o pedido de permissão", &|s| s.pending_permissions() > 0);
        let request = shared.lock().unwrap().items.iter().find_map(|i| match i {
            Item::Permission { request } if request.status == PermissionStatus::Pending => Some(request.request_id.clone()),
            _ => None,
        }).unwrap();
        shared.lock().unwrap().respond(&request, true, false);
        wait("o fim do turno", &|s| !s.running && s.items.iter().filter(|i| matches!(i, Item::Result { .. })).count() >= 2);
        let s = shared.lock().unwrap();
        assert!(s.items.iter().any(|i| matches!(i, Item::Tool { call } if call.name == "Write" && !call.is_error)));
        assert_eq!(fs::read_to_string(work.join("note.txt")).unwrap_or_default().trim(), "CAWDE-OK", "o arquivo foi criado depois da permissão");
        assert!(s.total_cost > 0.0);
        assert!(s.session_id.is_some());
        println!("itens: {} · custo: US$ {:.4} · sessão: {:?}", s.items.len(), s.total_cost, s.session_id);
        drop(s);
        shared.lock().unwrap().stop();
    }
}

//! Conversas de todos os projetos. O estado mora aqui, no núcleo: fechar o painel destrói a WebView, mas as
//! conversas seguem (no relay) e reaparecem inteiras ao reabrir. A interface recebe só o que mudou (evento "chat").

pub mod model;
pub mod session;

use crate::projects::{Project, Projects};
use serde::Serialize;
use serde_json::Value;
use session::{Session, Shared, Sink, Status, Update};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatEvent {
    pub project_id: String,
    pub items: Vec<IndexedItem>,
    pub status: Option<Status>,
    pub reset: Option<Vec<model::Item>>,
    pub seq: u64,
}

#[derive(Clone, Serialize)]
pub struct IndexedItem {
    pub index: usize,
    pub item: model::Item,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub items: Vec<model::Item>,
    pub status: Status,
    /// Atualizações até esta já estão no retrato.
    pub seq: u64,
}

/// Projeto com o estado da conversa, para a barra lateral.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectRow {
    #[serde(flatten)]
    pub project: Project,
    /// "working" | "waiting" | null
    pub activity: Option<&'static str>,
}

/// O corvo da área de notificação acompanha as conversas.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    Idle,
    Working,
    Waiting,
    Celebrating,
}

pub struct ChatManager {
    pub projects: Arc<Mutex<Projects>>,
    sessions: Mutex<HashMap<String, Shared>>,
    chats_dir: PathBuf,
    relay: PathBuf,
    sink: Sink,
}

impl ChatManager {
    /// `on_limits`: limites do plano que chegam em cada resposta. `on_attention`: o Claude pediu permissão.
    pub fn new(app: AppHandle, data_dir: PathBuf, relay: PathBuf, on_limits: impl Fn(&Value) + Send + Sync + 'static) -> Arc<Self> {
        let projects = Arc::new(Mutex::new(Projects::load(data_dir.join("projects.json"))));
        let store = projects.clone();
        let sink: Sink = Arc::new(move |project_id: &str, update: Update| {
            if let Some(info) = &update.rate_limits {
                on_limits(info);
            }
            if update.session_changed {
                let id = update.status.as_ref().and_then(|s| s.session_id.clone());
                store.lock().unwrap().update(project_id, |p| p.last_session_id = id);
            }
            if let Some(status) = &update.status {
                let settings = status.settings.clone();
                let mut projects = store.lock().unwrap();
                if projects.get(project_id).is_some_and(|p| p.settings != settings) {
                    projects.update(project_id, |p| p.settings = settings);
                }
            }
            let event = ChatEvent {
                project_id: project_id.into(),
                items: update.items.into_iter().map(|(index, item)| IndexedItem { index, item }).collect(),
                status: update.status,
                reset: update.reset,
                seq: update.seq,
            };
            let _ = app.emit("chat", event);
        });
        Arc::new(ChatManager { projects, sessions: Mutex::new(HashMap::new()), chats_dir: data_dir.join("chats"), relay, sink })
    }

    fn session(&self, project_id: &str) -> Option<Shared> {
        if let Some(existing) = self.sessions.lock().unwrap().get(project_id) {
            return Some(existing.clone());
        }
        let project = self.projects.lock().unwrap().get(project_id)?.clone();
        let session = Arc::new(Mutex::new(Session::new(
            &project.id, &project.path, &self.chats_dir, self.relay.clone(), project.last_session_id.clone(), project.settings.clone(),
        )));
        self.sessions.lock().unwrap().insert(project.id.clone(), session.clone());
        Some(session)
    }

    /// Ao abrir o Cawde: reconecta às conversas que continuaram rodando com ele fechado.
    pub fn attach_running(&self) {
        let ids: Vec<String> = self.projects.lock().unwrap().list.iter().map(|p| p.id.clone()).collect();
        for id in ids {
            if self.chats_dir.join(&id).join("meta.json").exists() {
                if let Some(session) = self.session(&id) {
                    Session::attach_if_running(&session, &self.sink);
                }
            }
        }
    }

    pub fn rows(&self) -> Vec<ProjectRow> {
        // Solta a lista de projetos antes de travar as sessões: quem entrega mudanças trava a sessão e depois os projetos.
        let list = self.projects.lock().unwrap().list.clone();
        let sessions = self.sessions.lock().unwrap();
        list.into_iter()
            .map(|p| {
                let activity = sessions.get(&p.id).and_then(|s| {
                    let s = s.lock().unwrap();
                    if s.pending_permissions() > 0 { Some("waiting") } else if s.running { Some("working") } else { None }
                });
                ProjectRow { project: p, activity }
            })
            .collect()
    }

    pub fn open(&self, project_id: &str) -> Option<Snapshot> {
        let session = self.session(project_id)?;
        Session::load_history_if_needed(&session, &self.sink);
        let s = session.lock().unwrap();
        Some(Snapshot { items: s.items.clone(), status: s.status(), seq: s.seq })
    }

    pub fn send(&self, project_id: &str, text: &str) {
        if let Some(session) = self.session(project_id) {
            Session::send(&session, &self.sink, text);
        }
    }

    pub fn interrupt(&self, project_id: &str) {
        if let Some(session) = self.session(project_id) {
            Session::interrupt(&session, &self.sink);
        }
    }

    /// Ações simples sobre a sessão, que depois entregam o que mudou.
    pub fn with(&self, project_id: &str, action: impl FnOnce(&mut Session)) {
        if let Some(session) = self.session(project_id) {
            let mut s = session.lock().unwrap();
            action(&mut s);
            let update = s.take_update();
            drop(s);
            (self.sink)(project_id, update);
        }
    }

    pub fn remove(&self, project_id: &str) {
        let removed = self.sessions.lock().unwrap().remove(project_id);
        if let Some(session) = removed {
            session.lock().unwrap().stop();
        }
        self.projects.lock().unwrap().remove(project_id);
    }

    pub fn activity(&self) -> Activity {
        let sessions = self.sessions.lock().unwrap();
        let mut activity = Activity::Idle;
        for session in sessions.values() {
            let s = session.lock().unwrap();
            if s.pending_permissions() > 0 {
                return Activity::Waiting;
            }
            if s.running {
                activity = Activity::Working;
            } else if activity == Activity::Idle && s.last_finished.is_some_and(|t| t.elapsed() < Duration::from_secs(8)) {
                activity = Activity::Celebrating;
            }
        }
        activity
    }

    /// Ao sair: conversa ocupada continua no relay; ociosa é encerrada.
    pub fn shutdown(&self) {
        for session in self.sessions.lock().unwrap().values() {
            session.lock().unwrap().shutdown();
        }
    }

    /// Só para a captura do CI: uma conversa de exemplo, sem processo, para ver o painel desenhado.
    pub fn add_demo(&self, transcript: &str) -> Option<String> {
        let dir = std::env::temp_dir().join("cawde-demo");
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("demo.jsonl");
        std::fs::write(&file, transcript).ok()?;
        let project = self.projects.lock().unwrap().add(&dir);
        let session = self.session(&project.id)?;
        let mut s = session.lock().unwrap();
        s.items = model::load_history(&file);
        s.total_cost = 0.42;
        Some(project.id)
    }
}

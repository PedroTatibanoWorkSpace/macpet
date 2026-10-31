//! Projetos do painel (pastas onde você conversa com o Claude), guardados em `projects.json`.

use crate::chat::session::Settings;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: String,
    pub path: String,
    pub name: String,
    pub color: String,
    /// Última conversa com o Claude, retomada ao reabrir.
    pub last_session_id: Option<String>,
    #[serde(default)]
    pub settings: Settings,
}

const COLORS: [&str; 8] = ["violet", "teal", "pumpkin", "rose", "sky", "sage", "sand", "slate"];

pub struct Projects {
    file: PathBuf,
    pub list: Vec<Project>,
}

impl Projects {
    pub fn load(file: PathBuf) -> Self {
        let list = std::fs::read_to_string(&file).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        Projects { file, list }
    }

    pub fn save(&self) {
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&self.list) {
            let tmp = self.file.with_extension("tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(tmp, &self.file);
            }
        }
    }

    /// Adiciona a pasta (ou devolve o projeto que já a tem). A cor é a menos usada até agora.
    pub fn add(&mut self, path: &Path) -> Project {
        let path_text = path.to_string_lossy().into_owned();
        if let Some(existing) = self.list.iter().find(|p| p.path == path_text) {
            return existing.clone();
        }
        let color = COLORS.iter().min_by_key(|c| self.list.iter().filter(|p| p.color == **c).count()).unwrap_or(&"violet");
        let project = Project {
            id: crate::proc::new_id(),
            name: path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path_text.clone()),
            path: path_text,
            color: color.to_string(),
            last_session_id: None,
            settings: Settings::default(),
        };
        self.list.push(project.clone());
        self.save();
        project
    }

    pub fn remove(&mut self, id: &str) {
        self.list.retain(|p| p.id != id);
        self.save();
    }

    pub fn get(&self, id: &str) -> Option<&Project> {
        self.list.iter().find(|p| p.id == id)
    }

    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut Project)) {
        if let Some(project) = self.list.iter_mut().find(|p| p.id == id) {
            change(project);
            self.save();
        }
    }
}

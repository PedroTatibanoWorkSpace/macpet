//! Cawde: o corvo da área de notificação do Windows, que acompanha o Claude Code.
//!
//! Leveza é regra: ao abrir só existe o ícone (desenhado aqui, em Rust). Nenhuma WebView roda até você clicar;
//! o popover e o painel nascem quando abertos e são destruídos quando fechados; as métricas só são medidas com o
//! popover aberto. As conversas moram no núcleo (chat/) e no relay, não na interface.

mod chat;
mod claude;
mod limits;
mod metrics;
mod pet;
mod proc;
mod projects;

use chat::{Activity, ChatManager, ProjectRow, Snapshot};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, Position, RunEvent, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_dialog::DialogExt;

const POPOVER: &str = "popover";
const PANEL: &str = "panel";
const POPOVER_SIZE: (f64, f64) = (360.0, 470.0);
const DEMO: &str = include_str!("../fixtures/demo-transcript.jsonl");

/// WebView2 enxuto: sem processo de GPU (a interface é simples; desenha na CPU), um processo de página só e
/// nada de serviços em segundo plano (atualizações, sincronização, telemetria). As três primeiras desativações
/// são as que o Tauri já passa por padrão. Todas as janelas precisam dos mesmos argumentos (um WebView2 só).
const WEBVIEW_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection,CalculateNativeWinOcclusion \
    --disable-gpu --disable-gpu-compositing --renderer-process-limit=1 --disable-background-networking \
    --disable-component-update --disable-extensions --disable-sync --no-pings --disable-breakpad";

struct AppState {
    limits: Arc<Mutex<limits::Limits>>,
    limits_path: PathBuf,
    refreshing: AtomicBool,
    metrics: metrics::Metrics,
    mood: Mutex<pet::Mood>,
    chats: Arc<ChatManager>,
    models: Mutex<Vec<claude::ModelOption>>,
    models_path: PathBuf,
    /// Quando o popover fechou por perder o foco: um clique no ícone logo depois não deve reabri-lo.
    popover_closed: Mutex<Option<Instant>>,
    /// Onde foi o último clique no ícone (para posicionar o popover).
    tray_anchor: Mutex<Option<(f64, f64, f64, f64)>>,
}

type St<'a> = State<'a, Arc<AppState>>;

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PetState {
    mood: pet::Mood,
    description: String,
}

// MARK: Comandos do popover

#[tauri::command]
fn limits(state: St) -> limits::Limits {
    state.limits.lock().unwrap().clone()
}

#[tauri::command]
fn refresh_limits(state: St) {
    refresh_limits_in_background(state.inner().clone(), 0);
}

#[tauri::command]
fn metrics(state: St) -> metrics::Snapshot {
    state.metrics.sample()
}

#[tauri::command]
fn pet_state(state: St) -> PetState {
    let mood = *state.mood.lock().unwrap();
    let description = match mood {
        pet::Mood::Idle => "De boa. Esperando o próximo prompt.",
        pet::Mood::Working => "O Claude está trabalhando.",
        pet::Mood::Waiting => "O Claude precisa de você.",
        pet::Mood::Celebrating => "Tarefa concluída!",
        pet::Mood::Tired => "Cansado… perto do limite do plano.",
        pet::Mood::Sleeping => "Dormindo… você saiu do computador.",
    };
    PetState { mood, description: description.into() }
}

#[tauri::command]
fn open_panel(app: AppHandle) {
    open_window_async(&app, PANEL);
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) {
    use tauri_plugin_opener::OpenerExt;
    if url.starts_with("http://") || url.starts_with("https://") {
        let _ = app.opener().open_url(url, None::<&str>);
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.state::<Arc<AppState>>().chats.shutdown();
    app.exit(0);
}

// MARK: Comandos do painel (projetos e conversas)

#[tauri::command]
fn projects(state: St) -> Vec<ProjectRow> {
    state.chats.rows()
}

/// Escolhe a pasta pelo seletor do Windows e adiciona o projeto. Devolve o id, ou nada se cancelar.
#[tauri::command]
async fn add_project(app: AppHandle) -> Option<String> {
    let (sender, receiver) = std::sync::mpsc::channel();
    app.dialog().file().set_title("Escolha a pasta do projeto").pick_folder(move |folder| {
        let _ = sender.send(folder.and_then(|f| f.into_path().ok()));
    });
    let path = receiver.recv().ok().flatten()?;
    let state = app.state::<Arc<AppState>>();
    let project = state.chats.projects.lock().unwrap().add(&path);
    Some(project.id)
}

#[tauri::command]
fn remove_project(state: St, project_id: String) {
    state.chats.remove(&project_id);
}

#[tauri::command]
fn open_chat(state: St, project_id: String) -> Option<Snapshot> {
    state.chats.open(&project_id)
}

#[tauri::command]
fn send(state: St, project_id: String, text: String) {
    state.chats.send(&project_id, &text);
}

#[tauri::command]
fn interrupt(state: St, project_id: String) {
    state.chats.interrupt(&project_id);
}

#[tauri::command]
fn respond(state: St, project_id: String, request_id: String, allow: bool, apply_suggestion: bool) {
    state.chats.with(&project_id, |s| s.respond(&request_id, allow, apply_suggestion));
}

#[tauri::command]
fn set_mode(state: St, project_id: String, mode: String) {
    state.chats.with(&project_id, |s| s.set_mode(&mode));
}

#[tauri::command]
fn set_model(state: St, project_id: String, model: String) {
    state.chats.with(&project_id, |s| s.set_model(&model));
}

#[tauri::command]
fn set_effort(state: St, project_id: String, effort: Option<String>) {
    state.chats.with(&project_id, |s| s.set_effort(effort));
}

#[tauri::command]
fn set_uses_mcp(state: St, project_id: String, enabled: bool) {
    state.chats.with(&project_id, |s| s.set_uses_mcp(enabled));
}

#[tauri::command]
fn new_conversation(state: St, project_id: String) {
    state.chats.with(&project_id, |s| s.new_conversation());
}

#[tauri::command]
fn models(state: St) -> Vec<claude::ModelOption> {
    state.models.lock().unwrap().clone()
}

// MARK: Fundo

/// Consulta o `/usage` fora da thread principal, se a última leitura tiver mais de `max_age` segundos.
fn refresh_limits_in_background(state: Arc<AppState>, max_age: i64) {
    let updated = state.limits.lock().unwrap().updated_at.unwrap_or(0);
    if chrono::Local::now().timestamp() - updated < max_age || state.refreshing.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        if let Some(fresh) = limits::fetch() {
            fresh.save(&state.limits_path);
            *state.limits.lock().unwrap() = fresh;
        }
        state.refreshing.store(false, Ordering::SeqCst);
    });
}

/// Anima o ícone no ritmo do humor. O humor segue as conversas (trabalhando, esperando você, comemorando) e,
/// paradas, os limites do plano e se você está no computador.
fn animate(tray: TrayIcon, state: Arc<AppState>, animations: HashMap<&'static str, pet::Animation>) {
    std::thread::spawn(move || {
        let mut frame = 0usize;
        // Quadro igual ao que já está no ícone não é reenviado (a animação parada repete muito o mesmo quadro).
        let mut shown: Option<(&'static str, usize)> = None;
        let mut calm = pet::Mood::Idle;
        let mut last_calm_check = Instant::now() - Duration::from_secs(60);
        loop {
            if last_calm_check.elapsed() >= Duration::from_secs(30) {
                last_calm_check = Instant::now();
                calm = if pet::idle_seconds() > 10 * 60 {
                    pet::Mood::Sleeping
                } else if state.limits.lock().unwrap().near_limit() {
                    pet::Mood::Tired
                } else {
                    pet::Mood::Idle
                };
            }
            let mood = match state.chats.activity() {
                Activity::Waiting => pet::Mood::Waiting,
                Activity::Working => pet::Mood::Working,
                Activity::Celebrating => pet::Mood::Celebrating,
                Activity::Idle => calm,
            };
            *state.mood.lock().unwrap() = mood;
            let Some(animation) = animations.get(mood.key()).or_else(|| animations.get("idle")) else { return };
            frame = (frame + 1) % animation.frames.len().max(1);
            let same = shown.is_some_and(|(key, i)| key == mood.key() && animation.frames[i].rgba() == animation.frames[frame].rgba());
            if !same {
                let _ = tray.set_icon(Some(animation.frames[frame].clone()));
                shown = Some((mood.key(), frame));
            }
            std::thread::sleep(Duration::from_secs_f64(1.0 / animation.fps.max(0.5)));
        }
    });
}

// MARK: Janelas

fn toggle_popover(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(POPOVER) {
        let _ = window.close();
        return;
    }
    let state = app.state::<Arc<AppState>>();
    if state.popover_closed.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_millis(300)) {
        return;
    }
    open_window_async(app, POPOVER);
}

/// No Windows, criar uma WebView de dentro de um tratador da thread principal (clique no ícone, segunda
/// instância) trava: o WebView2 precisa dessa thread livre para nascer. Cria a partir de outra thread.
/// Janela que já existe só vem para a frente.
fn open_window_async(app: &AppHandle, label: &'static str) {
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.unminimize();
        let _ = window.set_focus();
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        if app.get_webview_window(label).is_some() {
            return;
        }
        let result = if label == PANEL { open_panel_window(&app) } else { open_popover(&app) };
        if let Err(error) = result {
            eprintln!("Cawde: não consegui abrir {label}: {error}");
        }
    });
}

/// O painel: projetos e conversas. Uma janela comum (aparece na barra de tarefas); fechada, é destruída.
fn open_panel_window(app: &AppHandle) -> tauri::Result<()> {
    // 1100×720, sem passar de 92% da área útil da tela (telas pequenas e escala alta).
    let (mut width, mut height) = (1100.0, 720.0);
    if let Some(monitor) = app.primary_monitor().ok().flatten() {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        width = f64::min(width, area.size.width as f64 / scale * 0.92);
        height = f64::min(height, area.size.height as f64 / scale * 0.92);
    }
    WebviewWindowBuilder::new(app, PANEL, WebviewUrl::App("index.html#panel".into()))
        .additional_browser_args(WEBVIEW_ARGS)
        .title("Cawde")
        .inner_size(width, height)
        .min_inner_size(760.0, 480.0)
        .center()
        .build()?;
    Ok(())
}

/// Cria o popover colado ao ícone (acima dele com a barra de tarefas embaixo, abaixo com ela no alto).
fn open_popover(app: &AppHandle) -> tauri::Result<()> {
    let window = WebviewWindowBuilder::new(app, POPOVER, WebviewUrl::App("index.html#popover".into()))
        .additional_browser_args(WEBVIEW_ARGS)
        .title("Cawde")
        .inner_size(POPOVER_SIZE.0, POPOVER_SIZE.1)
        .decorations(false)
        .resizable(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .shadow(true)
        .visible(false)
        .build()?;
    let scale = window.scale_factor().unwrap_or(1.0);
    let (width, height) = (POPOVER_SIZE.0 * scale, POPOVER_SIZE.1 * scale);
    let state = app.state::<Arc<AppState>>();
    let anchor = *state.tray_anchor.lock().unwrap();
    if let Some(monitor) = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten()) {
        let area = monitor.work_area();
        let (left, top) = (area.position.x as f64, area.position.y as f64);
        let (right, bottom) = (left + area.size.width as f64, top + area.size.height as f64);
        let (x, y) = match anchor {
            Some((ax, ay, aw, ah)) => {
                let x = ax + aw / 2.0 - width / 2.0;
                let y = if ay > (top + bottom) / 2.0 { ay - height - 8.0 } else { ay + ah + 8.0 };
                (x, y)
            }
            None => (right - width - 12.0, bottom - height - 12.0),
        };
        let x = x.clamp(left + 8.0, right - width - 8.0);
        let y = y.clamp(top + 8.0, bottom - height - 8.0);
        let _ = window.set_position(Position::Physical(PhysicalPosition::new(x as i32, y as i32)));
    }
    let handle = app.clone();
    window.on_window_event(move |event| match event {
        WindowEvent::Focused(false) => {
            let state = handle.state::<Arc<AppState>>();
            *state.popover_closed.lock().unwrap() = Some(Instant::now());
            if let Some(window) = handle.get_webview_window(POPOVER) {
                let _ = window.close();
            }
        }
        WindowEvent::Destroyed => handle.state::<Arc<AppState>>().metrics.release(),
        _ => {}
    });
    window.show()?;
    window.set_focus()?;
    Ok(())
}

/// Argumentos de uma segunda execução (`cawde.exe --popover`, `--panel`): usados pelo teste do CI.
fn handle_args(app: &AppHandle, args: &[String]) {
    let has = |flag: &str| args.iter().any(|a| a == flag);
    if has("--demo") {
        let state = app.state::<Arc<AppState>>();
        if let Some(id) = state.chats.add_demo(DEMO) {
            state.chats.projects.lock().unwrap().update(&id, |p| p.name = "loja".into());
        }
    }
    if has("--popover") {
        open_window_async(app, POPOVER);
    }
    if has("--panel") {
        open_window_async(app, PANEL);
    }
    if has("--close-popover") {
        if let Some(window) = app.get_webview_window(POPOVER) {
            let _ = window.close();
        }
    }
    if has("--close-panel") {
        if let Some(window) = app.get_webview_window(PANEL) {
            let _ = window.close();
        }
    }
}

/// O relay vai junto com o app (sidecar), na mesma pasta do executável.
fn relay_path() -> PathBuf {
    let name = if cfg!(windows) { "cawde-relay.exe" } else { "cawde-relay" };
    std::env::current_exe().ok().and_then(|exe| exe.parent().map(|dir| dir.join(name))).unwrap_or_else(|| PathBuf::from(name))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| handle_args(app, &args)))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            limits, refresh_limits, metrics, pet_state, open_panel, open_url, quit, projects, add_project, remove_project,
            open_chat, send, interrupt, respond, set_mode, set_model, set_effort, set_uses_mcp, new_conversation, models
        ])
        .setup(|app| {
            let data = app.path().app_data_dir()?;
            let limits_path = data.join("limits.json");
            let models_path = data.join("models.json");
            let limits = Arc::new(Mutex::new(limits::Limits::load(&limits_path)));

            // Limites que chegam em cada resposta dos chats.
            let (limits_for_chats, path_for_chats) = (limits.clone(), limits_path.clone());
            let chats = ChatManager::new(app.handle().clone(), data.clone(), relay_path(), move |info| {
                let mut current = limits_for_chats.lock().unwrap();
                if let Some(fresh) = limits::from_rate_limit_event(info, &current) {
                    fresh.save(&path_for_chats);
                    *current = fresh;
                }
            });
            let models = std::fs::read_to_string(&models_path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
            let state = Arc::new(AppState {
                limits,
                limits_path,
                refreshing: AtomicBool::new(false),
                metrics: metrics::Metrics::new(),
                mood: Mutex::new(pet::Mood::Idle),
                chats,
                models: Mutex::new(models),
                models_path,
                popover_closed: Mutex::new(None),
                tray_anchor: Mutex::new(None),
            });
            app.manage(state.clone());

            let animations = pet::load();
            let open_item = MenuItem::with_id(app, "panel", "Abrir o painel", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Sair do Cawde", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open_item, &quit_item])?;
            let mut builder = TrayIconBuilder::with_id("cawde")
                .tooltip("Cawde")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "panel" => open_window_async(app, PANEL),
                    "quit" => {
                        app.state::<Arc<AppState>>().chats.shutdown();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { rect, button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        let app = tray.app_handle();
                        let scale = app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0);
                        let position = rect.position.to_physical::<f64>(scale);
                        let size = rect.size.to_physical::<f64>(scale);
                        *app.state::<Arc<AppState>>().tray_anchor.lock().unwrap() = Some((position.x, position.y, size.width, size.height));
                        toggle_popover(app);
                    }
                });
            if let Some(first) = animations.get("idle").and_then(|a| a.frames.first()) {
                builder = builder.icon(first.clone());
            }
            // Sem a área de notificação (ex.: máquina de CI sem desktop) o app segue rodando, só sem ícone.
            match builder.build(app) {
                Ok(tray) => animate(tray, state.clone(), animations),
                Err(error) => eprintln!("Cawde: área de notificação indisponível: {error}"),
            }

            // Em segundo plano: conversas que seguiram rodando, modelos da conta, e limites a cada 10 min.
            let background = state.clone();
            std::thread::spawn(move || {
                background.chats.attach_running();
                if let Some(models) = claude::fetch_models().filter(|m| !m.is_empty()) {
                    if let Ok(json) = serde_json::to_string(&models) {
                        let _ = std::fs::write(&background.models_path, json);
                    }
                    *background.models.lock().unwrap() = models;
                }
                loop {
                    refresh_limits_in_background(background.clone(), 5 * 60);
                    std::thread::sleep(Duration::from_secs(10 * 60));
                }
            });

            let args: Vec<String> = std::env::args().collect();
            handle_args(app.handle(), &args);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("falha ao iniciar o Cawde");

    app.run(|app, event| match event {
        // Fechar a última janela não encerra: o Cawde vive na área de notificação. Só "Sair" encerra.
        RunEvent::ExitRequested { api, code, .. } if code.is_none() => api.prevent_exit(),
        RunEvent::Exit => app.state::<Arc<AppState>>().chats.shutdown(),
        _ => {}
    });
}

//! O corvo da área de notificação: a arte vem de `windows/shared/pet-art.json` (exportada do PetArt.swift do
//! MacPet) e cada quadro vira um ícone RGBA uma vez só, na abertura. A animação acorda só no ritmo do humor
//! (1 a 6 quadros por segundo).

use serde::Deserialize;
use std::collections::HashMap;
use tauri::image::Image;

const ART: &str = include_str!("../../../shared/pet-art.json");

#[derive(Deserialize)]
struct Art {
    width: usize,
    height: usize,
    palette: HashMap<String, String>,
    moods: HashMap<String, MoodArt>,
}

#[derive(Deserialize)]
struct MoodArt {
    fps: f64,
    frames: Vec<Vec<String>>,
}

/// Quadros prontos de um humor.
pub struct Animation {
    pub fps: f64,
    pub frames: Vec<Image<'static>>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mood {
    Idle,
    Working,
    Waiting,
    Celebrating,
    Tired,
    Sleeping,
}

impl Mood {
    pub fn key(self) -> &'static str {
        match self {
            Mood::Idle => "idle",
            Mood::Working => "working",
            Mood::Waiting => "waiting",
            Mood::Celebrating => "celebrating",
            Mood::Tired => "tired",
            Mood::Sleeping => "sleeping",
        }
    }
}

/// Lado do ícone em pixels. O Windows reduz para 16 a 24 px conforme a escala da tela; 48 dá 2 px por célula
/// e reduz limpo para 24 (escala de 150%, comum em notebooks).
const ICON: usize = 48;

pub fn load() -> HashMap<&'static str, Animation> {
    let art: Art = serde_json::from_str(ART).expect("pet-art.json inválido");
    let colors: HashMap<char, [u8; 3]> = art
        .palette
        .iter()
        .filter_map(|(k, hex)| Some((k.chars().next()?, parse_hex(hex)?)))
        .collect();
    let mut out = HashMap::new();
    for mood in [Mood::Idle, Mood::Working, Mood::Waiting, Mood::Celebrating, Mood::Tired, Mood::Sleeping] {
        if let Some(m) = art.moods.get(mood.key()) {
            let frames = m.frames.iter().map(|f| render(f, art.width, art.height, &colors)).collect();
            out.insert(mood.key(), Animation { fps: m.fps, frames });
        }
    }
    out
}

/// Desenha o quadro centralizado num ícone quadrado, sem suavizar (pixel art).
fn render(frame: &[String], width: usize, height: usize, colors: &HashMap<char, [u8; 3]>) -> Image<'static> {
    let cell = ICON / width.max(height);
    let (ox, oy) = ((ICON - width * cell) / 2, (ICON - height * cell) / 2);
    let mut rgba = vec![0u8; ICON * ICON * 4];
    for (row, line) in frame.iter().enumerate() {
        for (col, ch) in line.chars().enumerate() {
            let Some(rgb) = colors.get(&ch) else { continue };
            for dy in 0..cell {
                for dx in 0..cell {
                    let (x, y) = (ox + col * cell + dx, oy + row * cell + dy);
                    let i = (y * ICON + x) * 4;
                    rgba[i..i + 4].copy_from_slice(&[rgb[0], rgb[1], rgb[2], 255]);
                }
            }
        }
    }
    Image::new_owned(rgba, ICON as u32, ICON as u32)
}

fn parse_hex(hex: &str) -> Option<[u8; 3]> {
    let v = u32::from_str_radix(hex.trim_start_matches('#'), 16).ok()?;
    Some([(v >> 16) as u8, (v >> 8) as u8, v as u8])
}

/// Segundos sem teclado e mouse (o corvo dorme quando você sai). Só no Windows.
pub fn idle_seconds() -> u64 {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::SystemInformation::GetTickCount;
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
        let mut info = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
        if GetLastInputInfo(&mut info) != 0 {
            return (GetTickCount().wrapping_sub(info.dwTime) / 1000) as u64;
        }
    }
    0
}

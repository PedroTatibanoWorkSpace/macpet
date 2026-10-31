//! Limites do plano (janela de 5h e semanal), pelo `/usage` do Claude Code: roda local e não gasta tokens.
//! A última leitura fica em `limits.json` na pasta de dados do app, para aparecer logo na abertura.

use chrono::{Datelike, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub used_percentage: f64,
    /// Segundos desde 1970; None quando o `/usage` não informou.
    pub resets_at: Option<i64>,
}

impl Window {
    fn is_expired(&self) -> bool {
        self.resets_at.is_some_and(|t| t < Local::now().timestamp())
    }
    pub fn fraction(&self) -> f64 {
        if self.is_expired() { 0.0 } else { (self.used_percentage / 100.0).clamp(0.0, 1.0) }
    }
}

#[derive(Clone, Serialize, Deserialize, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    pub five_hour: Option<Window>,
    pub seven_day: Option<Window>,
    pub updated_at: Option<i64>,
}

impl Limits {
    /// Perto de estourar: o corvo fica cansado.
    pub fn near_limit(&self) -> bool {
        self.five_hour.as_ref().is_some_and(|w| w.fraction() >= 0.9) || self.seven_day.as_ref().is_some_and(|w| w.fraction() >= 0.95)
    }

    pub fn load(path: &Path) -> Limits {
        std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string(self) {
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(tmp, path);
            }
        }
    }
}

/// `rate_limit_event` de cada resposta nos chats:
/// {"unifiedWindows": {"five_hour": {"utilization": 0.02, "resetsAt": 1793276400}, "seven_day": {...}}}
pub fn from_rate_limit_event(info: &serde_json::Value, current: &Limits) -> Option<Limits> {
    let windows = info.get("unifiedWindows")?;
    let read = |key: &str| {
        let w = windows.get(key)?;
        Some(Window { used_percentage: w.get("utilization")?.as_f64()? * 100.0, resets_at: w.get("resetsAt").and_then(|r| r.as_i64()) })
    };
    let (five, seven) = (read("five_hour"), read("seven_day"));
    if five.is_none() && seven.is_none() {
        return None;
    }
    Some(Limits {
        five_hour: five.or_else(|| current.five_hour.clone()),
        seven_day: seven.or_else(|| current.seven_day.clone()),
        updated_at: Some(Local::now().timestamp()),
    })
}

/// Roda o `/usage` e lê as janelas. None se o Claude Code não estiver instalado ou não responder.
pub fn fetch() -> Option<Limits> {
    let claude = crate::claude::executable()?;
    let mut command = Command::new(claude);
    command
        .args(["-p", "/usage", "--output-format", "json", "--no-session-persistence"])
        .current_dir(dirs_home());
    crate::claude::hide_console(&mut command);
    let output = command.output().ok()?;
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let text = json.get("result")?.as_str()?;
    let limits = parse(text, Local::now().naive_local());
    (limits.five_hour.is_some() || limits.seven_day.is_some()).then_some(limits)
}

fn dirs_home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// "Current session: 6% used · resets Oct 29 at 9:19am (America/Sao_Paulo)"
pub fn parse(text: &str, now: NaiveDateTime) -> Limits {
    let window = |prefix: &str| -> Option<Window> {
        let line = text.lines().map(str::trim).find(|l| l.starts_with(prefix))?;
        let after = &line[line.find(": ")? + 2..];
        let used: f64 = after[..after.find("% used")?].trim().parse().ok()?;
        let resets_at = after.split("resets ").nth(1).and_then(|r| {
            let reset = r.split(" (").next()?.trim();
            parse_reset(reset, now)
        });
        Some(Window { used_percentage: used, resets_at })
    };
    Limits {
        five_hour: window("Current session"),
        seven_day: window("Current week (all models)"),
        updated_at: Some(Local::now().timestamp()),
    }
}

/// "Oct 29 at 9:19am", "Oct 29 at 9am", "9:19am" ou "9am" (hoje), no fuso do computador.
fn parse_reset(text: &str, now: NaiveDateTime) -> Option<i64> {
    let text = text.to_lowercase();
    let (date_part, mut time_part) = match text.split_once(" at ") {
        Some((d, t)) => (Some(d.to_string()), t.trim().to_string()),
        None => (None, text.trim().to_string()),
    };
    // "1pm" → "1:00pm" (o chrono não lê hora sem minutos).
    if !time_part.contains(':') && time_part.len() > 2 {
        time_part.insert_str(time_part.len() - 2, ":00");
    }
    let time = NaiveTime::parse_from_str(&time_part, "%I:%M%p").ok()?;
    let date = match date_part {
        Some(d) => NaiveDate::parse_from_str(&format!("{} {}", now.year(), d), "%Y %b %d").ok()?,
        None => now.date(),
    };
    let mut when = date.and_time(time);
    // Sem ano no texto: um reset é sempre no futuro.
    if when < now - chrono::Duration::days(1) {
        when = when.with_year(when.year() + 1)?;
    }
    Local.from_local_datetime(&when).earliest().map(|d| d.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_usage_text() {
        let now = NaiveDate::from_ymd_opt(2026, 10, 29).unwrap().and_hms_opt(8, 0, 0).unwrap();
        let text = "Current session: 6% used · resets Oct 29 at 9:19am (America/Sao_Paulo)\n\
                    Current week (all models): 77% used · resets Oct 30 at 1pm (America/Sao_Paulo)\n";
        let limits = parse(text, now);
        let five = limits.five_hour.unwrap();
        assert_eq!(five.used_percentage, 6.0);
        let reset = Local.timestamp_opt(five.resets_at.unwrap(), 0).unwrap().naive_local();
        assert_eq!(reset, NaiveDate::from_ymd_opt(2026, 10, 29).unwrap().and_hms_opt(9, 19, 0).unwrap());
        let seven = limits.seven_day.unwrap();
        assert_eq!(seven.used_percentage, 77.0);
        let reset = Local.timestamp_opt(seven.resets_at.unwrap(), 0).unwrap().naive_local();
        assert_eq!(reset, NaiveDate::from_ymd_opt(2026, 10, 30).unwrap().and_hms_opt(13, 0, 0).unwrap());
    }

    #[test]
    fn today_only_and_missing_reset() {
        let now = NaiveDate::from_ymd_opt(2026, 10, 29).unwrap().and_hms_opt(8, 0, 0).unwrap();
        let limits = parse("Current session: 12.5% used · resets 11am\nCurrent week (all models): 3% used", now);
        assert_eq!(limits.five_hour.unwrap().used_percentage, 12.5);
        assert_eq!(limits.seven_day.unwrap().resets_at, None);
    }
}

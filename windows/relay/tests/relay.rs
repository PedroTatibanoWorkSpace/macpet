//! O relay entrega input.jsonl ao processo filho e grava a saída em out.jsonl, também com linhas grandes.
//! O filho é o próprio relay no modo `--echo` (as ferramentas de eco do sistema variam; o `findstr` do Windows
//! não aceita linhas longas).

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::process::Command;
use std::time::{Duration, Instant};

#[test]
fn relays_lines_both_ways() {
    let dir = std::env::temp_dir().join(format!("cawde-relay-test-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let relay = env!("CARGO_BIN_EXE_cawde-relay");
    let mut child = Command::new(relay).arg(&dir).arg(std::env::temp_dir()).arg("--").arg(relay).arg("--echo").spawn().unwrap();

    let big = "x".repeat(2_000_000);
    let lines = [r#"{"type":"user","n":1}"#.to_string(), format!(r#"{{"type":"user","pad":"{big}"}}"#), r#"{"type":"user","n":3}"#.to_string()];
    let mut input = OpenOptions::new().create(true).append(true).open(dir.join("input.jsonl")).unwrap();
    for line in &lines {
        writeln!(input, "{line}").unwrap();
    }

    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let out = fs::read_to_string(dir.join("out.jsonl")).unwrap_or_default();
        if out.lines().count() >= 3 {
            let got: Vec<&str> = out.lines().map(|l| l.trim_end_matches('\r')).collect();
            assert_eq!(got, lines.iter().map(String::as_str).collect::<Vec<_>>());
            break;
        }
        assert!(Instant::now() < deadline, "o relay não entregou as linhas em 20 s. out.jsonl: {} linhas; err.log: {:?}; exit: {:?}",
                out.lines().count(), fs::read_to_string(dir.join("err.log")).unwrap_or_default(),
                fs::read_to_string(dir.join("exit.json")).ok());
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(fs::read_to_string(dir.join("meta.json")).unwrap().contains("claudePid"));
    let _ = child.kill();
    let _ = fs::remove_dir_all(&dir);
}

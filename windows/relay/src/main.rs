//! Relay de uma conversa com o Claude Code.
//!
//! O app não segura o processo do `claude` (no Windows não há FIFO, e o app pode fechar no meio de um turno).
//! Ele lança este relay destacado, que segura o `claude` e conversa com o app só por arquivos na pasta da conversa:
//!
//! - `input.jsonl`: o app acrescenta linhas (mensagens stream-json); o relay entrega cada linha completa ao claude.
//! - `out.jsonl`: tudo o que o claude escreve na saída, linha a linha.
//! - `err.log`: a saída de erro do claude.
//! - `meta.json`: pids do relay e do claude (o app usa para reconectar e para encerrar).
//! - `exit.json`: código de saída quando o claude termina.
//!
//! Uso: cawde-relay <pasta> <cwd> -- <claude> [argumentos...]

// Sem janela de console no Windows (o relay roda escondido).
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // Só para os testes: devolve cada linha recebida (um "claude" de mentira igual em todo sistema).
    if args.get(1).map(String::as_str) == Some("--echo") {
        return echo();
    }
    let split = args.iter().position(|a| a == "--").unwrap_or_else(|| usage());
    if split < 3 || split + 1 >= args.len() {
        usage();
    }
    let dir = PathBuf::from(&args[1]);
    let cwd = PathBuf::from(&args[2]);
    let program = &args[split + 1];
    let program_args = &args[split + 2..];
    fs::create_dir_all(&dir).expect("criar a pasta da conversa");

    let stderr = File::create(dir.join("err.log")).expect("criar err.log");
    let mut command = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command
        .args(program_args)
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(stderr))
        .spawn()
        .unwrap_or_else(|e| fail(&dir, &format!("não consegui iniciar o claude: {e}")));

    write_atomic(&dir.join("meta.json"), &format!(
        "{{\"relayPid\":{},\"claudePid\":{},\"program\":{:?}}}\n", std::process::id(), child.id(), program));

    let finished = Arc::new(AtomicBool::new(false));

    // claude → out.jsonl, uma linha por vez (o app acompanha o arquivo crescendo).
    let mut stdout = child.stdout.take().unwrap();
    let out_path = dir.join("out.jsonl");
    let writer = thread::spawn(move || {
        let mut out = OpenOptions::new().create(true).append(true).open(&out_path).expect("abrir out.jsonl");
        let mut buffer = [0u8; 64 * 1024];
        loop {
            match stdout.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let _ = out.write_all(&buffer[..n]);
                    let _ = out.flush();
                }
            }
        }
    });

    // input.jsonl → claude: lê só linhas completas (o app pode estar no meio de uma escrita grande).
    let mut stdin = child.stdin.take().unwrap();
    let input_path = dir.join("input.jsonl");
    let done = finished.clone();
    thread::spawn(move || {
        let mut offset: u64 = 0;
        let mut pending: Vec<u8> = Vec::new();
        while !done.load(Ordering::Relaxed) {
            if let Ok(mut file) = File::open(&input_path) {
                if file.seek(SeekFrom::Start(offset)).is_ok() {
                    let mut chunk = Vec::new();
                    if let Ok(n) = file.read_to_end(&mut chunk) {
                        offset += n as u64;
                        pending.extend_from_slice(&chunk);
                    }
                }
            }
            while let Some(end) = pending.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = pending.drain(..=end).collect();
                if stdin.write_all(&line).and_then(|_| stdin.flush()).is_err() {
                    return;
                }
            }
            thread::sleep(Duration::from_millis(50));
        }
    });

    let status = child.wait().ok().and_then(|s| s.code());
    finished.store(true, Ordering::Relaxed);
    let _ = writer.join();
    write_atomic(&dir.join("exit.json"), &format!("{{\"code\":{}}}\n",
        status.map(|c| c.to_string()).unwrap_or_else(|| "null".into())));
}

fn echo() {
    let mut line = String::new();
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    while stdin.read_line(&mut line).map(|n| n > 0).unwrap_or(false) {
        let _ = stdout.write_all(line.as_bytes());
        let _ = stdout.flush();
        line.clear();
    }
}

/// Escreve num arquivo temporário e renomeia: o app nunca lê um meta.json pela metade.
fn write_atomic(path: &Path, content: &str) {
    let tmp = path.with_extension("tmp");
    if fs::write(&tmp, content).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

fn fail(dir: &Path, message: &str) -> ! {
    let _ = fs::write(dir.join("err.log"), message);
    write_atomic(&dir.join("exit.json"), "{\"code\":null}\n");
    std::process::exit(1)
}

fn usage() -> ! {
    eprintln!("uso: cawde-relay <pasta> <cwd> -- <claude> [argumentos...]");
    std::process::exit(2)
}

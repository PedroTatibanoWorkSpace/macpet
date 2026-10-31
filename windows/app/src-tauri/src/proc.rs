//! Processos: lançar o relay destacado, saber se um pid está vivo e encerrar um pid (com o que ele lançou).

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::SystemTime;

/// Lança `program` destacado do app: ele continua vivo se o Cawde fechar.
pub fn launch_detached(program: &Path, args: &[String]) -> std::io::Result<u32> {
    let spawn = |extra_flags: u32| {
        let mut command = Command::new(program);
        command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const DETACHED_PROCESS: u32 = 0x0000_0008;
            const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
            command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | extra_flags);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            let _ = extra_flags;
            command.process_group(0);
        }
        command.spawn().map(|child| child.id())
    };
    // No Windows, sair do "job" do app garante que o relay não morre junto; se o job não permitir, lança sem.
    #[cfg(windows)]
    {
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        spawn(CREATE_BREAKAWAY_FROM_JOB).or_else(|_| spawn(0))
    }
    #[cfg(not(windows))]
    spawn(0)
}

/// Vivo e já existente em `known_at` (quando o relay gravou o meta.json). O Windows reaproveita pids rápido,
/// ainda mais depois de reiniciar: um pid velho pode ser hoje de outro programa, e esse não conta.
pub fn is_alive_since(pid: u32, known_at: SystemTime) -> bool {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
        use windows_sys::Win32::System::Threading::{GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return false;
        }
        let mut code = 0u32;
        let alive = GetExitCodeProcess(handle, &mut code) != 0 && code == STILL_ACTIVE as u32;
        let same = alive && existed_at(handle, known_at);
        CloseHandle(handle);
        same
    }
    #[cfg(not(windows))]
    {
        let _ = known_at;
        Command::new("kill").args(["-0", &pid.to_string()]).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
    }
}

/// Encerra o processo e o que ele lançou (comandos em segundo plano, servidores MCP), se ainda for o mesmo de
/// `known_at`. No Windows, TerminateProcess sozinho deixa os filhos órfãos e escondidos.
pub fn terminate_tree(pid: u32, known_at: SystemTime) {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE};
        // O handle aberto segura o pid: ninguém o reaproveita enquanto o taskkill roda.
        let handle = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return;
        }
        if existed_at(handle, known_at) {
            let mut command = Command::new("taskkill");
            command.args(["/PID", &pid.to_string(), "/T", "/F"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
            crate::claude::hide_console(&mut command);
            let _ = command.status();
            // Se o taskkill falhar, ao menos o próprio processo.
            TerminateProcess(handle, 1);
        }
        CloseHandle(handle);
    }
    #[cfg(not(windows))]
    {
        let _ = known_at;
        let _ = Command::new("kill").arg(pid.to_string()).status();
    }
}

/// O processo do handle foi criado até `known_at` (com folga para a resolução do relógio do arquivo).
#[cfg(windows)]
fn existed_at(handle: windows_sys::Win32::Foundation::HANDLE, known_at: SystemTime) -> bool {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetProcessTimes;
    let (mut created, mut exited, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    if unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) } == 0 {
        return false;
    }
    // FILETIME: intervalos de 100 ns desde 1601.
    let ticks = ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64;
    let since_unix = ticks.saturating_sub(116_444_736_000_000_000);
    let started = SystemTime::UNIX_EPOCH + std::time::Duration::from_nanos(since_unix.saturating_mul(100));
    started <= known_at + std::time::Duration::from_secs(1)
}

/// Identificador aleatório sem dependências (ids de pedidos de controle e de conversas).
pub fn new_id() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::new();
    for _ in 0..2 {
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    format!("{}-{}-{}-{}-{}", &out[0..8], &out[8..12], &out[12..16], &out[16..20], &out[20..32])
}

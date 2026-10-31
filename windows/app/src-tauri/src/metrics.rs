//! CPU, memória, disco e rede. Medidos só quando alguém pede (o popover aberto pergunta a cada 2 s);
//! com o popover fechado nada é medido.

use serde::Serialize;
use std::sync::Mutex;
use std::time::Instant;
use sysinfo::{Disks, MemoryRefreshKind, Networks, System};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub cpu: f32,
    pub memory_used: u64,
    pub memory_total: u64,
    pub disk_used: u64,
    pub disk_total: u64,
    /// Bytes por segundo desde a última medição.
    pub net_in: f64,
    pub net_out: f64,
}

pub struct Metrics {
    inner: Mutex<Option<Inner>>,
}

struct Inner {
    system: System,
    networks: Networks,
    disks: Disks,
    last: Instant,
}

impl Metrics {
    pub fn new() -> Self {
        Metrics { inner: Mutex::new(None) }
    }

    pub fn sample(&self) -> Snapshot {
        let mut guard = self.inner.lock().unwrap();
        // Criado na primeira consulta (abrir o app não gasta nada com isso).
        let inner = guard.get_or_insert_with(|| {
            let mut system = System::new();
            system.refresh_cpu_usage();
            Inner { system, networks: Networks::new_with_refreshed_list(), disks: Disks::new_with_refreshed_list(), last: Instant::now() }
        });
        inner.system.refresh_cpu_usage();
        inner.system.refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram());
        inner.networks.refresh(true);
        inner.disks.refresh(true);
        let elapsed = inner.last.elapsed().as_secs_f64().max(0.5);
        inner.last = Instant::now();
        let (net_in, net_out) = inner
            .networks
            .iter()
            .fold((0u64, 0u64), |(i, o), (_, data)| (i + data.received(), o + data.transmitted()));
        // O disco do sistema: C:\ no Windows, / no resto.
        let system_disk = inner
            .disks
            .iter()
            .find(|d| { let m = d.mount_point().to_string_lossy(); m == "C:\\" || m == "/" })
            .or_else(|| inner.disks.iter().next());
        let (disk_total, disk_used) = system_disk
            .map(|d| (d.total_space(), d.total_space().saturating_sub(d.available_space())))
            .unwrap_or((0, 0));
        Snapshot {
            cpu: inner.system.global_cpu_usage(),
            memory_used: inner.system.used_memory(),
            memory_total: inner.system.total_memory(),
            disk_used,
            disk_total,
            net_in: net_in as f64 / elapsed,
            net_out: net_out as f64 / elapsed,
        }
    }

    /// Popover fechado: devolve a memória do medidor.
    pub fn release(&self) {
        *self.inner.lock().unwrap() = None;
    }
}

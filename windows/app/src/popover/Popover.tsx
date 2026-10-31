// O popover do corvo: limites do plano e a saúde do computador. Existe só enquanto está aberto.
import { useEffect, useState } from "react";
import { Button, Card, Meter } from "../design-system/components";
import { PetSprite } from "../pet/PetSprite";
import { api, type Limits, type Metrics, type PetState, type RateWindow } from "../lib/api";
import { bytes, percent, rate, until } from "../lib/format";
import "./popover.css";

function windowValue(w: RateWindow | null) {
  if (!w) return null;
  const expired = w.resetsAt !== null && w.resetsAt * 1000 < Date.now();
  return { value: expired ? 0 : w.usedPercentage, foot: w.resetsAt && !expired ? `reinicia em ${until(w.resetsAt)}` : undefined };
}

export function Popover() {
  const [pet, setPet] = useState<PetState>({ mood: "idle", description: "" });
  const [limits, setLimits] = useState<Limits | null>(null);
  const [metrics, setMetrics] = useState<Metrics | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    api.petState().then(setPet);
    api.limits().then(setLimits);
    api.metrics().then(setMetrics);
    // Enquanto aberto: métricas a cada 2 s. Fechado, a janela some e nada roda.
    const timer = window.setInterval(() => api.metrics().then(setMetrics), 2000);
    return () => window.clearInterval(timer);
  }, []);

  const refresh = async () => {
    setRefreshing(true);
    await api.refreshLimits();
    // O /usage leva alguns segundos; confere até 20 s.
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      const fresh = await api.limits();
      if (fresh.updatedAt !== limits?.updatedAt) { setLimits(fresh); break; }
    }
    setRefreshing(false);
  };

  const five = windowValue(limits?.fiveHour ?? null);
  const week = windowValue(limits?.sevenDay ?? null);

  return (
    <div className="pop">
      <header className="pop-head">
        <PetSprite mood={pet.mood} scale={4} />
        <div>
          <h1>Cawde</h1>
          <p>{pet.description}</p>
        </div>
      </header>

      <Card title="Limites do plano">
        {five || week ? (
          <div className="pop-meters">
            {five && <Meter label="5h" value={five.value} foot={five.foot} />}
            {week && <Meter label="Semana" value={week.value} foot={week.foot} />}
          </div>
        ) : (
          <p className="pop-muted">{refreshing ? "Consultando o Claude Code…" : "Sem leitura ainda. O Claude Code precisa estar instalado e com login feito."}</p>
        )}
      </Card>

      <Card title="Computador">
        {metrics ? (
          <dl className="pop-metrics">
            <div><dt>CPU</dt><dd>{Math.round(metrics.cpu)}%</dd></div>
            <div><dt>Memória</dt><dd>{percent(metrics.memoryUsed / Math.max(metrics.memoryTotal, 1))}</dd></div>
            <div><dt>Disco</dt><dd>{percent(metrics.diskUsed / Math.max(metrics.diskTotal, 1))}</dd><span>{bytes(metrics.diskTotal - metrics.diskUsed)} livres</span></div>
            <div><dt>Rede</dt><dd>↓ {rate(metrics.netIn)}</dd><span>↑ {rate(metrics.netOut)}</span></div>
          </dl>
        ) : <p className="pop-muted">Medindo…</p>}
      </Card>

      <footer className="pop-foot">
        <Button variant="primary" size="sm" icon="chat" onClick={api.openPanel}>Abrir o painel</Button>
        <Button variant="ghost" size="sm" icon="refresh" disabled={refreshing} onClick={refresh}>{refreshing ? "Atualizando…" : "Limites"}</Button>
        <span className="mp-grow" />
        <Button variant="ghost" size="sm" icon="power" onClick={api.quit}>Sair do Cawde</Button>
      </footer>
    </div>
  );
}

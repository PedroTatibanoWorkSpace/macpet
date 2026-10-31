// Onde você escreve para o Claude: texto, modo, modelo, esforço e MCP; custo e horário de pico.
// Com o Claude trabalhando e algo escrito, o botão envia (ele lê no meio do que está fazendo); vazio, para.
import { useEffect, useRef, useState } from "react";
import { Icon, Select, SendButton, type MenuSection } from "../design-system/components";
import { api, type ChatStatus, type ModelOption, type Project } from "../lib/api";
import { usd } from "../lib/format";
import { peak } from "../lib/peak";

const MODES: { value: string; label: string; icon: string; detail: string }[] = [
  { value: "default", label: "Pedir permissão", icon: "hand", detail: "Pede sua permissão antes de editar ou rodar comandos." },
  { value: "acceptEdits", label: "Aceitar edições", icon: "pencil", detail: "Edita arquivos sem perguntar; comandos ainda pedem permissão." },
  { value: "auto", label: "Auto", icon: "wand", detail: "O Claude decide sozinho o que é seguro e só para no que for arriscado." },
  { value: "plan", label: "Planejar", icon: "doc", detail: "Só investiga e propõe um plano; não altera nada até você aprovar." },
];
const EFFORTS: Record<string, string> = { low: "Esforço baixo", medium: "Esforço médio", high: "Esforço alto", xhigh: "Esforço extra alto", max: "Esforço máximo" };
const FALLBACK_MODELS: ModelOption[] = [
  { value: "default", name: "Padrão", detail: "", efforts: [] },
  { value: "opus", name: "Opus", detail: "", efforts: [] },
  { value: "sonnet", name: "Sonnet", detail: "", efforts: [] },
  { value: "haiku", name: "Haiku", detail: "", efforts: [] },
];

export function Composer({ project, status }: { project: Project; status: ChatStatus }) {
  const [draft, setDraft] = useState("");
  const [models, setModels] = useState<ModelOption[]>(FALLBACK_MODELS);
  const [peakNow, setPeakNow] = useState(peak());
  const input = useRef<HTMLTextAreaElement>(null);
  const id = project.id;
  const { settings } = status;

  useEffect(() => { api.models().then((m) => m.length && setModels(m)); }, []);
  useEffect(() => { input.current?.focus(); setDraft(""); }, [id]);
  useEffect(() => {
    const timer = window.setInterval(() => setPeakNow(peak()), 60_000);
    // Ctrl+. para a qualquer momento (também com algo escrito, quando o botão visível é o de enviar).
    const onKey = (e: KeyboardEvent) => { if (e.ctrlKey && e.key === ".") { e.preventDefault(); api.interrupt(id); } };
    window.addEventListener("keydown", onKey);
    return () => { window.clearInterval(timer); window.removeEventListener("keydown", onKey); };
  }, [id]);

  // A caixa cresce com o texto até ~8 linhas.
  useEffect(() => {
    const el = input.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 180)}px`;
  }, [draft]);

  const empty = !draft.trim();
  const submit = () => {
    if (empty) return;
    api.send(id, draft);
    setDraft("");
  };

  const mode = MODES.find((m) => m.value === settings.mode) ?? MODES[0];
  const model = models.find((m) => m.value === settings.model);
  const efforts = (model?.efforts.length ? model.efforts : Object.keys(EFFORTS));
  const modeMenu: MenuSection[] = [{ items: MODES.map((m) => ({ label: m.label, detail: m.detail, checked: m.value === settings.mode, onSelect: () => api.setMode(id, m.value) })) }];
  const modelMenu: MenuSection[] = [{ items: models.map((m) => ({ label: m.name, detail: m.detail || undefined, checked: m.value === settings.model, onSelect: () => api.setModel(id, m.value) })) }];
  const effortMenu: MenuSection[] = [{
    title: "Esforço (reinicia o Claude após o turno)",
    items: [{ label: "Esforço padrão", checked: settings.effort === null, onSelect: () => api.setEffort(id, null) },
      ...efforts.map((e) => ({ label: EFFORTS[e] ?? e, checked: settings.effort === e, onSelect: () => api.setEffort(id, e) }))],
  }];
  const contextMenu: MenuSection[] = [
    { items: [{ label: settings.usesMcp ? "Desligar servidores MCP" : "Ligar servidores MCP", detail: "Sem MCP, cada mensagem fica bem mais leve", onSelect: () => api.setUsesMcp(id, !settings.usesMcp) }] },
    { items: [{ label: "Nova conversa", detail: "A atual continua nas sessões do Claude Code", onSelect: () => api.newConversation(id) }] },
  ];

  return (
    <div className="composer-wrap">
      <div className="mp-composer">
        <textarea
          ref={input}
          className="mp-composer-input"
          rows={1}
          value={draft}
          placeholder=""
          aria-label="Mensagem para o Claude"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); submit(); }
          }}
        />
        <div className="mp-composer-bar">
          <Select icon={mode.icon} label={mode.label} highlighted={settings.mode === "auto"} sections={modeMenu} />
          <Select icon="sparkle" label={model?.name ?? status.modelName ?? settings.model} sections={modelMenu} />
          <Select icon="gauge" label={settings.effort ? EFFORTS[settings.effort] ?? settings.effort : "Esforço padrão"} sections={effortMenu} />
          <Select icon="chat" label={settings.usesMcp ? undefined : "Sem MCP"} sections={contextMenu} />
          <span className="mp-grow" />
          {peakNow.active && <span className="mp-peak" title="A janela de 5h do plano gasta mais rápido agora"><Icon name="flame" />Pico até {peakNow.until}</span>}
          {status.totalCost > 0 && <span className="mp-cost" title="Custo desta conversa (equivalente em API)">{usd(status.totalCost)}</span>}
          <SendButton state={status.running && empty ? "running" : empty ? "disabled" : "ready"} onClick={status.running && empty ? () => api.interrupt(id) : submit} />
        </div>
      </div>
    </div>
  );
}

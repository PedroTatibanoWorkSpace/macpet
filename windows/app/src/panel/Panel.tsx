// O painel: projetos na barra lateral e a conversa do projeto escolhido.
import { useCallback, useEffect, useState } from "react";
import { Button, EmptyState, IconButton, SidebarItem, type ProjectColor } from "../design-system/components";
import { ChatView } from "../chat/ChatView";
import { PetSprite } from "../pet/PetSprite";
import { api, type Project } from "../lib/api";
import "../chat/chat.css";
import "./panel.css";

export function Panel() {
  const [projects, setProjects] = useState<Project[]>([]);
  const [selected, setSelected] = useState<string | null>(() => {
    try { return localStorage.getItem("panel.selected"); } catch { return null; }
  });

  const reload = useCallback(() => api.projects().then(setProjects), []);

  useEffect(() => {
    reload();
    // Estado da barra lateral (trabalhando, esperando você) acompanha as conversas.
    const unlisten = api.onChat((event) => { if (event.status) reload(); });
    return () => { unlisten.then((stop) => stop()); };
  }, [reload]);

  useEffect(() => {
    if (projects.length && !projects.some((p) => p.id === selected)) setSelected(projects[0].id);
  }, [projects, selected]);

  useEffect(() => {
    try { if (selected) localStorage.setItem("panel.selected", selected); } catch { /* sem armazenamento: tudo bem */ }
  }, [selected]);

  // Ctrl+1…9 trocam de projeto.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const n = Number(e.key);
      if (e.ctrlKey && n >= 1 && n <= 9 && projects[n - 1]) { e.preventDefault(); setSelected(projects[n - 1].id); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [projects]);

  const add = async () => {
    const id = await api.addProject();
    await reload();
    if (id) setSelected(id);
  };

  const project = projects.find((p) => p.id === selected);

  return (
    <div className="panel">
      <aside className="panel-side">
        <div className="panel-brand"><PetSprite mood="idle" scale={1.5} /><span>Cawde</span></div>
        <div className="mp-section-label panel-label">Projetos</div>
        <div className="panel-list">
          {projects.map((p, i) => (
            <SidebarItem key={p.id} kind="project" title={p.name} color={p.color as ProjectColor} status={p.activity ?? undefined}
              shortcut={i < 9 ? `Ctrl+${i + 1}` : undefined} selected={p.id === selected} onClick={() => setSelected(p.id)} />
          ))}
        </div>
        <div className="panel-add"><Button variant="ghost" size="sm" icon="plus" onClick={add}>Adicionar projeto</Button></div>
      </aside>
      <main className="panel-main">
        {project ? (
          <>
            <header className="panel-header">
              <div>
                <div className="panel-title">{project.name}</div>
                <div className="panel-path" title={project.path}>{project.path}</div>
              </div>
              <span className="mp-grow" />
              <IconButton icon="x" label="Remover projeto do Cawde (a pasta não é apagada)" onClick={async () => { await api.removeProject(project.id); reload(); }} />
            </header>
            <ChatView key={project.id} project={project} />
          </>
        ) : (
          <div className="panel-empty">
            <EmptyState title="Adicione um projeto" body="Escolha a pasta de um projeto para conversar com o Claude Code nele. Cada projeto tem sua conversa, que continua rodando mesmo com o painel fechado."
              figure={<PetSprite mood="idle" scale={5} />} />
            <Button variant="primary" icon="plus" onClick={add}>Adicionar projeto</Button>
          </div>
        )}
      </main>
    </div>
  );
}

// A conversa de um projeto com o Claude: mensagens, cards de ferramenta, permissões e o composer.
// O estado vive no núcleo (Rust); aqui só desenhamos o que ele manda (evento "chat").
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Badge, Button, EmptyState, Icon, Loader, MessageBubble, PermissionCard, ToolCard, TurnDivider, type ProjectColor } from "../design-system/components";
import { PetSprite } from "../pet/PetSprite";
import { api, type ChatEvent, type ChatItem, type ChatStatus, type Project, type ToolCall } from "../lib/api";
import { duration, usd } from "../lib/format";
import { Composer } from "./Composer";
import { Markdown } from "./Markdown";

/// Quantas mensagens do fim são desenhadas; as anteriores entram pelo botão no topo (sem pular a rolagem).
const PAGE = 60;

export function ChatView({ project }: { project: Project }) {
  const [items, setItems] = useState<ChatItem[]>([]);
  const [status, setStatus] = useState<ChatStatus | null>(null);
  const [first, setFirst] = useState(0);
  const scroller = useRef<HTMLDivElement>(null);
  const follow = useRef(true);
  const [following, setFollowing] = useState(true);

  useEffect(() => {
    let cancelled = false;
    follow.current = true;
    setFollowing(true);
    // Escuta antes de pedir o retrato e guarda o que chegar até ele: senão o histórico (que chega num evento
    // logo depois de abrir) pode se perder. Do que foi guardado, só vale o que o retrato ainda não inclui.
    let seen: number | null = null;
    const early: ChatEvent[] = [];
    const apply = (event: ChatEvent) => {
      if (seen !== null && event.seq <= seen) return;
      if (event.reset) {
        setItems(event.reset);
        setFirst(Math.max(0, event.reset.length - PAGE));
      }
      if (event.items.length) {
        setItems((current) => {
          const next = current.slice();
          for (const { index, item } of event.items) next[index] = item;
          return next;
        });
      }
      if (event.status) setStatus(event.status);
    };
    const unlisten = api.onChat((event) => {
      if (event.projectId !== project.id) return;
      if (seen === null) early.push(event);
      else apply(event);
    });
    unlisten.then(() => api.openChat(project.id)).then((snapshot) => {
      if (cancelled || !snapshot) return;
      setItems(snapshot.items);
      setStatus(snapshot.status);
      setFirst(Math.max(0, snapshot.items.length - PAGE));
      seen = snapshot.seq;
      early.splice(0).forEach(apply);
    });
    return () => { cancelled = true; unlisten.then((stop) => stop()); };
  }, [project.id]);

  // Mensagem nova só puxa a rolagem se você já estava no fim (lendo lá em cima, fica onde está).
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el && follow.current) el.scrollTop = el.scrollHeight;
  }, [items, status?.running]);

  const onScroll = () => {
    const el = scroller.current;
    if (!el) return;
    const atEnd = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
    follow.current = atEnd;
    if (atEnd !== following) setFollowing(atEnd);
  };

  const goToEnd = () => {
    follow.current = true;
    setFollowing(true);
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  };

  const showEarlier = () => {
    const el = scroller.current;
    const before = el ? el.scrollHeight - el.scrollTop : 0;
    setFirst((f) => Math.max(0, f - PAGE));
    // As anteriores entram acima: mantém na tela a mesma mensagem.
    requestAnimationFrame(() => { if (el) el.scrollTop = el.scrollHeight - before; });
  };

  const color = project.color as ProjectColor;
  const visible = items.slice(first);

  return (
    <div className="chat">
      <div className="chat-scroll" ref={scroller} onScroll={onScroll}>
        <div className="chat-column">
          {first > 0 && (
            <div className="chat-earlier">
              <Button variant="ghost" size="sm" onClick={showEarlier}>Mostrar {Math.min(first, PAGE)} mensagens anteriores</Button>
            </div>
          )}
          {items.length === 0 && (status?.loadingHistory ? (
            <div className="chat-loading"><Loader label="Carregando a conversa…" /></div>
          ) : (
            <EmptyState title={`O que vamos fazer em ${project.name}?`} body="O Claude trabalha na pasta do projeto. Peça uma mudança, uma investigação ou uma revisão."
              hints={[["Enter", "envia"], ["Shift+Enter", "quebra a linha"], ["Ctrl+.", "para"]]} figure={<PetSprite mood="idle" scale={5} />} />
          ))}
          {visible.map((item, i) => <Item key={first + i} item={item} color={color} projectId={project.id} />)}
          {status?.running ? (
            <div className="chat-working">
              <PetSprite mood={status.pendingPermissions > 0 ? "waiting" : "working"} scale={2} />
              <span className={status.pendingPermissions > 0 ? "chat-waiting" : undefined}>
                {status.pendingPermissions > 0 ? "Esperando sua permissão…" : status.stopping ? "Parando…" : "Claude está trabalhando…"}
              </span>
            </div>
          ) : status && status.backgroundTasks.length > 0 ? (
            <div className="chat-working">
              <PetSprite mood="working" scale={2} />
              <div>
                <div>{backgroundTitle(status)}</div>
                {status.backgroundTasks.slice(0, 4).map((t) => <div key={t.id} className="chat-faint">· {t.description}</div>)}
                <div className="chat-faint">O Claude continua sozinho quando terminar. Pode fechar o Cawde.</div>
              </div>
            </div>
          ) : null}
        </div>
      </div>
      {!following && (
        <button type="button" className="chat-end" onClick={goToEnd}><Icon name="chev" /> Ir para o fim</button>
      )}
      {status && <Composer project={project} status={status} />}
    </div>
  );
}

function backgroundTitle(status: ChatStatus) {
  const agents = status.backgroundTasks.filter((t) => t.isAgent).length;
  const commands = status.backgroundTasks.length - agents;
  const parts = [agents && `${agents} agente${agents === 1 ? "" : "s"}`, commands && `${commands} comando${commands === 1 ? "" : "s"}`].filter(Boolean);
  return `${parts.join(" e ")} em segundo plano`;
}

const TOOL_ICON: Record<string, string> = { Read: "doc", Write: "doc", Edit: "pencil", MultiEdit: "pencil", Grep: "search", Glob: "search", Task: "split", Agent: "split", TodoWrite: "check", WebFetch: "info", WebSearch: "search" };

function Item({ item, color, projectId }: { item: ChatItem; color: ProjectColor; projectId: string }) {
  switch (item.kind) {
    case "user":
      return <div className="chat-user"><MessageBubble color={color}>{item.text}{item.images > 0 && <div className="chat-faint">{item.images} imagem(ns)</div>}</MessageBubble></div>;
    case "assistant":
      return item.text ? <Markdown text={item.text} /> : null;
    case "tool":
      return <Tool call={item.call} />;
    case "permission": {
      const r = item.request;
      if (r.status !== "pending") {
        return <div className="chat-notice-line"><Badge tone={r.status === "allowed" ? "success" : "danger"}>{r.status === "allowed" ? "Permitido" : "Negado"}</Badge> {r.tool.name} {r.tool.summary}</div>;
      }
      return <PermissionCard tool={r.tool.name} summary={r.tool.summary} detail={r.tool.detail ?? undefined} suggestion={r.suggestionLabel ?? undefined}
        onAllow={() => api.respond(projectId, r.requestId, true)} onSuggestion={() => api.respond(projectId, r.requestId, true, true)}
        onDeny={() => api.respond(projectId, r.requestId, false)} />;
    }
    case "result":
      return <TurnDivider error={item.isError}>{item.isError ? "erro" : "pronto"} · {duration(item.seconds)} · {usd(item.cost)}</TurnDivider>;
    case "notice":
      return <div className="chat-notice"><Icon name="info" />{item.text}</div>;
  }
}

function Tool({ call }: { call: ToolCall }) {
  const result = call.result && call.result.length > 4000 ? call.result.slice(0, 4000) + "\n…" : call.result;
  const progress = call.childSteps > 0 ? `${call.childSteps} passos · ${call.childLast ?? ""}` : undefined;
  return (
    <ToolCard tool={call.name} summary={call.summary} icon={TOOL_ICON[call.name] ?? "terminal"} running={call.result === null} error={call.isError} progress={progress}>
      <div className="tool-body">
        {call.edits.map(([before, after], i) => (
          <div key={i} className="mp-diff">
            {before.split("\n").map((l, j) => <div key={`o${j}`} className="mp-diff-line mp-diff-remove"><span /><span /><b>−</b><code>{l}</code></div>)}
            {after.split("\n").map((l, j) => <div key={`n${j}`} className="mp-diff-line mp-diff-add"><span /><span /><b>+</b><code>{l}</code></div>)}
          </div>
        ))}
        {call.detail && !call.edits.length && <pre className="mp-code">{call.detail.length > 4000 ? call.detail.slice(0, 4000) + "\n…" : call.detail}</pre>}
        {result && <pre className={`mp-code tool-result${call.isError ? " tool-result-error" : ""}`}>{result}</pre>}
      </div>
    </ToolCard>
  );
}

// Componentes do design system "MacPet" (Claude Design), em TypeScript. Mesmos nomes e classes CSS de
// source/project/components/bundle.js; aqui controlados por props (o bundle original guarda estado próprio
// porque é só vitrine).
import { Fragment, useState, type CSSProperties, type ReactNode } from "react";
import "./tokens.css";
import "./source/project/components/bundle.css";
import "./windows.css";

const cx = (...names: (string | false | null | undefined)[]) => names.filter(Boolean).join(" ");

// Ícones de linha no lugar dos SF Symbols.
const PATHS: Record<string, string> = {
  paperclip: "M17 7.5 9.6 14.9a2.6 2.6 0 0 1-3.7-3.7l7.6-7.6a4.2 4.2 0 0 1 5.9 5.9l-7.8 7.8a5.8 5.8 0 0 1-8.2-8.2l7-7",
  up: "M12 19V5M5.5 11.5 12 5l6.5 6.5", stop: "M7 7h10v10H7z", chev: "m6 9 6 6 6-6", check: "m5 12.5 4.5 4.5L19 7.5",
  branch: "M7 4v10m0 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm10-4a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 0c0 4-4 4-10 4",
  pin: "M9 3h6l-1 6 4 3v2H6v-2l4-3-1-6Zm3 11v7",
  flame: "M12 21c4 0 6-2.7 6-6 0-4-3-5.5-4-9-2 2-2.5 3.5-2.5 5.5C10 10 9 9 9 7.5 7 9.5 6 12 6 15c0 3.3 2 6 6 6Z",
  hand: "M8 11V5.5a1.5 1.5 0 0 1 3 0V11m0-1V4.5a1.5 1.5 0 0 1 3 0V11m0-.5V6a1.5 1.5 0 0 1 3 0v8c0 4-2.7 7-6.5 7-2.6 0-4-1-5.6-3.4L4 15a1.6 1.6 0 0 1 2.6-1.8L8 15",
  wand: "m4 20 11-11m2-5 .6 1.4L19 6l-1.4.6L17 8l-.6-1.4L15 6l1.4-.6L17 4ZM20 11l.4 1 .1.1 1 .4-1 .4-.5 1-.4-1-1-.5 1-.4.4-1Z",
  sparkle: "M12 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7Z",
  gauge: "M4 17a8 8 0 1 1 16 0M12 17l4-5", terminal: "M4 5h16v14H4zM8 10l3 2.5L8 15m5 0h3",
  doc: "M7 3h7l4 4v14H7zM14 3v4h4", pencil: "M15.5 5.5 18.5 8.5 9 18H6v-3l9.5-9.5Z", x: "M6 6l12 12M18 6 6 18",
  plus: "M12 5v14M5 12h14", split: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z", chat: "M4 5h16v11H9l-5 4z",
  dots: "M6 12h.01M12 12h.01M18 12h.01", alert: "M12 4 3 20h18L12 4Zm0 6v4m0 3h.01",
  moon: "M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z", info: "M12 8h.01M11 12h1v5h1M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z",
  search: "m20 20-4.5-4.5M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z", refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
  power: "M12 3v9M6.3 7a8 8 0 1 0 11.4 0",
};

export function Icon({ name, className }: { name: string; className?: string }) {
  return (
    <svg className={cx("mp-ico", className)} viewBox="0 0 24 24" aria-hidden>
      <path d={PATHS[name] ?? PATHS.dots} />
    </svg>
  );
}

type ButtonProps = { variant?: "primary" | "secondary" | "ghost" | "danger"; size?: "sm" | "md"; icon?: string; disabled?: boolean; onClick?: () => void; children?: ReactNode };
export function Button({ variant = "secondary", size, icon, disabled, onClick, children }: ButtonProps) {
  return (
    <button type="button" className={cx("mp-btn", `mp-btn-${variant}`, size === "sm" && "mp-btn-sm")} disabled={disabled} onClick={onClick}>
      {icon && <Icon name={icon} />}
      {children}
    </button>
  );
}

export function IconButton({ icon, label, glass, onClick }: { icon: string; label: string; glass?: boolean; onClick?: () => void }) {
  return (
    <button type="button" className={cx("mp-iconbtn", glass && "mp-iconbtn-glass")} aria-label={label} title={label} onClick={onClick}>
      <Icon name={icon} />
    </button>
  );
}

export function SendButton({ state, onClick }: { state: "ready" | "disabled" | "running"; onClick?: () => void }) {
  const running = state === "running";
  const label = running ? "Parar (Ctrl+.)" : "Enviar (Enter)";
  return (
    <button type="button" className={cx("mp-send", running && "mp-send-stop")} disabled={state === "disabled"} aria-label={label} title={label} onClick={onClick}>
      <Icon name={running ? "stop" : "up"} />
    </button>
  );
}

type TabItem = { id: string; label: string; count?: number; tone?: "ember" };
export function Tabs({ items, value, onChange }: { items: TabItem[]; value: string; onChange: (id: string) => void }) {
  return (
    <div className="mp-tabs" role="tablist">
      {items.map((it) => (
        <button key={it.id} role="tab" className="mp-tab" aria-selected={it.id === value} onClick={() => onChange(it.id)}>
          {it.label}
          {it.count ? <span className={cx("mp-tab-count", it.tone === "ember" && "mp-tab-count-ember")}>{it.count}</span> : null}
        </button>
      ))}
    </div>
  );
}

export function Switch({ checked, label, onChange }: { checked: boolean; label?: string; onChange: (on: boolean) => void }) {
  return (
    <span className="mp-switch" role="switch" tabIndex={0} aria-checked={checked} onClick={() => onChange(!checked)}
      onKeyDown={(e) => (e.key === " " || e.key === "Enter") && onChange(!checked)}>
      <span className="mp-switch-track" />
      {label}
    </span>
  );
}

export function Checkbox({ checked, label, onChange }: { checked: boolean; label?: string; onChange: (on: boolean) => void }) {
  return (
    <span className="mp-check" role="checkbox" tabIndex={0} aria-checked={checked} onClick={() => onChange(!checked)}
      onKeyDown={(e) => (e.key === " " || e.key === "Enter") && onChange(!checked)}>
      <span className="mp-check-box">{checked && <Icon name="check" />}</span>
      {label}
    </span>
  );
}

export type MenuItem = { label: string; detail?: string; checked?: boolean; shortcut?: string; danger?: boolean; onSelect?: () => void };
export type MenuSection = { title?: string; items: MenuItem[] };
export function Menu({ sections, onClose }: { sections: MenuSection[]; onClose?: () => void }) {
  return (
    <div className="mp-menu" role="menu">
      {sections.map((section, i) => (
        <Fragment key={i}>
          {i > 0 && <div className="mp-menu-sep" />}
          {section.title && <div className="mp-menu-label">{section.title}</div>}
          {section.items.map((item, j) => (
            <div key={j} role="menuitem" tabIndex={0} className={cx("mp-menu-item", item.danger && "mp-menu-danger")}
              onClick={() => { item.onSelect?.(); onClose?.(); }}>
              {item.checked ? <Icon name="check" className="check" /> : <span className="mp-spacer" />}
              <div>
                <div>{item.label}</div>
                {item.detail && <div className="mp-menu-detail">{item.detail}</div>}
              </div>
              {item.shortcut && <span className="mp-menu-short">{item.shortcut}</span>}
            </div>
          ))}
        </Fragment>
      ))}
    </div>
  );
}

export function Select({ icon, label, highlighted, sections }: { icon?: string; label?: string; highlighted?: boolean; sections: MenuSection[] }) {
  const [open, setOpen] = useState(false);
  return (
    <div style={{ position: "relative", display: "inline-flex" }}>
      <button type="button" className={cx("mp-select", highlighted && "mp-select-hl")} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        {icon && <Icon name={icon} />}
        {label && <span>{label}</span>}
        <Icon name="chev" className="mp-chev" />
      </button>
      {open && (
        <div style={{ position: "absolute", bottom: "calc(100% + 6px)", left: 0, zIndex: 10 }}>
          <Menu sections={sections} onClose={() => setOpen(false)} />
        </div>
      )}
    </div>
  );
}

export function Stepper({ value, min = -Infinity, max = Infinity, suffix = "", onChange }: { value: number; min?: number; max?: number; suffix?: string; onChange: (v: number) => void }) {
  return (
    <span className="mp-stepper">
      <button type="button" aria-label="Menos" onClick={() => onChange(Math.max(min, value - 1))}>−</button>
      <span>{value + suffix}</span>
      <button type="button" aria-label="Mais" onClick={() => onChange(Math.min(max, value + 1))}>+</button>
    </span>
  );
}

export function TextField({ label, placeholder, value, mono, hint, error, onChange }: { label?: string; placeholder?: string; value: string; mono?: boolean; hint?: string; error?: string; onChange: (v: string) => void }) {
  return (
    <label className="mp-field">
      {label && <span className="mp-field-label">{label}</span>}
      <input className={cx("mp-input", mono && "mp-mono")} placeholder={placeholder} value={value} onChange={(e) => onChange(e.target.value)} />
      {error ? <span className="mp-field-error">{error}</span> : hint && <span className="mp-field-hint">{hint}</span>}
    </label>
  );
}

export function TextArea({ label, placeholder, value, rows = 3, mono, hint, onChange }: { label?: string; placeholder?: string; value: string; rows?: number; mono?: boolean; hint?: string; onChange: (v: string) => void }) {
  return (
    <label className="mp-field">
      {label && <span className="mp-field-label">{label}</span>}
      <textarea className={cx("mp-textarea", mono && "mp-mono")} rows={rows} placeholder={placeholder} value={value} onChange={(e) => onChange(e.target.value)} />
      {hint && <span className="mp-field-hint">{hint}</span>}
    </label>
  );
}

export type ProjectColor = "violet" | "teal" | "pumpkin" | "rose" | "sky" | "sage" | "sand" | "slate";
const projectVar = (color?: ProjectColor) => `var(--project-${color ?? "violet"})`;

export function Monogram({ name, color, size = 20 }: { name: string; color?: ProjectColor; size?: number }) {
  return (
    <span className="mp-mono-tile" aria-hidden style={{ width: size, height: size, fontSize: size * 0.6, borderRadius: size * 0.28, background: projectVar(color) }}>
      {(name || "?").charAt(0).toUpperCase()}
    </span>
  );
}

export type Status = "working" | "waiting" | "ok" | "error" | "idle";
const STATUS_LABEL: Record<Status, string> = { working: "trabalhando", waiting: "esperando você", ok: "conectado", error: "falhou", idle: "parado" };
export function StatusDot({ status = "idle", label, hideLabel }: { status?: Status; label?: string; hideLabel?: boolean }) {
  return (
    <span className={`mp-dot mp-dot-${status}`}>
      <i />
      {hideLabel ? null : label ?? STATUS_LABEL[status]}
    </span>
  );
}

export function SidebarItem({ kind, title, color, status, shortcut, selected, icon, onClick }: { kind: "project" | "task" | "pinned" | "section"; title: string; color?: ProjectColor; status?: "working" | "waiting"; shortcut?: string; selected?: boolean; icon?: string; onClick?: () => void }) {
  const lead = kind === "project" ? <Monogram name={title} color={color} />
    : kind === "section" ? <Icon name={icon ?? "doc"} />
    : <span style={{ color: projectVar(color), display: "inline-flex" }}><Icon name={kind === "pinned" ? "pin" : "branch"} /></span>;
  return (
    <div className={cx("mp-side-item", (kind === "task" || kind === "pinned") && "mp-side-child")} aria-current={selected || undefined} onClick={onClick}>
      {lead}
      <span className="mp-grow">{title}</span>
      {status && <StatusDot status={status} hideLabel />}
      {shortcut && <span className="mp-short">{shortcut}</span>}
    </div>
  );
}

export function Card({ title, children }: { title?: string; children?: ReactNode }) {
  return (
    <div className="mp-card">
      {title && <div className="mp-card-title">{title}</div>}
      {children}
    </div>
  );
}

export function ListRow({ title, subtitle, meta, leading, selected, onClick }: { title: string; subtitle?: string; meta?: string; leading?: ReactNode; selected?: boolean; onClick?: () => void }) {
  return (
    <div className="mp-listrow" aria-selected={selected || undefined} onClick={onClick}>
      {leading}
      <div className="mp-grow">
        <div className="mp-listrow-title">{title}</div>
        {subtitle && <div className="mp-listrow-sub">{subtitle}</div>}
      </div>
      {meta && <span className="mp-listrow-meta">{meta}</span>}
    </div>
  );
}

export function Dialog({ title, body, actions, children }: { title: string; body?: string; actions: { label: string; variant?: ButtonProps["variant"]; onClick?: () => void }[]; children?: ReactNode }) {
  return (
    <div className="mp-dialog" role="dialog" aria-label={title}>
      <h3>{title}</h3>
      {body && <p>{body}</p>}
      {children}
      <div className="mp-dialog-actions">
        {actions.map((a, i) => <Button key={i} variant={a.variant} onClick={a.onClick}>{a.label}</Button>)}
      </div>
    </div>
  );
}

export function Banner({ tone = "info", title, body }: { tone?: "peak" | "info" | "danger" | "quiet"; title: string; body?: string }) {
  const icon = { peak: "flame", info: "info", danger: "alert", quiet: "moon" }[tone];
  return (
    <div className={`mp-banner mp-banner-${tone}`} role="status">
      <Icon name={icon} />
      <div><b>{title}</b>{body && <span>{body}</span>}</div>
    </div>
  );
}

export function EmptyState({ title, body, hints, figure }: { title: string; body?: string; hints?: [string, string][]; figure?: ReactNode }) {
  return (
    <div className="mp-empty">
      {figure}
      <h3>{title}</h3>
      {body && <p>{body}</p>}
      {hints && <div className="mp-keys">{hints.map(([key, text], i) => <span key={i}><span className="mp-key">{key}</span>{text}</span>)}</div>}
    </div>
  );
}

export function Badge({ tone = "neutral", mono, icon, children }: { tone?: "neutral" | "sheen" | "ember" | "success" | "danger"; mono?: boolean; icon?: string; children?: ReactNode }) {
  return (
    <span className={cx("mp-badge", `mp-badge-${tone}`, mono && "mp-badge-mono")}>
      {icon && <Icon name={icon} />}
      {children}
    </span>
  );
}

export function Meter({ label, value, foot }: { label: string; value: number; foot?: string }) {
  const level = value >= 90 ? "high" : value >= 70 ? "warn" : "ok";
  return (
    <div className="mp-meter" data-level={level}>
      <div className="mp-meter-top">
        <span className="mp-meter-title">{label}</span>
        <span className="mp-meter-value">{Math.round(value)}%</span>
      </div>
      <div className="mp-meter-bar" role="progressbar" aria-valuenow={value} aria-valuemin={0} aria-valuemax={100}>
        <i style={{ width: `${Math.min(100, value)}%` }} />
      </div>
      {foot && <div className="mp-meter-foot">{foot}</div>}
    </div>
  );
}

export function Loader({ label }: { label?: string }) {
  return (
    <span className="mp-dot">
      <span className="mp-loader" aria-hidden><i /><i /><i /></span>
      {label}
    </span>
  );
}

export function MessageBubble({ color, children }: { color?: ProjectColor; children?: ReactNode }) {
  return <div className="mp-bubble" style={{ "--bubble": projectVar(color) } as CSSProperties}>{children}</div>;
}

export function ToolCard({ tool, summary, icon, running, error, progress, children }: { tool: string; summary: string; icon?: string; running?: boolean; error?: boolean; progress?: string; children?: ReactNode }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={cx("mp-tool", error && "mp-tool-error")}>
      <div className="mp-tool-head" onClick={() => setOpen(!open)} style={{ cursor: "pointer" }}>
        <Icon name={icon ?? "terminal"} />
        <span className="mp-tool-name">{tool}</span>
        <span className="mp-tool-sum">{summary}</span>
        {running ? <Loader /> : <Icon name="chev" />}
      </div>
      {progress && <div className="mp-tool-progress">{progress}</div>}
      {open && children}
    </div>
  );
}

export function PermissionCard({ tool, summary, detail, suggestion, onAllow, onSuggestion, onDeny }: { tool: string; summary: string; detail?: string; suggestion?: string; onAllow?: () => void; onSuggestion?: () => void; onDeny?: () => void }) {
  return (
    <div className="mp-perm" role="group" aria-label="Pedido de permissão">
      <div className="mp-perm-head"><Icon name="hand" /><b>Permitir {tool}?</b><span className="mp-tool-sum">{summary}</span></div>
      {detail && <pre className="mp-code">{detail}</pre>}
      <div className="mp-perm-actions">
        <Button variant="primary" size="sm" onClick={onAllow}>Permitir</Button>
        {suggestion && <Button size="sm" onClick={onSuggestion}>{suggestion}</Button>}
        <Button variant="danger" size="sm" onClick={onDeny}>Negar</Button>
        <span className="mp-grow" />
        <span className="mp-short">Ctrl+Enter permite</span>
      </div>
    </div>
  );
}

export function TurnDivider({ error, children }: { error?: boolean; children?: ReactNode }) {
  return <div className={cx("mp-divider", error && "mp-divider-error")}>{children}</div>;
}

export function DiffView({ lines, hunk, start = 1 }: { lines: string[]; hunk?: string; start?: number }) {
  let old = start, now = start;
  return (
    <div className="mp-diff">
      {hunk && <div className="mp-diff-hunk">{hunk}</div>}
      {lines.map((line, i) => {
        const kind = line[0] === "+" ? "add" : line[0] === "-" ? "remove" : "ctx";
        const a = kind === "add" ? "" : old++, b = kind === "remove" ? "" : now++;
        return (
          <div key={i} className={cx("mp-diff-line", kind !== "ctx" && `mp-diff-${kind}`)}>
            <span>{a}</span><span>{b}</span><b>{kind === "add" ? "+" : kind === "remove" ? "−" : ""}</b><code>{line.slice(1)}</code>
          </div>
        );
      })}
    </div>
  );
}

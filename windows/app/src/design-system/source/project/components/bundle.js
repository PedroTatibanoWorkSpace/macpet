/* @ds-bundle: {"format":4,"namespace":"MacPet","components":[{"name":"Button"},{"name":"IconButton"},{"name":"SendButton"},{"name":"Tabs"},{"name":"Switch"},{"name":"Checkbox"},{"name":"Select"},{"name":"Menu"},{"name":"Stepper"},{"name":"TextField"},{"name":"TextArea"},{"name":"Composer"},{"name":"ProjectHeader"},{"name":"SidebarItem"},{"name":"Monogram"},{"name":"Card"},{"name":"ListRow"},{"name":"Dialog"},{"name":"Banner"},{"name":"EmptyState"},{"name":"Badge"},{"name":"StatusDot"},{"name":"Meter"},{"name":"Loader"},{"name":"MessageBubble"},{"name":"ToolCard"},{"name":"PermissionCard"},{"name":"TurnDivider"},{"name":"TaskPlanCard"},{"name":"DiffView"}]} */
(function () {
  var React = window.React, h = React.createElement, useState = React.useState;
  var cx = function () { return Array.prototype.filter.call(arguments, Boolean).join(" "); };

  // Line icons standing in for SF Symbols.
  var PATHS = {
    paperclip: "M17 7.5 9.6 14.9a2.6 2.6 0 0 1-3.7-3.7l7.6-7.6a4.2 4.2 0 0 1 5.9 5.9l-7.8 7.8a5.8 5.8 0 0 1-8.2-8.2l7-7",
    up: "M12 19V5M5.5 11.5 12 5l6.5 6.5", stop: "M7 7h10v10H7z", chev: "m6 9 6 6 6-6", check: "m5 12.5 4.5 4.5L19 7.5",
    branch: "M7 4v10m0 0a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm10-4a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm0 0c0 4-4 4-10 4",
    pin: "M9 3h6l-1 6 4 3v2H6v-2l4-3-1-6Zm3 11v7", flame: "M12 21c4 0 6-2.7 6-6 0-4-3-5.5-4-9-2 2-2.5 3.5-2.5 5.5C10 10 9 9 9 7.5 7 9.5 6 12 6 15c0 3.3 2 6 6 6Z",
    hand: "M8 11V5.5a1.5 1.5 0 0 1 3 0V11m0-1V4.5a1.5 1.5 0 0 1 3 0V11m0-.5V6a1.5 1.5 0 0 1 3 0v8c0 4-2.7 7-6.5 7-2.6 0-4-1-5.6-3.4L4 15a1.6 1.6 0 0 1 2.6-1.8L8 15",
    wand: "m4 20 11-11m2-5 .6 1.4L19 6l-1.4.6L17 8l-.6-1.4L15 6l1.4-.6L17 4ZM20 11l.4 1 .1.1 1 .4-1 .4-.5 1-.4-1-1-.5 1-.4.4-1Z",
    sparkle: "M12 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7Z",
    gauge: "M4 17a8 8 0 1 1 16 0M12 17l4-5", terminal: "M4 5h16v14H4zM8 10l3 2.5L8 15m5 0h3",
    doc: "M7 3h7l4 4v14H7zM14 3v4h4", pencil: "M15.5 5.5 18.5 8.5 9 18H6v-3l9.5-9.5Z", x: "M6 6l12 12M18 6 6 18",
    plus: "M12 5v14M5 12h14", split: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z", chat: "M4 5h16v11H9l-5 4z",
    dots: "M6 12h.01M12 12h.01M18 12h.01", alert: "M12 4 3 20h18L12 4Zm0 6v4m0 3h.01", moon: "M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z",
    info: "M12 8h.01M11 12h1v5h1M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", search: "m20 20-4.5-4.5M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z"
  };
  function Icon(p) { return h("svg", { className: cx("mp-ico", p.className), viewBox: "0 0 24 24", "aria-hidden": true }, h("path", { d: PATHS[p.name] || PATHS.dots })); }

  function Button(p) {
    return h("button", { type: "button", className: cx("mp-btn", "mp-btn-" + (p.variant || "secondary"), p.size === "sm" && "mp-btn-sm"), disabled: p.disabled, onClick: p.onClick },
      p.icon && h(Icon, { name: p.icon }), p.children);
  }
  function IconButton(p) {
    return h("button", { type: "button", className: cx("mp-iconbtn", p.glass && "mp-iconbtn-glass"), "aria-label": p.label, title: p.label, onClick: p.onClick }, h(Icon, { name: p.icon }));
  }
  function SendButton(p) {
    var running = p.state === "running";
    return h("button", { type: "button", className: cx("mp-send", running && "mp-send-stop"), disabled: p.state === "disabled",
      "aria-label": running ? "Parar (⌘.)" : "Enviar (⏎)", title: running ? "Parar (⌘.)" : "Enviar (⏎)" }, h(Icon, { name: running ? "stop" : "up" }));
  }

  function Tabs(p) {
    var s = useState(p.value || (p.items[0] && p.items[0].id)), value = s[0], set = s[1];
    return h("div", { className: "mp-tabs", role: "tablist" }, p.items.map(function (it) {
      return h("button", { key: it.id, role: "tab", className: "mp-tab", "aria-selected": it.id === value, onClick: function () { set(it.id); } },
        it.label, it.count ? h("span", { className: cx("mp-tab-count", it.tone === "ember" && "mp-tab-count-ember") }, it.count) : null);
    }));
  }
  function Switch(p) {
    var s = useState(!!p.checked), on = s[0], set = s[1];
    return h("span", { className: "mp-switch", role: "switch", tabIndex: 0, "aria-checked": on, onClick: function () { set(!on); } },
      h("span", { className: "mp-switch-track" }), p.label);
  }
  function Checkbox(p) {
    var s = useState(!!p.checked), on = s[0], set = s[1];
    return h("span", { className: "mp-check", role: "checkbox", tabIndex: 0, "aria-checked": on, onClick: function () { set(!on); } },
      h("span", { className: "mp-check-box" }, on && h(Icon, { name: "check" })), p.label);
  }

  function Menu(p) {
    return h("div", { className: "mp-menu", role: "menu" }, (p.sections || []).map(function (sec, i) {
      return h(React.Fragment, { key: i },
        i > 0 && h("div", { className: "mp-menu-sep" }),
        sec.title && h("div", { className: "mp-menu-label" }, sec.title),
        sec.items.map(function (it, j) {
          return h("div", { key: j, role: "menuitem", className: cx("mp-menu-item", it.danger && "mp-menu-danger"), "data-active": it.active || undefined },
            it.checked ? h(Icon, { name: "check", className: "check" }) : h("span", { className: "mp-spacer" }),
            h("div", null, h("div", null, it.label), it.detail && h("div", { className: "mp-menu-detail" }, it.detail)),
            it.shortcut && h("span", { className: "mp-menu-short" }, it.shortcut));
        }));
    }));
  }
  function Select(p) {
    var s = useState(!!p.open), open = s[0], set = s[1];
    return h("div", { style: { display: "inline-flex", flexDirection: "column", gap: 6, alignItems: "flex-start" } },
      h("button", { type: "button", className: cx("mp-select", p.highlighted && "mp-select-hl"), "aria-haspopup": "menu", "aria-expanded": open, onClick: function () { set(!open); } },
        p.icon && h(Icon, { name: p.icon }), p.label && h("span", null, p.label), h(Icon, { name: "chev", className: "mp-chev" })),
      open && p.sections && h(Menu, { sections: p.sections }));
  }
  function Stepper(p) {
    var s = useState(p.value || 0), v = s[0], set = s[1];
    var min = p.min == null ? -Infinity : p.min, max = p.max == null ? Infinity : p.max;
    return h("span", { className: "mp-stepper" },
      h("button", { type: "button", "aria-label": "Menos", onClick: function () { set(Math.max(min, v - 1)); } }, "−"),
      h("span", null, v + (p.suffix || "")),
      h("button", { type: "button", "aria-label": "Mais", onClick: function () { set(Math.min(max, v + 1)); } }, "+"));
  }

  function TextField(p) {
    return h("label", { className: "mp-field" },
      p.label && h("span", { className: "mp-field-label" }, p.label),
      h("input", { className: cx("mp-input", p.mono && "mp-mono"), placeholder: p.placeholder, defaultValue: p.value }),
      p.error ? h("span", { className: "mp-field-error" }, p.error) : p.hint && h("span", { className: "mp-field-hint" }, p.hint));
  }
  function TextArea(p) {
    return h("label", { className: "mp-field" },
      p.label && h("span", { className: "mp-field-label" }, p.label),
      h("textarea", { className: cx("mp-textarea", p.mono && "mp-mono"), rows: p.rows || 3, placeholder: p.placeholder, defaultValue: p.value }),
      p.hint && h("span", { className: "mp-field-hint" }, p.hint));
  }

  function Composer(p) {
    return h("div", { className: "mp-composer" },
      p.attachments ? h("div", { className: "mp-thumbs" }, Array.from({ length: p.attachments }).map(function (_, i) { return h("div", { key: i, className: "mp-thumb" }); })) : null,
      h("textarea", { className: "mp-composer-input", rows: 1, defaultValue: p.draft || "", "aria-label": "Mensagem para o Claude" }),
      h("div", { className: "mp-composer-bar" },
        h(IconButton, { icon: "paperclip", label: "Anexar imagem" }),
        h(Select, { icon: p.mode === "auto" ? "wand" : "hand", label: p.mode === "auto" ? "Auto" : "Pedir permissão", highlighted: p.mode === "auto" }),
        h(Select, { icon: "sparkle", label: p.model || "Padrão (Opus 5.5)" }),
        h(Select, { icon: "gauge", label: p.effort || "Esforço padrão" }),
        h(Select, { icon: "chat" }),
        h("span", { className: "mp-grow" }),
        p.peak && h("span", { className: "mp-peak" }, h(Icon, { name: "flame" }), "Pico até " + p.peak),
        p.cost && h("span", { className: "mp-cost" }, p.cost),
        h(SendButton, { state: p.running ? "running" : (p.draft || p.attachments) ? "ready" : "disabled" })));
  }

  var PROJECT = { violet: "--project-violet", teal: "--project-teal", pumpkin: "--project-pumpkin", rose: "--project-rose", sky: "--project-sky", sage: "--project-sage", sand: "--project-sand", slate: "--project-slate" };
  function Monogram(p) {
    var size = p.size || 20;
    return h("span", { className: "mp-mono-tile", "aria-hidden": true, style: { width: size, height: size, fontSize: size * 0.6, borderRadius: size * 0.28, background: "var(" + (PROJECT[p.color] || PROJECT.violet) + ")" } },
      (p.name || "?").charAt(0).toUpperCase());
  }
  function StatusDot(p) {
    var labels = { working: "trabalhando", waiting: "esperando você", ok: "conectado", error: "falhou", idle: "parado" };
    return h("span", { className: "mp-dot mp-dot-" + (p.status || "idle") }, h("i"), p.hideLabel ? null : (p.label || labels[p.status || "idle"]));
  }
  function ProjectHeader(p) {
    return h("div", { className: "mp-header" },
      h("div", { className: "mp-header-title" }, h(Monogram, { name: p.parent || p.name, color: p.color, size: 26 }),
        h("div", null,
          h("div", { className: "mp-header-name" }, p.parent && h("span", { className: "mp-header-parent" }, p.parent + " › "), p.name),
          h("button", { type: "button", className: "mp-branch", title: "Trocar de branch" }, h(Icon, { name: "branch" }), p.branch || "main", h(Icon, { name: "chev" })))),
      h("span", { className: "mp-grow" }),
      h(Tabs, { value: p.tab || "chat", items: [{ id: "chat", label: "Chat" }, { id: "changes", label: "Alterações", count: p.changes }, { id: "agents", label: "Agentes" }, { id: "terminal", label: "Terminal" }] }),
      h("span", { className: "mp-grow" }),
      h(IconButton, { icon: "split", label: "Nova tarefa", glass: true }),
      h(IconButton, { icon: "dots", label: "Opções do projeto", glass: true }));
  }
  function SidebarItem(p) {
    var lead = p.kind === "project" ? h(Monogram, { name: p.title, color: p.color }) :
      p.kind === "section" ? h(Icon, { name: p.icon || "doc" }) :
      h("span", { style: { color: "var(" + (PROJECT[p.color] || PROJECT.violet) + ")", display: "inline-flex" } }, h(Icon, { name: p.kind === "pinned" ? "pin" : "branch" }));
    return h("div", { className: cx("mp-side-item", (p.kind === "task" || p.kind === "pinned") && "mp-side-child"), "aria-current": p.selected || undefined },
      lead, h("span", { className: "mp-grow" }, p.title),
      p.status && h(StatusDot, { status: p.status, hideLabel: true }),
      p.shortcut && h("span", { className: "mp-short" }, p.shortcut));
  }

  function Card(p) { return h("div", { className: "mp-card" }, p.title && h("div", { className: "mp-card-title" }, p.title), p.children); }
  function ListRow(p) {
    return h("div", { className: "mp-listrow", "aria-selected": p.selected || undefined },
      p.leading, h("div", { className: "mp-grow" }, h("div", { className: "mp-listrow-title" }, p.title), p.subtitle && h("div", { className: "mp-listrow-sub" }, p.subtitle)),
      p.meta && h("span", { className: "mp-listrow-meta" }, p.meta));
  }
  function Dialog(p) {
    return h("div", { className: "mp-dialog", role: "dialog", "aria-label": p.title },
      h("h3", null, p.title), p.body && h("p", null, p.body), p.children,
      h("div", { className: "mp-dialog-actions" }, (p.actions || []).map(function (a, i) { return h(Button, { key: i, variant: a.variant, onClick: a.onClick }, a.label); })));
  }
  function Banner(p) {
    var icon = { peak: "flame", info: "info", danger: "alert", quiet: "moon" }[p.tone || "info"];
    return h("div", { className: "mp-banner mp-banner-" + (p.tone || "info"), role: "status" }, h(Icon, { name: icon }), h("div", null, h("b", null, p.title), p.body && h("span", null, p.body)));
  }
  function EmptyState(p) {
    return h("div", { className: "mp-empty" },
      p.figure,
      h("h3", null, p.title), p.body && h("p", null, p.body),
      p.hints && h("div", { className: "mp-keys" }, p.hints.map(function (k, i) { return h("span", { key: i }, h("span", { className: "mp-key" }, k[0]), k[1]); })));
  }
  function Badge(p) { return h("span", { className: cx("mp-badge", "mp-badge-" + (p.tone || "neutral"), p.mono && "mp-badge-mono") }, p.icon && h(Icon, { name: p.icon }), p.children); }
  function Meter(p) {
    var level = p.value >= 90 ? "high" : p.value >= 70 ? "warn" : "ok";
    return h("div", { className: "mp-meter", "data-level": level },
      h("div", { className: "mp-meter-top" }, h("span", { className: "mp-meter-title" }, p.label), h("span", { className: "mp-meter-value" }, Math.round(p.value) + "%")),
      h("div", { className: "mp-meter-bar", role: "progressbar", "aria-valuenow": p.value, "aria-valuemin": 0, "aria-valuemax": 100 }, h("i", { style: { width: Math.min(100, p.value) + "%" } })),
      p.foot && h("div", { className: "mp-meter-foot" }, p.foot));
  }
  function Loader(p) { return h("span", { className: "mp-dot" }, h("span", { className: "mp-loader", "aria-hidden": true }, h("i"), h("i"), h("i")), p.label); }

  function MessageBubble(p) {
    return h("div", { className: "mp-bubble", style: { "--bubble": "var(" + (PROJECT[p.color] || PROJECT.violet) + ")" } }, p.children);
  }
  function ToolCard(p) {
    var s = useState(!!p.expanded), open = s[0], set = s[1];
    return h("div", { className: cx("mp-tool", p.error && "mp-tool-error") },
      h("div", { className: "mp-tool-head", onClick: function () { set(!open); }, style: { cursor: "pointer" } },
        h(Icon, { name: p.icon || "terminal" }), h("span", { className: "mp-tool-name" }, p.tool), h("span", { className: "mp-tool-sum" }, p.summary),
        p.running ? h(Loader) : h(Icon, { name: "chev", className: "" })),
      p.progress && h("div", { className: "mp-tool-progress" }, p.progress),
      (open || p.diff) && p.children);
  }
  function PermissionCard(p) {
    return h("div", { className: "mp-perm", role: "group", "aria-label": "Pedido de permissão" },
      h("div", { className: "mp-perm-head" }, h(Icon, { name: "hand" }), h("b", null, "Permitir " + p.tool + "?"), h("span", { className: "mp-tool-sum" }, p.summary)),
      p.detail && h("pre", { className: "mp-code" }, p.detail),
      h("div", { className: "mp-perm-actions" },
        h(Button, { variant: "primary", size: "sm" }, "Permitir"),
        p.suggestion && h(Button, { variant: "secondary", size: "sm" }, p.suggestion),
        h(Button, { variant: "danger", size: "sm" }, "Negar"),
        h("span", { className: "mp-grow" }), h("span", { className: "mp-short" }, "⌘⏎ permite")));
  }
  function TurnDivider(p) { return h("div", { className: cx("mp-divider", p.error && "mp-divider-error") }, p.children); }
  function TaskPlanCard(p) {
    return h("div", { className: "mp-plan" },
      h("div", { className: "mp-plan-head" }, h(Icon, { name: "split" }), h("h4", null, "Plano: " + p.tasks.length + " tarefas em paralelo"), h("span", { className: "mp-short" }, "briefings ≈ " + (p.tokens || "600") + " tokens")),
      p.tasks.map(function (t, i) {
        return h("div", { key: i, className: "mp-plan-task" }, h(Checkbox, { checked: true }),
          h("div", { className: "mp-plan-body" },
            h("div", { style: { display: "flex", gap: 6, alignItems: "center" } }, h("b", { style: { flex: 1 } }, t.title), t.model && h(Badge, { mono: true }, t.model), t.effort && h(Badge, { mono: true }, t.effort)),
            h("div", { className: "mp-plan-branch" }, t.branch), h("div", { className: "mp-plan-brief" }, t.brief)));
      }),
      h("div", { className: "mp-plan-foot" }, h("span", null, "Cada tarefa ganha branch, worktree e conversa próprias; o agente começa só com o briefing."),
        h(Button, { variant: "primary" }, "Lançar " + p.tasks.length + " tarefas")));
  }
  function DiffView(p) {
    var old = p.start || 1, nu = p.start || 1;
    return h("div", { className: "mp-diff" }, p.hunk && h("div", { className: "mp-diff-hunk" }, p.hunk),
      p.lines.map(function (l, i) {
        var kind = l[0] === "+" ? "add" : l[0] === "-" ? "remove" : "ctx";
        var a = kind === "add" ? "" : old++, b = kind === "remove" ? "" : nu++;
        return h("div", { key: i, className: cx("mp-diff-line", kind !== "ctx" && "mp-diff-" + kind) },
          h("span", null, a), h("span", null, b), h("b", null, kind === "add" ? "+" : kind === "remove" ? "−" : ""), h("code", null, l.slice(1)));
      }));
  }

  window.MacPet = { Icon: Icon, Button: Button, IconButton: IconButton, SendButton: SendButton, Tabs: Tabs, Switch: Switch, Checkbox: Checkbox, Select: Select, Menu: Menu,
    Stepper: Stepper, TextField: TextField, TextArea: TextArea, Composer: Composer, ProjectHeader: ProjectHeader, SidebarItem: SidebarItem, Monogram: Monogram,
    Card: Card, ListRow: ListRow, Dialog: Dialog, Banner: Banner, EmptyState: EmptyState, Badge: Badge, StatusDot: StatusDot, Meter: Meter, Loader: Loader,
    MessageBubble: MessageBubble, ToolCard: ToolCard, PermissionCard: PermissionCard, TurnDivider: TurnDivider, TaskPlanCard: TaskPlanCard, DiffView: DiffView };
})();

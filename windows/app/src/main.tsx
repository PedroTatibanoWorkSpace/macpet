import React from "react";
import ReactDOM from "react-dom/client";
import { Popover } from "./popover/Popover";
import { Panel } from "./panel/Panel";

// Uma página para cada janela, escolhida pelo endereço (index.html#popover). Mais telas entram nas próximas fases.
const route = window.location.hash.replace("#", "");

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>{route === "popover" ? <Popover /> : route === "panel" ? <Panel /> : null}</React.StrictMode>,
);

// Comandos e eventos do núcleo em Rust (src-tauri/src/lib.rs).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type RateWindow = { usedPercentage: number; resetsAt: number | null };
export type Limits = { fiveHour: RateWindow | null; sevenDay: RateWindow | null; updatedAt: number | null };
export type Metrics = { cpu: number; memoryUsed: number; memoryTotal: number; diskUsed: number; diskTotal: number; netIn: number; netOut: number };
export type PetState = { mood: "idle" | "working" | "waiting" | "celebrating" | "tired" | "sleeping"; description: string };

export type Settings = { mode: string; model: string; effort: string | null; usesMcp: boolean };
export type Project = { id: string; path: string; name: string; color: string; lastSessionId: string | null; settings: Settings; activity: "working" | "waiting" | null };
export type ToolCall = {
  id: string; name: string; summary: string; detail: string | null; edits: [string, string][];
  result: string | null; isError: boolean; childSteps: number; childLast: string | null;
};
export type Permission = { requestId: string; tool: ToolCall; suggestionLabel: string | null; status: "pending" | "allowed" | "denied" };
export type ChatItem =
  | { kind: "user"; text: string; images: number }
  | { kind: "assistant"; text: string }
  | { kind: "tool"; call: ToolCall }
  | { kind: "permission"; request: Permission }
  | { kind: "result"; cost: number; seconds: number; isError: boolean }
  | { kind: "notice"; text: string };
export type BackgroundTask = { id: string; description: string; isAgent: boolean };
export type ChatStatus = {
  running: boolean; stopping: boolean; sessionId: string | null; modelName: string | null; totalCost: number;
  settings: Settings; backgroundTasks: BackgroundTask[]; pendingPermissions: number; loadingHistory: boolean;
};
export type Snapshot = { items: ChatItem[]; status: ChatStatus; seq: number };
export type ChatEvent = { projectId: string; items: { index: number; item: ChatItem }[]; status: ChatStatus | null; reset: ChatItem[] | null; seq: number };
export type ModelOption = { value: string; name: string; detail: string; efforts: string[] };

export const api = {
  limits: () => invoke<Limits>("limits"),
  refreshLimits: () => invoke<void>("refresh_limits"),
  metrics: () => invoke<Metrics>("metrics"),
  petState: () => invoke<PetState>("pet_state"),
  openPanel: () => invoke<void>("open_panel"),
  openUrl: (url: string) => invoke<void>("open_url", { url }),
  quit: () => invoke<void>("quit"),

  projects: () => invoke<Project[]>("projects"),
  addProject: () => invoke<string | null>("add_project"),
  removeProject: (projectId: string) => invoke<void>("remove_project", { projectId }),
  openChat: (projectId: string) => invoke<Snapshot | null>("open_chat", { projectId }),
  send: (projectId: string, text: string) => invoke<void>("send", { projectId, text }),
  interrupt: (projectId: string) => invoke<void>("interrupt", { projectId }),
  respond: (projectId: string, requestId: string, allow: boolean, applySuggestion = false) =>
    invoke<void>("respond", { projectId, requestId, allow, applySuggestion }),
  setMode: (projectId: string, mode: string) => invoke<void>("set_mode", { projectId, mode }),
  setModel: (projectId: string, model: string) => invoke<void>("set_model", { projectId, model }),
  setEffort: (projectId: string, effort: string | null) => invoke<void>("set_effort", { projectId, effort }),
  setUsesMcp: (projectId: string, enabled: boolean) => invoke<void>("set_uses_mcp", { projectId, enabled }),
  newConversation: (projectId: string) => invoke<void>("new_conversation", { projectId }),
  models: () => invoke<ModelOption[]>("models"),

  onChat: (handler: (event: ChatEvent) => void): Promise<UnlistenFn> => listen<ChatEvent>("chat", (e) => handler(e.payload)),
};

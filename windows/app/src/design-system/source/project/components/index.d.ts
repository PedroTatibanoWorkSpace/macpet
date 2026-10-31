import type * as React from 'react';
export type ProjectColor = 'violet'|'teal'|'pumpkin'|'rose'|'sky'|'sage'|'sand'|'slate';
export interface MenuSection { title?: string; items: { label: string; detail?: string; checked?: boolean; shortcut?: string; danger?: boolean }[] }
/** A labelled action; primary is the one action a screen exists for. */
export interface ButtonProps { variant?: 'primary'|'secondary'|'ghost'|'danger'; size?: 'sm'|'md'; icon?: string; disabled?: boolean; onClick?: () => void; children?: React.ReactNode?: React.ReactNode }
export declare function Button(props: ButtonProps): React.ReactElement;
/** A square icon-only action with a tooltip label. */
export interface IconButtonProps { icon: string; label: string; glass?: boolean; onClick?: () => void }
export declare function IconButton(props: IconButtonProps): React.ReactElement;
/** The round send / stop control at the end of the composer. */
export interface SendButtonProps { state: 'ready'|'disabled'|'running' }
export declare function SendButton(props: SendButtonProps): React.ReactElement;
/** Pill tabs that switch between views of one project. */
export interface TabsProps { items: {id,label,count?,tone?: 'ember'}[]; value?: string; onChange?: (id) => void }
export declare function Tabs(props: TabsProps): React.ReactElement;
/** An on/off setting that takes effect immediately. */
export interface SwitchProps { checked?: boolean; label?: string; onChange?: (on) => void }
export declare function Switch(props: SwitchProps): React.ReactElement;
/** Picks items from a list (which tasks to launch, which files to commit). */
export interface CheckboxProps { checked?: boolean; label?: string; onChange?: (on) => void }
export declare function Checkbox(props: CheckboxProps): React.ReactElement;
/** A borderless chip that opens a Menu of options; the composer's mode, model and effort pickers. */
export interface SelectProps { icon?: string; label?: string; highlighted?: boolean; open?: boolean; sections?: MenuSection[] }
export declare function Select(props: SelectProps): React.ReactElement;
/** A floating list of actions or options, grouped in sections. */
export interface MenuProps { sections: {title?: string; items: {label, detail?, checked?, shortcut?, danger?}[]}[] }
export declare function Menu(props: MenuProps): React.ReactElement;
/** Adjusts a small number in steps (peak-hour start and end). */
export interface StepperProps { value: number; min?: number; max?: number; suffix?: string; onChange?: (v) => void }
export declare function Stepper(props: StepperProps): React.ReactElement;
/** A single-line input with a label above and an optional hint or error below. */
export interface TextFieldProps { label?: string; placeholder?: string; value?: string; mono?: boolean; hint?: string; error?: string }
export declare function TextField(props: TextFieldProps): React.ReactElement;
/** A multi-line input: commit messages, first request to Claude, skill instructions. */
export interface TextAreaProps { label?: string; placeholder?: string; rows?: number; mono?: boolean; hint?: string }
export declare function TextArea(props: TextAreaProps): React.ReactElement;
/** Where the person writes to Claude: text, image attachments and the mode/model/effort pickers. */
export interface ComposerProps { draft?: string; attachments?: number; mode?: 'ask'|'auto'; model?: string; effort?: string; cost?: string; peak?: string; running?: boolean }
export declare function Composer(props: ComposerProps): React.ReactElement;
/** The window header of a project, task or pinned conversation. */
export interface ProjectHeaderProps { name: string; parent?: string; color?: ProjectColor; branch?: string; tab?: string; changes?: number }
export declare function ProjectHeader(props: ProjectHeaderProps): React.ReactElement;
/** A row in the sidebar: a project, its tasks and pinned conversations, or a section. */
export interface SidebarItemProps { kind: 'project'|'task'|'pinned'|'section'; title: string; color?: ProjectColor; status?: 'working'|'waiting'; shortcut?: string; selected?: boolean; icon?: string }
export declare function SidebarItem(props: SidebarItemProps): React.ReactElement;
/** A project's initial on its colour; the project's identity everywhere. */
export interface MonogramProps { name: string; color?: 'violet'|'teal'|'pumpkin'|'rose'|'sky'|'sage'|'sand'|'slate'; size?: number }
export declare function Monogram(props: MonogramProps): React.ReactElement;
/** A plumage surface that groups related content (Overview panels, skill details). */
export interface CardProps { title?: string; children?: React.ReactNode }
export declare function Card(props: CardProps): React.ReactElement;
/** One selectable line in a list: sessions, files, skills, MCP servers. */
export interface ListRowProps { title: string; subtitle?: string; meta?: string; leading?: React.ReactNode; selected?: boolean }
export declare function ListRow(props: ListRowProps): React.ReactElement;
/** Asks one question before something that cannot be undone, or collects a short form. */
export interface DialogProps { title: string; body?: string; actions: {label, variant}[]; children?: React.ReactNode? }
export declare function Dialog(props: DialogProps): React.ReactElement;
/** A full-width notice above a section: peak hours, information, errors. */
export interface BannerProps { tone?: 'peak'|'info'|'danger'|'quiet'; title: string; body?: string }
export declare function Banner(props: BannerProps): React.ReactElement;
/** What a screen shows before there is anything in it, and how to start. */
export interface EmptyStateProps { title: string; body?: string; hints?: [key, text][]; figure?: React.ReactNode }
export declare function EmptyState(props: EmptyStateProps): React.ReactElement;
/** One or two words of state next to a title. */
export interface BadgeProps { tone?: 'neutral'|'sheen'|'ember'|'success'|'danger'; mono?: boolean; icon?: string; children?: React.ReactNode }
export declare function Badge(props: BadgeProps): React.ReactElement;
/** A dot plus a word for the live state of an agent or server. */
export interface StatusDotProps { status: 'working'|'waiting'|'ok'|'error'|'idle'; label?: string; hideLabel?: boolean }
export declare function StatusDot(props: StatusDotProps): React.ReactElement;
/** A plan limit: how much of a window is used and when it resets. */
export interface MeterProps { label: string; value: number ; foot?: string }
export declare function Meter(props: MeterProps): React.ReactElement;
/** Three pulsing sheen dots for work in progress, with what is happening. */
export interface LoaderProps { label?: string }
export declare function Loader(props: LoaderProps): React.ReactElement;
/** The person's own message, right-aligned in their project's colour. */
export interface MessageBubbleProps { color?: ProjectColor; children?: React.ReactNode }
export declare function MessageBubble(props: MessageBubbleProps): React.ReactElement;
/** One thing Claude did — a command, a read, an edit — collapsed to a line. */
export interface ToolCardProps { tool: string; summary: string; icon?: string; running?: boolean; error?: boolean; progress?: string; diff?: boolean; children?: React.ReactNode? }
export declare function ToolCard(props: ToolCardProps): React.ReactElement;
/** Claude asks before acting; the person allows, allows always, or denies. */
export interface PermissionCardProps { tool: string; summary: string; detail?: string; suggestion?: string }
export declare function PermissionCard(props: PermissionCardProps): React.ReactElement;
/** Marks the end of one of Claude's turns with time and cost. */
export interface TurnDividerProps { error?: boolean; children?: React.ReactNode }
export declare function TurnDivider(props: TurnDividerProps): React.ReactElement;
/** Claude's plan to split work into parallel tasks, launched with one click. */
export interface TaskPlanCardProps { tasks: {title, branch, model?, effort?, brief}[]; tokens?: string }
export declare function TaskPlanCard(props: TaskPlanCardProps): React.ReactElement;
/** A readable diff: old and new line numbers, wrapping lines, hunk headers. */
export interface DiffViewProps { lines: string[] (prefixed with ' ', '+' or '-'); hunk?: string; start?: number }
export declare function DiffView(props: DiffViewProps): React.ReactElement;
declare global { interface Window { MacPet: { Button: typeof Button; IconButton: typeof IconButton; SendButton: typeof SendButton; Tabs: typeof Tabs; Switch: typeof Switch; Checkbox: typeof Checkbox; Select: typeof Select; Menu: typeof Menu; Stepper: typeof Stepper; TextField: typeof TextField; TextArea: typeof TextArea; Composer: typeof Composer; ProjectHeader: typeof ProjectHeader; SidebarItem: typeof SidebarItem; Monogram: typeof Monogram; Card: typeof Card; ListRow: typeof ListRow; Dialog: typeof Dialog; Banner: typeof Banner; EmptyState: typeof EmptyState; Badge: typeof Badge; StatusDot: typeof StatusDot; Meter: typeof Meter; Loader: typeof Loader; MessageBubble: typeof MessageBubble; ToolCard: typeof ToolCard; PermissionCard: typeof PermissionCard; TurnDivider: typeof TurnDivider; TaskPlanCard: typeof TaskPlanCard; DiffView: typeof DiffView } } }

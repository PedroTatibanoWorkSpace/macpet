// Horário de pico do Claude: em dias úteis, das 5h às 11h no horário do Pacífico, a janela de 5h do plano é
// consumida mais rápido. Mesma regra do PeakHours.swift do MacPet.
const START = 5, END = 11;

export function peak(now = new Date()): { active: boolean; until?: string } {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: "America/Los_Angeles", weekday: "short", hour: "numeric", minute: "numeric", hour12: false }).formatToParts(now);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  const weekday = get("weekday"), hour = Number(get("hour")) % 24, minute = Number(get("minute"));
  const workday = !["Sat", "Sun"].includes(weekday);
  if (!workday || hour < START || hour >= END) return { active: false };
  const minutesLeft = (END - hour) * 60 - minute;
  const end = new Date(now.getTime() + minutesLeft * 60_000);
  return { active: true, until: end.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" }) };
}

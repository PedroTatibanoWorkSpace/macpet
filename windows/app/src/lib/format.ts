// Formatos em português (os mesmos do MacPet).
export function percent(fraction: number) {
  return `${Math.round(fraction * 100)}%`;
}

export function bytes(value: number) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = value, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1).replace(".", ",")} ${units[i]}`;
}

export function rate(perSecond: number) {
  return `${bytes(perSecond)}/s`;
}

/** "2h46", "18 min", "3 dias" até o momento dado (segundos desde 1970). */
export function until(epochSeconds: number) {
  const minutes = Math.max(0, Math.round((epochSeconds * 1000 - Date.now()) / 60000));
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h${String(minutes % 60).padStart(2, "0")}`;
  const days = Math.round(hours / 24);
  return `${days} dia${days === 1 ? "" : "s"}`;
}

export function usd(value: number) {
  return `US$ ${value.toFixed(2).replace(".", ",")}`;
}

/** "12s", "3 min", "1h05" */
export function duration(seconds: number) {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}`;
}

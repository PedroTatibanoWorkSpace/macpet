// Compila o cawde-relay e o copia para src-tauri/binaries com o sufixo do alvo (o Tauri embute "sidecars" assim).
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const triple = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/host: (\S+)/)[1];
const ext = process.platform === "win32" ? ".exe" : "";
execFileSync("cargo", ["build", "--release", "-p", "cawde-relay"], { cwd: root, stdio: "inherit" });
const target = join(root, "app", "src-tauri", "binaries");
mkdirSync(target, { recursive: true });
copyFileSync(join(root, "target", "release", `cawde-relay${ext}`), join(target, `cawde-relay-${triple}${ext}`));
console.log(`cawde-relay → binaries/cawde-relay-${triple}${ext}`);

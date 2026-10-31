// Gera app/src/design-system/tokens.css a partir do tokens.json do design system (Claude Design).
// Tema escuro (o Cawde usa só ele, como o MacPet) e fontes que já vêm no Windows 11.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const app = join(dirname(fileURLToPath(import.meta.url)), "..", "app", "src", "design-system");
const tokens = JSON.parse(readFileSync(join(app, "source", "project", "tokens.json"), "utf8"));
const lines = ["/* Gerado por windows/tools/tokens-css.mjs a partir de source/project/tokens.json. Não edite. */", ":root {"];
for (const t of tokens.color.tokens) lines.push(`  --${t.name}: ${t.value.dark};`);
for (const group of ["spacing", "radius"]) for (const t of tokens[group].tokens) lines.push(`  --${t.name}: ${t.value};`);
for (const t of tokens.shadow.tokens) lines.push(`  --${t.name}: ${t.value.dark};`);
lines.push(`  --font-display: Georgia, "Cambria", ${tokens.type.families.display};`);
lines.push(`  --font-sans: "Segoe UI Variable Text", "Segoe UI", ${tokens.type.families.sans};`);
lines.push(`  --font-mono: "Cascadia Mono", Consolas, ${tokens.type.families.mono};`);
lines.push("  color-scheme: dark;", "}", "");
writeFileSync(join(app, "tokens.css"), lines.join("\n"));
console.log(`tokens.css: ${tokens.color.tokens.length} cores`);

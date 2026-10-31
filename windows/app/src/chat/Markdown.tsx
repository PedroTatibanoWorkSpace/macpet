// Markdown das respostas do Claude, sem biblioteca: títulos, listas, tabelas, código, citações, negrito, itálico,
// código em linha e links (abertos no navegador). O mesmo conjunto do MarkdownText.swift do MacPet.
import { Fragment, type ReactNode } from "react";
import { api } from "../lib/api";

type Block =
  | { type: "paragraph"; text: string }
  | { type: "heading"; text: string; level: number }
  | { type: "code"; text: string; language: string }
  | { type: "list"; items: string[]; ordered: boolean }
  | { type: "table"; header: string[]; rows: string[][] }
  | { type: "quote"; text: string }
  | { type: "rule" };

const cells = (line: string) => line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());

export function parse(text: string): Block[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  let paragraph: string[] = [];
  const flush = () => {
    if (paragraph.length) blocks.push({ type: "paragraph", text: paragraph.join("\n") });
    paragraph = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(/^\s*```(\S*)/);
    if (fence) {
      flush();
      const code: string[] = [];
      for (i++; i < lines.length && !/^\s*```/.test(lines[i]); i++) code.push(lines[i]);
      blocks.push({ type: "code", text: code.join("\n"), language: fence[1] });
      continue;
    }
    const heading = line.match(/^(#{1,4})\s+(.*)/);
    if (heading) { flush(); blocks.push({ type: "heading", text: heading[2], level: heading[1].length }); continue; }
    if (/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line)) { flush(); blocks.push({ type: "rule" }); continue; }
    if (line.trim().startsWith("|") && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      flush();
      const header = cells(line);
      const rows: string[][] = [];
      for (i += 2; i < lines.length && lines[i].trim().startsWith("|"); i++) rows.push(cells(lines[i]));
      i--;
      blocks.push({ type: "table", header, rows });
      continue;
    }
    const item = line.match(/^\s*([-*•]|\d+[.)])\s+(.*)/);
    if (item) {
      flush();
      const ordered = /\d/.test(item[1]);
      const items = [item[2]];
      for (; i + 1 < lines.length; i++) {
        const next = lines[i + 1].match(/^\s*([-*•]|\d+[.)])\s+(.*)/);
        if (next) items.push(next[2]);
        else if (/^\s{2,}\S/.test(lines[i + 1]) && items.length) items[items.length - 1] += " " + lines[i + 1].trim();
        else break;
      }
      blocks.push({ type: "list", items, ordered });
      continue;
    }
    if (line.startsWith(">")) { flush(); blocks.push({ type: "quote", text: line.replace(/^>\s?/, "") }); continue; }
    if (!line.trim()) { flush(); continue; }
    paragraph.push(line);
  }
  flush();
  return blocks;
}

/** `código`, **negrito**, *itálico* e [link](url). */
function inline(text: string, key = 0): ReactNode[] {
  const out: ReactNode[] = [];
  const pattern = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)\s]+\))|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)/g;
  let last = 0;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text))) {
    if (match.index > last) out.push(text.slice(last, match.index));
    const token = match[0];
    const k = `${key}-${match.index}`;
    if (token.startsWith("`")) out.push(<code key={k} className="md-code">{token.slice(1, -1)}</code>);
    else if (token.startsWith("**")) out.push(<strong key={k}>{inline(token.slice(2, -2), key + 1)}</strong>);
    else if (token.startsWith("[")) {
      const [, label, url] = token.match(/\[([^\]]+)\]\(([^)]+)\)/) ?? [];
      out.push(<a key={k} href={url} onClick={(e) => { e.preventDefault(); api.openUrl(url); }}>{label}</a>);
    } else out.push(<em key={k}>{token.slice(1, -1)}</em>);
    last = match.index + token.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function withBreaks(text: string) {
  return text.split("\n").map((line, i) => <Fragment key={i}>{i > 0 && <br />}{inline(line, i)}</Fragment>);
}

export function Markdown({ text }: { text: string }) {
  return (
    <div className="md">
      {parse(text).map((block, i) => {
        switch (block.type) {
          case "paragraph": return <p key={i}>{withBreaks(block.text)}</p>;
          case "heading": return <div key={i} className={`md-h md-h${block.level}`}>{inline(block.text)}</div>;
          case "code": return <pre key={i} className="mp-code md-pre" data-language={block.language || undefined}>{block.text}</pre>;
          case "quote": return <blockquote key={i}>{inline(block.text)}</blockquote>;
          case "rule": return <hr key={i} />;
          case "list": {
            const Tag = block.ordered ? "ol" : "ul";
            return <Tag key={i}>{block.items.map((item, j) => <li key={j}>{inline(item, j)}</li>)}</Tag>;
          }
          case "table": return (
            <div key={i} className="md-table">
              <table>
                <thead><tr>{block.header.map((c, j) => <th key={j}>{inline(c, j)}</th>)}</tr></thead>
                <tbody>{block.rows.map((row, r) => <tr key={r}>{row.map((c, j) => <td key={j}>{inline(c, j)}</td>)}</tr>)}</tbody>
              </table>
            </div>
          );
        }
      })}
    </div>
  );
}

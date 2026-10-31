# Continuando o Cawde (versão Windows 11)

O Cawde é a versão Windows do MacPet (o app de Mac na raiz deste repositório): um corvo na área de notificação que acompanha o Claude Code, com um painel de projetos onde você conversa com o Claude em cada pasta. A ideia é ter as mesmas funcionalidades do MacPet, o mesmo design e ser **leve** (bem mais que o VS Code).

O plano completo, a arquitetura e o mapa "recurso do Mac → equivalente no Windows" estão em [PLANO.md](PLANO.md). Este arquivo é o atalho para começar.

## Onde está

| Fase | Situação |
|---|---|
| 0. Base: relay, app Tauri, build no Windows | pronta |
| 1. Corvo na área de notificação, popover com limites e métricas | pronta |
| 2a. Painel de projetos e chat completo com o Claude | pronta, testada de ponta a ponta com o Claude de verdade (no Mac) |
| 2b. Hooks, sessões, notificações, imagens, @arquivos, /comandos, conversas fixadas | **a fazer** |
| 3. Alterações (git), commits com IA, revisão de PR, tarefas paralelas, terminal, servidores | **a fazer** |
| 4. Corvo na tela, balão de fala, guarda-roupa, foco, tela ligada, modo limpeza | **a fazer** |
| 5. Release no GitHub com atualização automática | **a fazer** |

O chat ainda não foi usado num Windows com o Claude Code logado: o CI não tem login. Testar isso é o primeiro passo recomendado.

## Rodar no Windows 11

Precisa de: [Rust](https://rustup.rs) (stable, MSVC), Node 22+, pnpm 10 (`npm i -g pnpm`), as ferramentas de build do Visual Studio (C++) e o [Claude Code](https://code.claude.com) instalado e com login (`claude` no terminal). O WebView2 já vem no Windows 11.

```powershell
cd windows\app
pnpm install
pnpm tauri dev          # compila o relay, abre o Cawde com recarga automática
```

O Cawde abre só como ícone perto do relógio. Clique nele para o popover; "Abrir o painel" para os projetos e o chat.

Instalador: `pnpm tauri build` gera `windows\target\release\bundle\nsis\Cawde_*_x64-setup.exe`. O workflow **Windows** do GitHub Actions faz o mesmo a cada push na branch `windows` (artefato `cawde-windows-instalador`). Sem assinatura de código, o SmartScreen avisa na instalação: "Mais informações" › "Executar assim mesmo".

O Tauri roda no Mac também (`pnpm tauri dev`), útil para mexer na interface; o que é específico do Windows está atrás de `#[cfg(windows)]`.

## Como está organizado

```
windows/
  app/src-tauri/src/     núcleo em Rust
    lib.rs               ícone, janelas (popover e painel), comandos chamados pela interface
    chat/session.rs      uma conversa: protocolo stream-json do Claude, permissões, parar, reconectar
    chat/model.rs        itens da conversa, resumo dos cards de ferramenta, leitura do histórico
    chat/mod.rs          todas as conversas; manda para a interface só o que mudou (evento "chat")
    projects.rs          projetos (projects.json na pasta de dados do app)
    limits.rs            limites do plano (/usage e rate_limit_event)
    metrics.rs, pet.rs   métricas do computador; o corvo do ícone
    proc.rs, claude.rs   processos (lançar destacado, pid vivo, encerrar); achar e rodar o claude
  app/src/               interface em React + TypeScript
    design-system/       componentes do design system "MacPet" (Claude Design) em TSX e o CSS
    panel/, chat/        painel, conversa, composer, Markdown
    popover/, pet/       popover do ícone; o corvo animado
  relay/                 cawde-relay: segura o claude fora do app (ver abaixo)
  shared/pet-art.json    arte do corvo, exportada do PetArt.swift do MacPet
  tools/                 exportadores (arte, tokens, ícone) e measure.ps1 (leveza no CI)
```

**Por que o relay.** No Mac a conversa sobrevive ao app fechar com FIFO + `setsid`; no Windows não há FIFO. Cada conversa tem um `cawde-relay.exe` lançado destacado que segura o `claude` e fala com o app só por arquivos em `%APPDATA%\app.cawde\chats\<projeto>\`: `input.jsonl` (o app acrescenta mensagens), `out.jsonl` (o que o Claude responde), `meta.json` e `exit.json`.

**Onde mora o estado.** As conversas vivem no núcleo em Rust e no relay, não na interface. Fechar o painel destrói a WebView; ao reabrir, a conversa aparece inteira (`open_chat` devolve tudo, depois o evento `chat` manda só as mudanças).

## Regras de leveza (não quebre)

O CI abre o Cawde num Windows de verdade e mede (`tools/measure.ps1`); **o build falha** se, parado, passar de 60 MB de memória privada ou 1% de CPU, ou se o popover/painel não abrir. Hoje: 2,7 MB e 0,08% parado; ~110 MB com o painel aberto; volta a ~10 MB ao fechar.

- Nenhuma WebView na abertura: só o ícone (desenhado em Rust).
- Janelas são criadas ao abrir e **destruídas** ao fechar (não escondidas).
- Nada fica fazendo polling sem ninguém olhando (métricas só com o popover aberto).
- Animações no ritmo necessário (o ícone não reenvia quadro igual).
- Sem bibliotecas grandes no front (o Markdown é próprio, ~150 linhas).
- Todas as janelas usam o mesmo `WEBVIEW_ARGS` (WebView2 sem GPU e sem serviços em segundo plano).

## Armadilhas que já custaram tempo

- **Criar janela trava se for na thread principal.** Clique no ícone, menu e segunda instância rodam na thread principal; criar uma WebView ali trava o app (o WebView2 precisa dela livre). Use `open_window_async` em `lib.rs`.
- **Console piscando.** Todo processo lançado (claude, git…) precisa de `claude::hide_console` (`CREATE_NO_WINDOW`), senão abre uma janela preta.
- **`findstr` não serve de eco** para testes: não aceita linhas longas. O relay tem um modo `--echo` só para isso.
- **`source/project/components/index.d.ts`** (exportado do Claude Design) é documentação, não TypeScript válido: fica fora do `tsconfig`.
- **Instância única:** rodar `cawde.exe --popover`, `--panel`, `--demo` com o app aberto repassa o argumento para ele (é como o CI abre as janelas). `--demo` cria um projeto com uma conversa de exemplo.
- **Mensagens grandes** (prompts longos, imagens) já passam pelo relay em linhas inteiras; não volte a escrever direto no stdin do claude com escrita bloqueante (foi o que travava o MacPet).
- **Permissão em teste:** o Claude Code libera `echo` sem perguntar; para testar o pedido de permissão use criar arquivo (Write).

## Testes

```powershell
cd windows
cargo test                      # núcleo e relay
cargo build --release -p cawde-relay
cargo test -p cawde -- --ignored --nocapture   # de ponta a ponta com o Claude de verdade (Haiku, menos de 1 centavo)
```

## O que falta, e de onde portar

O MacPet (Swift, em `Sources/MacPet/`) é a referência de comportamento; a lógica foi portada quase linha a linha até aqui.

| Fase | Funcionalidade | No MacPet |
|---|---|---|
| 2b | Hooks: sessões do Claude abertas fora do Cawde (terminal, VS Code) | `Claude/HookInstaller.swift`, `ClaudeEventServer.swift`, `Sources/macpet-hook/` (no Windows: named pipe em vez de Unix socket) |
| 2b | Índice de uso (custo/tokens por dia e projeto) e aba de sessões | `Claude/UsageIndex.swift`, `Views/Dashboard/SessionsView.swift` |
| 2b | Notificações (terminou, precisa de você) com som por projeto | `Alerts/Notifier.swift` |
| 2b | Colar imagem, @arquivo, /comando, conversa fixada | `Workspace/ChatAttachments.swift`, `ProjectStore.swift` (pins) |
| 3 | Alterações: diff, preparar, commit com mensagem da IA, separar commits, branch, PR | `Workspace/GitRepo.swift`, `CommitAssistant.swift`, `Views/Workspace/ChangesView.swift` |
| 3 | Revisão do PR | `Workspace/BranchReview.swift`, `Views/Workspace/BranchReviewView.swift` |
| 3 | Tarefas paralelas (worktrees) lançadas pelo chat | `Workspace/Worktrees.swift`, `TaskPlan.swift`, `Views/Workspace/TaskPlanCard.swift` (no Windows: junction em vez de symlink no `node_modules`) |
| 3 | Terminal e servidores (portas, caiu, reiniciar) | `Workspace/TerminalGroup.swift`, `ServerMonitor.swift` (no Windows: ConPTY via `portable-pty` + xterm.js; portas via `GetExtendedTcpTable`) |
| 3 | Agentes e workflows de uma conversa | `Workspace/AgentScanner.swift`, `Views/Workspace/AgentsView.swift` |
| 4 | Corvo na tela, balão de fala, guarda-roupa | `Pet/DesktopPet.swift`, `SpeechBubble.swift`, `PetArt.swift` (roupas), `Views/CrowSettings.swift` |
| 4 | Modo foco, tela ligada, modo limpeza | `Monitors/FocusTimer.swift`, `KeepAwake.swift` (`SetThreadExecutionState`), `Cleaning/CleaningMode.swift` (hook de teclado de baixo nível) |
| 5 | Release com atualização automática | `.github/workflows/release.yml` do MacPet como base; plugin updater do Tauri |

Fica de fora no Windows: temperatura (sem API pública) e ir para uma aba específica do terminal (o Windows Terminal só permite focar a janela).

## Convenções

- Textos da interface em português, no tom do MacPet: direto, sem jargão, dizendo o que acontece.
- Comentários no código em português, explicando o porquê.
- Commits em inglês, no estilo dos que já estão na branch.
- A arte do corvo tem uma fonte só: mudou o `PetArt.swift`, rode `tools/export-pet-art.sh` (precisa de Mac) para atualizar `shared/pet-art.json`.

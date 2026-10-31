# Cawde para Windows 11

**Cawde** = *caw* (o grasnado do corvo) + Claude. A versão Windows do MacPet: o mesmo corvo, o mesmo design e o mesmo hub de projetos com o Claude Code. Uso direto no Windows (não WSL), Windows 11, instalado pelo GitHub (sem assinatura de código).

Vai continuar o desenvolvimento? Comece por [CONTINUAR.md](CONTINUAR.md).

## Arquitetura

| Camada | Tecnologia | Por quê |
|---|---|---|
| App | Tauri 2 (Rust + WebView2) | Leve (bem menos que o VS Code, que é Electron) e roda o design system, que já é React |
| Interface | React + TypeScript (`app/src`) | Os 30 componentes, CSS e tokens do design system "MacPet" no Claude Design |
| Núcleo | Rust (`app/src-tauri`) | Claude, git, métricas, corvo, foco, servidores |
| Conversas | `cawde-relay` (`relay/`) | Segura o `claude` fora do app (ver abaixo) |
| Hooks | `cawde-hook` (a fazer) | Recebe os eventos do Claude Code e avisa o app por named pipe |

### Conversas que sobrevivem ao app fechar

No Mac isso é FIFO + `setsid`. No Windows não há FIFO, então cada conversa tem um **relay**: um executável pequeno (≈350 KB), lançado destacado, que segura o `claude` e fala com o app só por arquivos na pasta da conversa:

- `input.jsonl`: o app acrescenta mensagens; o relay entrega cada linha completa ao claude.
- `out.jsonl`: tudo o que o claude responde.
- `meta.json` / `exit.json`: pids e código de saída.

**Validado** (no Mac, com o Claude de verdade): o app fecha e o Claude responde mesmo assim; uma mensagem de 2 MB passa inteira; a conversa mantém a memória; ao terminar, o relay grava o código e sai. O teste `relay/tests/relay.rs` roda no CI também no Windows.

## O que muda do Mac para o Windows

| No Mac | No Windows | Situação |
|---|---|---|
| Barra de menu com métricas em texto | Ícone na área de notificação (números desenhados no ícone) | viável |
| Popover do corvo | Janela que abre colada ao ícone, perto do relógio | viável |
| Temperatura | Sem API pública no Windows | **fica de fora** |
| CPU, memória, disco, rede, processos | `sysinfo` | viável |
| Portas dos servidores | `GetExtendedTcpTable` | viável |
| Tela ligada | `SetThreadExecutionState` | viável |
| Notificações | Notificações do Windows (app instalado pelo instalador) | viável |
| Hooks via Unix socket | `cawde-hook.exe` + named pipe | viável |
| Terminal (SwiftTerm) | ConPTY (`portable-pty`) + xterm.js | viável |
| Corvo na tela | Janela transparente que deixa o clique passar, janelas via `EnumWindows` | viável; desempenho a medir |
| Modo limpeza | Hook de teclado de baixo nível (não pede permissão) | viável; Ctrl+Alt+Del e Win+L não são bloqueáveis |
| Liquid Glass | Mica (Windows 11) | viável |
| Serifa New York, SF Pro, SF Mono | Georgia, Segoe UI Variable e Cascadia Mono, que já vêm no Windows 11 (nada embutido) | feito |
| Ir para a aba do iTerm | Windows Terminal não foca aba específica | só a janela |
| Symlink do `node_modules` nas tarefas | Junction (`mklink /J`) | viável |
| Assinatura | Sem certificado: o SmartScreen avisa na instalação ("Mais informações › Executar assim mesmo") | aceito |

## Leveza (medida no Windows, a cada build)

O CI abre o Cawde num Windows de verdade e mede (`tools/measure.ps1`); o build falha se, parado, passar de 60 MB ou 1% de CPU.

| Momento | Memória privada | Processos |
|---|---|---|
| Só o ícone | 2,5 MB (13,5 MB de working set) | 1 |
| Popover aberto | 102 MB | 7 (o Cawde + o WebView2) |
| Popover fechado | 9,9 MB | 1 (o WebView2 encerra) |
| Painel aberto (conversa de exemplo) | 114 MB | 7 |
| Painel fechado | 10,5 MB | 1 |

CPU parado: 0,08% de um núcleo. Regras: nenhuma WebView na abertura; janelas criadas ao abrir e destruídas ao fechar; métricas só com o popover aberto; animação no ritmo do humor, sem reenviar quadro igual; WebView2 sem GPU nem serviços em segundo plano.

## Fases

0. **Base** ✅ relay validado, app Tauri, workspace Rust, CI no Windows gerando o instalador.
1. **Corvo na área de notificação** ✅ design system em TSX (tokens gerados, fontes do Windows), arte do corvo exportada do `PetArt.swift`, ícone animado (parado, cansado, dormindo), popover com limites do plano e saúde do computador.
2. **Núcleo do Claude.**
   - **2a ✅ Painel e chat:** projetos (seletor de pasta do Windows), chat completo pelo relay (texto ao vivo, cards de ferramenta, permissões, modo/modelo/esforço/MCP, parar, enviar com o Claude trabalhando, agentes em segundo plano, reconectar ao abrir, histórico, custo), limites a cada resposta, horário de pico, corvo do ícone acompanhando as conversas. Testado de ponta a ponta com o Claude de verdade.
   - 2b: hooks para sessões fora do Cawde (terminal, VS Code), índice de uso e aba de sessões, notificações do Windows, imagens coladas, @arquivos e comandos /, conversas fixadas.
3. Hub de projetos: alterações, commits com IA, revisão de PR, tarefas paralelas (worktrees), terminal, servidores.
4. Corvo na tela, balão de fala, guarda-roupa, foco, tela ligada, modo limpeza.
5. Instalador e atualização automática pelo GitHub Releases.

## Desenvolvimento

```sh
cd windows/app
pnpm install
pnpm tauri dev      # roda no Mac também (a interface e o núcleo são os mesmos)
```

O instalador do Windows sai do workflow **Windows** do GitHub Actions (artefato `cawde-windows-instalador`).

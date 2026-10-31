# MacPet

Monitor de sistema na barra de menu do macOS, com um pet que acompanha suas sessões do Claude Code.

- **Barra de menu**: temperatura, rede ↑↓, pressão térmica, disco, memória e CPU, no estilo do Stats.
- **Painéis**: gráfico da última hora, 24h e 7 dias, e os processos que mais consomem, com opção de encerrar.
- **Alertas**: regras como "temperatura acima de 90°C por 1 min". O item fica vermelho e chega uma notificação.
- **Pet (corvo de Halloween)**: bica o laptop enquanto o Claude trabalha, bate a asa quando uma sessão está esperando você, comemora quando termina, fica tonto quando o Mac esquenta, cansado perto do limite do plano e dorme quando não tem nada acontecendo. Clicar numa sessão ou na notificação leva direto à aba do iTerm.
- **Dashboard do Claude Code** (`macpet://claude`): limites oficiais do plano (5h e semana), custo e tokens por dia, projeto e modelo, histórico de sessões com busca em todos os prompts e arquivos alterados, retomar sessão no terminal, biblioteca de prompts e configuração (CLAUDE.md, permissões, plugins, MCPs, skills, hooks).
- **Projetos** (o hub que substitui as janelas do VS Code): para cada projeto, um **chat nativo com o Claude Code** (texto em tempo real, cards de ferramenta com diff, botões de permissão, modo e modelo, retomar conversas), uma aba de **Alterações** (diff colorido, preparar/descartar, commit com mensagem escrita pelo Claude no padrão do repo, revisão antes do commit, separar em commits lógicos, branch, push e PR) e uma aba de **Terminal** com os comandos do projeto (`yarn start:dev`, testes…) que continuam rodando ao trocar de projeto. ⌘1…⌘9 trocam de projeto.
- **Revisão do PR**: o Claude revisa tudo o que entra no PR lendo o código em volta, e cada achado tem "Corrigir no chat".
- **Servidores**: os terminais mostram as portas abertas, avisam quando um servidor cai e podem reiniciá-lo sozinho.
- **Corvo na tela**: anda pelo chão e por cima das janelas, dá para arrastar, fazer carinho e trocar a roupa. Comemora e conta num balão o que o Claude terminou.
- **Modo foco**: pomodoro com o corvo. Ele cochila e guarda as notificações que podem esperar até a pausa.
- **Tela ligada**: impede a tela de apagar, na hora ou em horários programados.
- **Modo limpeza** (✨): apaga a tela e desliga o teclado para limpar o Mac.

Leve: cerca de 40 MB de RAM e menos de 1% de CPU.

## Instalação

O guia completo, com requisitos, primeira abertura, atualização, desinstalação e problemas comuns, está em **[docs/INSTALACAO.md](docs/INSTALACAO.md)**. Em resumo:

```sh
git clone https://github.com/PedroTatibanoWorkSpace/macpet.git
cd macpet
./scripts/setup-signing.sh   # uma vez: as permissões do macOS sobrevivem às atualizações
make install                 # compila, instala em /Applications e abre
```

Depois de abrir, clique no corvo da barra e em **Instalar hooks** para conectar ao Claude Code. Isso adiciona hooks em `~/.claude/settings.json` e faz backup do arquivo antes.

Quando houver uma release publicada, também dá para instalar pelo Homebrew:

```sh
brew tap PedroTatibanoWorkSpace/macpet https://github.com/PedroTatibanoWorkSpace/macpet
brew install --cask PedroTatibanoWorkSpace/macpet/macpet
```

## Desenvolvimento

Requer só as Command Line Tools do Xcode (Swift 6).

```sh
make run       # compila dist/MacPet.app e abre
make install   # instala em /Applications
```

Simular um evento do Claude Code:

```sh
echo '{"hook_event_name":"Stop","session_id":"x","cwd":"'$PWD'"}' | ~/.macpet/bin/macpet-hook
```

## Release

Para publicar uma versão, crie uma tag `vX.Y.Z` e faça push. O GitHub Actions compila o app universal (arm64 + x86_64), publica a Release e atualiza `Casks/macpet.rb`.

## Como funciona

| Parte | Fonte |
|---|---|
| CPU / memória | `host_statistics` (mesmo cálculo do Monitor de Atividade) |
| Temperatura | sensores `PMU tdie*` via IOHIDEventSystem (API privada) |
| Rede | contadores da interface principal (`getifaddrs`) |
| Histórico | SQLite em `~/Library/Application Support/MacPet` |
| Claude Code (eventos) | hooks → `macpet-hook` → Unix socket `~/.macpet/macpet.sock` |
| Limites do plano | statusLine → `macpet-hook statusline` (campo `rate_limits`) |
| Uso e histórico | índice incremental dos transcripts `~/.claude/projects/**/*.jsonl` em SQLite |
| Chat dos projetos | `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio` |
| IA do git | `claude -p` enxuto (sem ferramentas, hooks nem sessão salva) com Haiku/Sonnet |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |

## Roadmap

1. ~~Monitor, alertas, histórico e pet com notificações do Claude~~
2. ~~Dashboard do Claude: tokens e custo, limites do plano, histórico de conversas, configuração, launcher e prompts salvos~~
3. ~~Hub de projetos: chat nativo, alterações/commits com IA e terminal~~

# Instalando o MacPet no MacBook

Este guia instala o MacPet compilando o código no seu Mac. Leva uns 5 minutos, a maior parte esperando a primeira compilação.

> Só quer usar? Instale pronto pelo Homebrew (`brew tap PedroTatibanoWorkSpace/macpet https://github.com/PedroTatibanoWorkSpace/macpet && brew install --cask PedroTatibanoWorkSpace/macpet/macpet`) ou baixe o `.zip` em [Releases](https://github.com/PedroTatibanoWorkSpace/macpet/releases). Pelo `.zip`, na primeira abertura vá em Ajustes › Privacidade e Segurança › **Abrir mesmo assim** (o app não é assinado por conta paga da Apple).

## O que você precisa

| | Para quê | Como conferir |
|---|---|---|
| **macOS 14 (Sonoma) ou mais novo** | Rodar o app. Apple Silicon ou Intel. | Menu  › Sobre este Mac |
| **Command Line Tools do Xcode 26** (Swift 6.2) | Compilar. O Xcode completo não é necessário. Exige macOS 15.6 ou mais novo. | `swift --version` mostra 6.2 ou mais |
| **Git** | Baixar o código. Vem com as Command Line Tools. | `git --version` |
| **Claude Code** (opcional) | Chat dos projetos, dashboard, revisão de PR e o corvo reagindo ao Claude. Sem ele, o MacPet funciona só como monitor do sistema. | `claude --version` |
| **GitHub CLI** (opcional) | Abrir Pull Requests pelo MacPet. | `gh auth status` |

Se faltar alguma coisa:

```sh
# Command Line Tools do Xcode (abre uma janela de instalação)
xcode-select --install

# Claude Code (instalador oficial); depois rode `claude` uma vez para fazer login
curl -fsSL https://claude.ai/install.sh | bash

# GitHub CLI (precisa do Homebrew: https://brew.sh)
brew install gh && gh auth login
```

## 1. Baixar o código

```sh
git clone https://github.com/PedroTatibanoWorkSpace/macpet.git
cd macpet
```

## 2. Criar a assinatura local (recomendado, uma vez só)

```sh
./scripts/setup-signing.sh
```

Isso cria um certificado chamado **MacPet Local Signing** no seu Keychain de login, usado só para assinar o MacPet no seu Mac.

**Por que fazer:** sem ele o app é assinado de forma provisória, e o macOS trata cada nova compilação como um app diferente. Ele esquece as permissões que você deu (como a de Acessibilidade, usada pelo modo limpeza) toda vez que você atualizar. Com o certificado, as permissões ficam.

Na primeira compilação depois disso, o macOS pode perguntar se o `codesign` pode usar a chave. Clique em **Sempre permitir**.

## 3. Compilar e instalar

```sh
make install
```

Esse comando compila o app (a primeira vez demora alguns minutos), copia para `/Applications/MacPet.app` e abre.

O MacPet vive na barra de menu: não aparece no Dock enquanto o painel estiver fechado. Procure o corvo de chapéu perto do relógio.

> Mac com notch: os itens mais à esquerda da barra de menu ficam escondidos atrás da câmera. Se o corvo não aparecer, segure ⌘ e arraste outros ícones da barra para abrir espaço, ou desligue métricas em Preferências › Geral.

## 4. Primeira abertura

1. **Notificações:** o macOS pergunta se o MacPet pode enviar notificações. Permita, porque é por elas que o corvo avisa quando o Claude termina ou precisa de você.
2. **Conectar ao Claude Code:** clique no corvo da barra e em **Instalar hooks**.
   - Isso adiciona hooks em `~/.claude/settings.json` e guarda um backup em `settings.json.macpet-backup`.
   - Sessões do Claude que já estavam abertas só aparecem depois de reiniciadas.
3. **Projetos:** clique em **Abrir dashboard do Claude** e, na barra lateral, em **Adicionar projeto**, escolhendo a pasta de cada um. Cada um ganha chat com o Claude, alterações do git e terminais.
4. **Abrir ao iniciar o Mac:** Preferências › Geral › **Abrir ao iniciar o Mac**.
5. **Modo limpeza** (opcional): para desligar o teclado, o MacPet precisa da permissão de **Acessibilidade**. Ele pede na hora em que você usar o modo pela primeira vez. Ligue o MacPet em Ajustes › Privacidade e Segurança › Acessibilidade.

## Atualizar

```sh
cd macpet
git pull
make install
```

Conversas com o Claude que estavam rodando continuam ao reabrir. Agentes em segundo plano também não são interrompidos.

## Desinstalar

1. Clique no corvo › Preferências › Claude › **Remover hooks**. Isso tira do `~/.claude/settings.json` só o que o MacPet adicionou.
2. Feche o MacPet (clique no corvo › Sair do MacPet) e apague os arquivos:

```sh
rm -rf /Applications/MacPet.app ~/.macpet ~/Library/Application\ Support/MacPet
defaults delete app.macpet
```

3. Se você criou a assinatura local, apague o certificado **MacPet Local Signing** no app Acesso às Chaves.

## Problemas comuns

**O modo limpeza continua pedindo permissão de Acessibilidade, mesmo já ligado.**
A permissão é de uma compilação antiga. Faça o passo 2 (assinatura local) e rode `make install` de novo. Depois, em Ajustes › Privacidade e Segurança › Acessibilidade, selecione o MacPet, remova com **–** e conceda de novo.

**"Não encontrei o comando `claude` no seu PATH."**
Instale o Claude Code (veja "O que você precisa") e reabra o MacPet. Ele procura o `claude` no seu PATH, em `~/.local/bin` e na extensão do VS Code, e usa a versão mais nova que achar.

**Um modelo novo (por exemplo, Opus) não aparece no seletor do chat.**
O seu Claude Code está desatualizado. Atualize com `claude update` e reabra o MacPet.

**A temperatura aparece vazia.**
A leitura usa os sensores dos chips Apple Silicon. Em Macs Intel o item de temperatura fica sem valor.

**O corvo não aparece na barra de menu.**
Veja a nota sobre o notch no passo 3. Se ainda assim não aparecer, confira em Preferências › Geral se **Mostrar o pet na barra** está ligado.

## Para quem vai mexer no código

```sh
make run      # compila dist/MacPet.app e abre, sem instalar
make build    # só compila (swift build)
make clean    # apaga .build e dist
```

Simular um evento do Claude Code, sem precisar de uma sessão de verdade:

```sh
echo '{"hook_event_name":"Stop","session_id":"x","cwd":"'$PWD'"}' | ~/.macpet/bin/macpet-hook
```

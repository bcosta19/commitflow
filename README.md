# commitflow

Animação no terminal de um ano de commits (GitHub + GitLab): um heatmap estilo GitHub é revelado dia a dia, com um gráfico de barras do volume semanal crescendo embaixo, contador acumulado e um resumo no final (dias ativos, maior sequência, dia mais intenso).

Zig 0.17, sem dependências. Só Linux (tamanho do terminal via `ioctl`).

## Uso

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/commitflow                       # fontes do arquivo de config
./zig-out/bin/commitflow --github @me --gitlab gitlab.example.org/usuario
./zig-out/bin/commitflow --static              # só o último frame (também se stdout não for TTY)
```

Opções: `--end YYYY-MM-DD`, `--duration SEGUNDOS` (6), `--fps N` (30), `--no-color`, `--config CAMINHO`, `--refresh`, `--no-cache`. `NO_COLOR` é respeitado. Ctrl-C restaura o cursor.

### Fontes

Autenticação fica por conta dos CLIs `gh` e `glab` já logados; o commitflow não toca em tokens.

- `--github USER` — `@me` é o usuário autenticado.
- `--gitlab SPEC` — `USER` (gitlab.com), `HOST/USER` ou `HOST/` (usuário autenticado em HOST). Repetível.

Sem flags, lê `$XDG_CONFIG_HOME/commitflow/config` (ou `~/.config/commitflow/config`); sem arquivo, usa `--github @me`.

```
# ~/.config/commitflow/config
github = @me
gitlab = gitlab.example.org/alice
```

Uma fonte que falha (ex.: GitLab interno sem VPN, timeout de 25 s) vira aviso e as demais continuam.

### Cache

Cada conta (GitHub ou GitLab) tem um arquivo binário em `$XDG_CACHE_HOME/commitflow/` (padrão `~/.cache/commitflow/`), com as contagens por dia (36 bytes de cabeçalho + 4 bytes por dia, ~1,5 KB). A cada execução o programa faz **uma** chamada barata e compara o resultado com o que está no cache:

| Fonte | Chamada | Compara | Com cache | Sem cache |
|---|---|---|---|---|
| GitLab | `users/:id/events?per_page=1` | id do push mais recente | ~0,2 s | ~15-20 s |
| GitHub | GraphQL `totalContributions` dos últimos 365 dias | total de contribuições | ~0,6 s | ~1,9 s |

Se for igual, usa o cache. Se mudou, refaz a busca completa e regrava o arquivo. A busca completa também ocorre com cache com mais de 7 dias, que não cobre a janela, corrompido, de outra conta (o login do GitHub é guardado como hash; no GitLab `@me` confere o id) ou com `--refresh`. `--no-cache` desliga leitura e escrita.

Limites:

- GitLab: rebase, force-push ou branch apagada não geram push novo; o TTL de 7 dias (ou `--refresh`) corrige isso. Um scan em que algum projeto falhou não é gravado.
- GitHub: o total só cobre os últimos 365 dias; uma mudança nos primeiros ~6 dias da janela de 371 só aparece pelo TTL. Dois ajustes que se compensam exatamente no total também passam despercebidos.
- GitHub: a busca completa agora faz a sonda mais as duas chamadas de calendário, então um cache vazio custa um pouco mais que antes.

### O que é contado

- **GitHub**: calendário de contribuições (GraphQL `contributionCalendar`). O GitHub não expõe série diária só de commits, então PRs, issues e reviews entram na conta.
- **GitLab**: só commits. Os eventos de push descobrem os projetos; depois cada projeto é listado e contam os commits do usuário (por e-mail verificado ou nome de autor), por `authored_date`, sem merges e sem repetir SHA. `push_data.commit_count` não serve: um push de "created branch" traz o histórico inteiro da branch (centenas de commits).
- A janela são 53 semanas terminando hoje (data local), alinhada ao domingo.

## Desenvolvimento

```sh
zig build test
```

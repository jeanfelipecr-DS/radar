# Radar

Painel pessoal que acompanha vagas de **freela de dados** em plataformas internacionais e as candidaturas feitas a elas, pra quem trabalha em horário comercial e quer renda extra à noite e no fim de semana.

## Por que existe

As boas vagas de dados para freelancer ficam espalhadas por várias plataformas, e a maioria dos quadros de vaga remota anuncia emprego fixo de 40h, que não cabe ao lado de um trabalho CLT. O Radar busca as fontes que têm freela de verdade, ordena pelo que eu sei entregar e mostra num painel que abre no celular.

## Como funciona

```
pg_cron no banco (de hora em hora, minuto 17)
  └─ pg_net chama a função `coletar` (Supabase Edge Function, TypeScript)
        └─ busca as 5 fontes (Mercor, Braintrust, Freelancer, Workana, 99Freelas) e grava
             ├─ coleta       uma linha por execução (frescor de cada fonte)
             ├─ vaga_bruta   o JSON como a fonte mandou (versão nova só quando muda)
             ├─ vaga         a vaga organizada
             └─ vaga_aberta  view: "aberta" é calculado, nunca gravado
```

O agendamento mora no banco porque o agendador do GitHub Actions é "best-effort": no repositório novo ele perdeu os primeiros horários sem rodar nenhuma vez. A primeira versão do coletor (Python + GitHub Actions) está no histórico do git.

**Tela:** <https://jeanfelipecr-ds.github.io/radar/>. O Radar é do Jean e de alguns amigos, por convite: o cadastro é fechado. O Jean entra por link no e-mail; os amigos entram com e-mail e senha, criados pela tela Convidar, que só o Jean vê. Cada pessoa vê as vagas abertas que aceitam Brasil, ranqueadas pela nota de **encaixe** (0–100) com o **próprio** perfil, em abas por tempo até o primeiro dinheiro (Dias, Semanas, Meses) mais a aba Mercado, com vagas de tempo integral só para ler o mercado. No computador a lista fica à esquerda e o detalhe à direita; no celular o detalhe abre por cima da lista. O botão **Todas | Português** e o filtro de **Plataformas** ficam salvos no perfil de cada pessoa, e a lista ordena por encaixe, por mais recentes ou por valor (por valor, cada unidade é um grupo: por hora não se compara com pelo projeto). Cada linha mostra a idade da vaga, e em "Todas" o português vem num bloco e o inglês em outro. O valor aparece na moeda da vaga; por trás, tudo vira US$ para ordenar e para o valor mínimo. Desenho em [`docs/SDD_freelas_br_e_layout.md`](docs/SDD_freelas_br_e_layout.md).

**Configurar:** cada pessoa edita as próprias habilidades (peso 1 ou ½), as áreas que esconde, um valor mínimo opcional em US$ e a senha. Perfil novo nasce de um modelo pronto (**Dados** ou **Vídeo**). Desenho e decisões em [`docs/SDD_multiusuario.md`](docs/SDD_multiusuario.md).

A nota de encaixe mora no banco, não no código. `perfil_termo` guarda os termos de cada pessoa com peso, e a view `vaga_radar` soma o peso dobrado quando o termo aparece no título, o peso inteiro na área ou nas habilidades e metade quando ele aparece só na descrição. A view é `security_invoker`: lê o perfil de quem está logado. Mudou a stack? Muda uma linha e o ranking se recalcula na próxima leitura.

A chave que aparece no `index.html` é a pública (papel `anon`). Ela sozinha não lê nada: as regras de acesso (RLS) liberam as vagas só para convidados e cada perfil só para o dono.

**Fontes automáticas** (testadas em 11 e 13/10/2026):

| Fonte | Como lê | Observação |
|---|---|---|
| Mercor | JSON embutido na página pública `/explore` | toda vaga passa por entrevista em vídeo com IA, falada em inglês |
| Braintrust | API pública paginada | a maioria das vagas é restrita a EUA ou a uma lista de países |
| Freelancer.com | API pública (`projects/active`), uma busca por habilidade distinta de todos os perfis | busca por palavra é solta: quem separa o relevante é a nota de cada perfil; metade dos projetos vem em rupia, convertida para US$ com a cotação do próprio projeto |
| Workana | JSON embutido na página pública `/jobs` (`results-initials`), `language=pt`, uma busca por habilidade | só projetos em português; orçamento em texto e em dólar; data relativa ("há 5 dias") |
| 99Freelas | HTML da busca pública `/projects?q=`, uma busca por habilidade | orçamento sempre "Aberto" (quem propõe o preço é o freelancer), então a vaga entra sem valor |

Upwork, Malt, Outlier, Toptal e outras não entregam vagas de forma automática; entram como link e registro manual da candidatura.

## Publicar e rodar

```bash
# publicar a função (precisa do token de conta em SUPABASE_ACCESS_TOKEN)
curl -X POST -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"   "https://api.supabase.com/v1/projects/<ref>/functions/deploy?slug=coletar"   -F 'metadata={"entrypoint_path":"index.ts","name":"coletar","verify_jwt":false};type=application/json'   -F "file=@supabase/functions/coletar/index.ts;filename=index.ts"

# rodar na mão
curl -X POST "https://<ref>.supabase.co/functions/v1/coletar" -H "x-radar-segredo: $RADAR_SEGREDO"
```

A função não exige JWT: ela confere o cabeçalho `x-radar-segredo`, cujo valor fica nos segredos da função (`RADAR_SEGREDO`) e no cofre do banco (`radar_segredo`, lido pelo `pg_cron`).

## Armadilhas

- **A Mercor não tem API.** Se a página mudar de formato, a coleta falha com erro explícito e a tela mostra a fonte como atrasada. As vagas da última coleta boa continuam visíveis.
- **Horas significam coisas diferentes em cada fonte.** Na Mercor o número é o teto (paga por hora; vaga "full-time" vai para o bloco de mercado). Na Braintrust são as horas esperadas, e 30h ou mais vai para o bloco de mercado.
- **A Braintrust devolve `job_skills` em ordem aleatória.** A lista é ordenada só para o hash da versão bruta; sem isso, cada coleta gravava versões falsas.
- **Contadores voláteis ficam fora do hash** da versão bruta (`VOLATEIS` na função). Sem isso, cada coleta gravaria uma versão nova de quase toda vaga e o plano grátis do Supabase lotaria em semanas.
- **Título e descrição são gravados como texto limpo.** O 99Freelas manda HTML com `&ccedil;`; sem limpar, "an&aacute;lise" não bate com o termo "análise" e a nota sai errada.
- **A data da Workana é relativa** ("há 17 minutos" vira "há 2 semanas"). O gatilho `vaga_manter_primeira_data` guarda a primeira leitura, que é a mais precisa.
- **"Nova" exige duas coisas:** o Radar viu pela primeira vez nas últimas 24 h e a fonte publicou nas últimas 48 h. Só a primeira marcava como nova toda vaga antiga de uma fonte recém-chegada.
- **"Aberta" não quer dizer viva.** A Workana deixa projeto "Aberto" até o cliente fechar, por meses. Projeto de cliente (Workana, Freelancer, 99Freelas) com mais de 30 dias sai da tela (`antiga` na view). A Mercor mantém redes de especialistas abertas de propósito: essas ficam, com a etiqueta "vaga contínua" (`continua`).
- **A API do banco devolve no máximo 1.000 linhas.** A tela lê a lista em páginas, em ordem fixa (fonte, id).
- **Vaga não é apagada** quando some da fonte. Ela sai da view `vaga_aberta` e fica como histórico.

---

Parte do portfólio de [Jean Felipe Carneiro](https://jeanfelipecr-ds.github.io).

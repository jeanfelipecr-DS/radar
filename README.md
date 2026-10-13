# Radar

Painel pessoal que acompanha vagas de **freela de dados** em plataformas internacionais e as candidaturas feitas a elas, pra quem trabalha em horário comercial e quer renda extra à noite e no fim de semana.

## Por que existe

As boas vagas de dados para freelancer ficam espalhadas por várias plataformas, e a maioria dos quadros de vaga remota anuncia emprego fixo de 40h, que não cabe ao lado de um trabalho CLT. O Radar busca as fontes que têm freela de verdade, ordena pelo que eu sei entregar e mostra num painel que abre no celular.

## Como funciona

```
pg_cron no banco (de hora em hora, minuto 17)
  └─ pg_net chama a função `coletar` (Supabase Edge Function, TypeScript)
        └─ busca Mercor + Braintrust e grava
             ├─ coleta       uma linha por execução (frescor de cada fonte)
             ├─ vaga_bruta   o JSON como a fonte mandou (versão nova só quando muda)
             ├─ vaga         a vaga organizada
             └─ vaga_aberta  view: "aberta" é calculado, nunca gravado
```

O agendamento mora no banco porque o agendador do GitHub Actions é "best-effort": no repositório novo ele perdeu os primeiros horários sem rodar nenhuma vez. A primeira versão do coletor (Python + GitHub Actions) está no histórico do git.

**Tela** (parte 2): <https://jeanfelipecr-ds.github.io/radar/> — login por link no e-mail (cadastro fechado: só o dono entra), vagas abertas que aceitam Brasil ranqueadas pela nota de **encaixe** (0–100), separadas por tempo até o primeiro dinheiro (dias · semanas · meses) e um bloco à parte com vagas de tempo integral, só para ler o mercado.

A nota de encaixe mora no banco, não no código: `perfil_termo` guarda os termos da stack com peso, e a view `vaga_radar` soma o peso dobrado quando o termo aparece no título, o peso inteiro na área ou nas habilidades e metade quando ele aparece só na descrição. Mudou a stack? Muda uma linha da tabela e o ranking se recalcula na próxima leitura.

A chave que aparece no `index.html` é a pública (papel `anon`). Ela sozinha não lê nada: as regras de acesso (RLS) só liberam os dados para o login do dono.

**Fontes automáticas** (testadas em 11/10/2026):

| Fonte | Como lê | Observação |
|---|---|---|
| Mercor | JSON embutido na página pública `/explore` | toda vaga passa por entrevista em vídeo com IA, falada em inglês |
| Braintrust | API pública paginada | a maioria das vagas é restrita a EUA ou a uma lista de países |

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
- **Vaga não é apagada** quando some da fonte. Ela sai da view `vaga_aberta` e fica como histórico.

---

Parte do portfólio de [Jean Felipe Carneiro](https://jeanfelipecr-ds.github.io).

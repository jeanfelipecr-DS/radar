# Radar

Painel pessoal que acompanha vagas de **freela de dados** em plataformas internacionais e as candidaturas feitas a elas, pra quem trabalha em horário comercial e quer renda extra à noite e no fim de semana.

## Por que existe

As boas vagas de dados para freelancer ficam espalhadas por várias plataformas, e a maioria dos quadros de vaga remota anuncia emprego fixo de 40h, que não cabe ao lado de um trabalho CLT. O Radar busca as fontes que têm freela de verdade, ordena pelo que eu sei entregar e mostra num painel que abre no celular.

## Como funciona

```
GitHub Actions (de hora em hora)
  └─ coletor/coletar.py ── busca Mercor + Braintrust
        └─ Supabase
             ├─ coleta       uma linha por execução (frescor de cada fonte)
             ├─ vaga_bruta   o JSON como a fonte mandou (versão nova só quando muda)
             ├─ vaga         a vaga organizada
             └─ vaga_aberta  view: "aberta" é calculado, nunca gravado
```

**Fontes automáticas** (testadas em 11/10/2026):

| Fonte | Como lê | Observação |
|---|---|---|
| Mercor | JSON embutido na página pública `/explore` | toda vaga passa por entrevista em vídeo com IA, falada em inglês |
| Braintrust | API pública paginada | a maioria das vagas é restrita a EUA ou a uma lista de países |

Upwork, Malt, Outlier, Toptal e outras não entregam vagas de forma automática; entram como link e registro manual da candidatura.

## Rodar

```bash
python coletor/coletar.py --seco                 # busca e salva em saida/, não grava no banco
python coletor/coletar.py                        # grava no Supabase
python coletor/coletar.py --seco --fonte mercor  # uma fonte só
```

Para gravar, o coletor precisa de `SUPABASE_URL` e `SUPABASE_SERVICE_KEY` (no GitHub, em *Settings → Secrets → Actions*). Sem dependências além da biblioteca padrão do Python.

## Armadilhas

- **A Mercor não tem API.** Se a página mudar de formato, a coleta falha com erro explícito e a tela mostra a fonte como atrasada. As vagas da última coleta boa continuam visíveis.
- **O GitHub desliga agendamentos** de repositório público depois de 60 dias sem commit. Se o Radar parar de atualizar, reative o workflow em *Actions*.
- **Contadores voláteis ficam fora do hash** da versão bruta (`VOLATEIS` no coletor). Sem isso, cada coleta gravaria uma versão nova de quase toda vaga e o plano grátis do Supabase lotaria em semanas.
- **Vaga não é apagada** quando some da fonte. Ela sai da view `vaga_aberta` e fica como histórico.

---

Parte do portfólio de [Jean Felipe Carneiro](https://jeanfelipecr-ds.github.io).

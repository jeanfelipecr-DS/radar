# SDD: freelas brasileiros em português e tela em duas colunas

> 13/10/2026 · decisões do Jean em 1 rodada de perguntas (Q11–Q14) · implementado na mesma data

## 1. O pedido

"Refaça o design do Radar pra ficar de melhor visualização, e quero freelas BR em PT também, tipo um filtro: todos, ou apenas em PT."

| # | Decisão |
|---|---|
| Q11 | Fontes novas: **Workana** (só projetos em português) e **99Freelas**. |
| Q12 | Botão **Todas \| Português** ("todas as vagas"), salvo no perfil de cada pessoa (vale no celular e no computador). |
| Q13 | Valor **na moeda da vaga**. Por trás, tudo vira US$ para ordenar e para o valor mínimo. |
| Q14 | Computador em **duas colunas** (lista à esquerda, detalhe à direita), abas **Dias · Semanas · Meses · Mercado**, barra de filtro (idioma, ordenar por encaixe ou por valor). Celular em uma coluna. |

## 2. O que foi medido antes (13/10/2026)

**Workana.** A lista pública traz as vagas num JSON dentro da página (`results-initials`). Busca por palavra funciona com `jobs?language=pt&query=<palavra>`: "power bi" deu 154 projetos em português, 20 por página. O orçamento vem em texto e em dólar ("USD 100 - 250", "Menos de USD 50", "USD 15 - 45 / hora"). A data vem relativa ("há 5 dias", "Ontem"). O robots.txt só bloqueia `/api/`.

**99Freelas.** HTML, 10 projetos por página, 1.363 projetos abertos. Busca por palavra com `projects?q=<palavra>`. **O orçamento é "Aberto" em 14 de 14 projetos conferidos**: quem propõe o preço é o freelancer. A data é exata (milissegundos no atributo `cp-datetime`). Projeto "exclusivo" fica só para assinantes nas primeiras 24 h. O robots.txt libera `/projects`.

**Freelancer.com.** Dos ~500 projetos já coletados, 253 são em rupia (INR), 134 em dólar, o resto em libra, dólar canadense, euro e outras. Só 3 estão em português. O idioma vem no campo `language` de cada projeto.

**Limite da API do banco.** O Supabase devolve no máximo 1.000 linhas por consulta. Hoje a tela lê ~540 vagas; com as fontes brasileiras passa de 1.000 e a lista seria cortada sem aviso.

## 3. Desenho

### 3.1 Dados (0005)

| Objeto | Muda o quê | Por quê |
|---|---|---|
| `vaga.idioma` | código da língua da vaga (`en`, `pt`, `es`…) | o filtro Português precisa de um campo, não de uma lista de fontes: a Freelancer também tem projeto em português |
| `vaga.moeda`, `valor_min_original`, `valor_max_original` | o valor como a fonte mandou | a tela mostra a moeda da vaga (Q13) |
| `vaga.valor_min`, `valor_max` | continuam **em US$** | ordenar e comparar com o valor mínimo da pessoa não pode misturar rupia com dólar |
| `perfil.idioma_vagas` | `todos` ou `pt` | preferência de cada pessoa (Q12) |
| `vaga_aberta`, `vaga_radar` | expõem as colunas novas | a view com `v.*` congela a lista de colunas no dia em que foi criada |
| gatilho na `vaga` | na Workana, `publicada_em` fica com a **primeira** leitura | a data relativa perde precisão com o tempo ("há 17 minutos" vira "há 2 semanas"); a primeira leitura é a mais precisa que vamos ter |

Conversão: Mercor, Braintrust e Workana já vêm em dólar. A Freelancer manda a cotação no próprio projeto. O 99Freelas não tem valor. Por isso **não entra API de câmbio**: se um dia vier uma moeda sem cotação, a vaga fica sem valor em US$, aparece com o valor original e nunca é escondida pelo valor mínimo.

### 3.2 Coleta

As duas fontes novas buscam do mesmo jeito que a Freelancer: **uma busca por habilidade distinta de todos os perfis**, primeira página (Workana 20, 99Freelas 10), 4 buscas ao mesmo tempo. Busca por palavra é solta; quem separa o relevante é a nota de encaixe de cada pessoa.

- Título e descrição são gravados **como texto limpo** (sem HTML e sem `&ccedil;`). Sem isso, "an&aacute;lise" não bate com o termo "análise" e a nota sai errada.
- Workana: a versão bruta guarda o JSON da vaga sem os campos de tela (botões, popover, link de login). Data relativa, número de propostas e destaque ficam fora do hash.
- 99Freelas: não há JSON, então a versão bruta é o que se lê do HTML (título, categoria, nível, datas, propostas, descrição, habilidades, nota do cliente, se é exclusivo). Propostas, interessados e exclusivo ficam fora do hash.
- Se **nenhuma** busca devolver vaga, a coleta falha com erro explícito ("a página mudou de formato?") e a tela mostra a fonte como atrasada.
- Prazo: **Semanas** (projeto com cliente, por proposta). Idioma: `pt`.

### 3.3 Tela

```
computador (≥ 960 px)
┌──────────────────────────────────────────────────────────────────┐
│ ◆ RADAR   última busca há 12 min                Configurar  Sair │
│ Dias 12   Semanas 48   Meses 0   Mercado 31                      │
│ [Todos|Português]  [Encaixe|Valor]       7 novas no seu perfil   │
├────────────────────────┬─────────────────────────────────────────┤
│ (83) Título            │ Título grande                            │
│      US$ 40/h  Mercor  │ (83)  US$ 40–60 por hora                 │
│ (67) Título            │ Por que essa nota: Power BI · Excel      │
│ …                      │ Descrição inteira                        │
│ mostrar as outras 210  │ [Abrir na Mercor]                        │
└────────────────────────┴─────────────────────────────────────────┘
celular: mesma ordem em uma coluna; tocar na vaga abre o detalhe por cima, "Voltar" (e o voltar do Android) fecha
```

- **Abas** no lugar dos blocos que abriam e fechavam. Cada aba diz o que é numa linha. A aba e a ordem ficam guardadas no aparelho; o idioma fica no perfil.
- **Ordenar por valor** separa por unidade (por hora, por projeto…): US$ 50 por hora e US$ 500 pelo projeto não se comparam.
- **Valor**: na moeda da vaga na lista; no detalhe, o equivalente em US$ quando a moeda é outra. Vaga do 99Freelas mostra "orçamento aberto".
- **Anel de encaixe**: o arco enche até a nota (o mesmo dourado da marca: cheio a partir de 75, contorno de 50 a 74, apagado abaixo).
- Saem os dois números "parte 3" (candidaturas e recebido): voltam quando a parte 3 existir.
- A lista é lida em páginas de 1.000.

## 4. Risco real e como evitar

| Pode ser afetado | Como evitar / conferir |
|---|---|
| Nota do Jean mudar | a fórmula não muda; conferir o mesmo topo de Dias (Excel 100 · BI 100 · Data Analysis 83) |
| Workana/99Freelas bloquearem | 1 vez por hora, 4 buscas por vez, User-Agent identificado; falha de uma fonte não para as outras |
| Banco grátis lotar | bruto da Workana sem campos de tela; medir o tamanho depois da 1ª coleta |
| Lista cortada em 1.000 | leitura em páginas; conferir que o total da tela = total da view |
| Freelancer antiga sem idioma/moeda | preenchidos a partir da última versão bruta de cada projeto |

## 5. Critérios de aceite (binários)

1. A coleta grava projetos da Workana e do 99Freelas com idioma `pt`, título e descrição sem HTML.
2. Freelancer passa a ter idioma e moeda original; valor em US$ continua igual ao de antes.
3. O botão Português mostra só vagas `pt`; a escolha volta igual depois de sair e entrar de novo.
4. No computador, lista e detalhe lado a lado; no celular (500 px), uma coluna e o detalhe abre por cima.
5. Ordenar por valor agrupa por unidade, maior primeiro.
6. O total de vagas da tela bate com o total da view (nada cortado em 1.000).
7. O topo de Dias do Jean continua igual; o amigo de teste vê o perfil Vídeo e é apagado no fim.
8. 0 erros de JavaScript no console.

## 6. O que este SDD não faz

- Candidaturas e dinheiro (parte 3).
- Links manuais (Upwork, Malt, Toptal, Arc): parte 4.
- Detalhe da vaga direto da fonte (abrir a página de cada projeto): a lista já traz a descrição.

## 7. Relatório (13/10/2026)

**Entregue:** `0005_idioma_moeda_freelas_br.sql`, `coletar` v4 (Workana e 99Freelas; idioma e moeda em todas as fontes), `index.html` refeito (abas, duas colunas, filtro de idioma, ordenar por valor).

| # | Critério | Resultado |
|---|---|---|
| 1 | Workana e 99Freelas gravadas em `pt`, sem HTML | ✅ Workana 144 e 99Freelas 136 na 1ª coleta; 0 títulos e 0 descrições com HTML ou `&…;`; coleta inteira (5 fontes) em 30 s |
| 2 | Freelancer com idioma e moeda | ✅ preenchidos pela última versão bruta: 131 em rupia, 15 em libra, 2 em português; a conversão para US$ não mudou |
| 3 | Português filtra e fica salvo | ✅ só vaga `pt`; depois de recarregar a página o botão voltou em Português (amigo de teste) |
| 4 | Duas colunas e celular | ✅ prints em 1440 px e 390 px; no celular o detalhe abre por cima e o "voltar" fecha sem sair do Radar; nada passa da largura da tela |
| 5 | Ordenar por valor agrupa por unidade | ✅ Semanas/Português: por hora 16, pelo projeto 81, sem valor informado 63 |
| 6 | Nada cortado em 1.000 | ✅ a soma das abas (49 + 277 + 0 + 53 = 379 com encaixe) bate com a view; hoje são 778 vagas, então o caminho de mais de uma página ainda não rodou de verdade |
| 7 | Topo do Jean igual; amigo de teste | ✅ Dias: BI 100, Excel 100, Data Analysis 83 (igual a antes da migração). Amigo de teste com modelo Vídeo viu "Produtor de Vídeos…" e "Editor de Vídeo…" com nota 100, recebeu 403 no Convidar e só leu o próprio perfil; apagado no fim |
| 8 | Sem erro de JavaScript | ✅ 0 erros nas 3 rodadas (Jean no computador e no celular, amigo no celular e no computador) |

**Desvios e achados:**
- **"Nova" estava errada para fonte recém-chegada.** No dia em que Workana e 99Freelas entraram, a tela mostrava 162 novas (até vaga de 8 meses da Mercor, porque o banco foi recriado hoje). Regra nova: vista pela 1ª vez nas últimas 24 h **e** publicada nas últimas 48 h.
- **99Freelas não tem valor**: a vaga aparece como "Orçamento aberto: quem propõe o preço é você" e nunca some pelo valor mínimo.
- **Saíram os dois números "parte 3"** (candidaturas e recebido): voltam quando a parte 3 existir.
- O teste de tela passou a rodar pelo protocolo de depuração do Edge (Node puro, sem Playwright): clica, troca de largura e lê os erros do console.

**Riscos que ficam:** Workana e 99Freelas não têm API; se a página mudar, a coleta da fonte falha com erro explícito e a tela mostra a fonte como atrasada. Cada habilidade nova de qualquer perfil vira mais uma busca em 3 fontes (hoje ~30 buscas por fonte, 30 s no total).

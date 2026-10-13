# SDD — Radar para o Jean e amigos (multiusuário, Configurar, Freelancer.com)

> 13/10/2026 · decisões tomadas com o Jean em 2 rodadas de perguntas (Q1–Q10) · implementado na mesma data

## 1. O pedido

Um amigo do Jean, editor de vídeo, quer usar o Radar. O Radar é de uma pessoa só: a regra de acesso confere o e-mail do Jean e o perfil de encaixe é a stack de dados dele. O pedido é deixar o Radar **configurável** para o Jean e alguns amigos.

Decisões do Jean:

| # | Decisão |
|---|---|
| Q1 | Só o Jean e alguns amigos, **por convite**. Cadastro continua fechado. |
| Q2 | Qualquer plataforma serve como fonte → entra a **Freelancer.com** (Q8). |
| Q3 | "Configurável" = cada pessoa edita **as próprias habilidades** (com peso) e **as áreas que esconde**. |
| Q4 | Amigo entra com **e-mail e senha** (o plano grátis só entrega o link de login para a equipe do projeto, 2/hora). O Jean continua com o link. |
| Q5 | Fica na identidade do Jean. |
| Q6 | Isto vem **antes** da parte 3 (candidaturas), que já nasce por pessoa. |
| Q7 | Convite por uma **tela que só o Jean vê**: e-mail + modelo → senha provisória para mandar no WhatsApp; "gerar nova senha" quando o amigo esquecer. |
| Q8 | **Freelancer.com** entra (API pública), buscando com as habilidades de cada perfil, valor convertido para US$, no bloco SEMANAS. |
| Q9 | Perfil novo nasce de **modelo pronto** editável: **Vídeo** ou **Dados**. |
| Q10 | **Valor mínimo (US$) opcional** por pessoa; em branco mostra tudo. |

## 2. O que já existe (nada é criado do zero)

- `vaga`, `vaga_bruta`, `coleta` e as views `vaga_aberta`, `frescor_fonte` (0001) — continuam iguais; só a regra de leitura muda.
- `perfil_termo` + view `vaga_radar` com a nota de encaixe (0002). A view é `security_invoker`: ela já lê `perfil_termo` com os direitos de quem está logado. **Se `perfil_termo` passar a ser filtrado por dono, cada pessoa vê a nota calculada com o próprio perfil sem mudar a fórmula.**
- Função `coletar` + pg_cron (0003) — ganha uma terceira fonte.
- `index.html` — ganha login por senha, a tela Configurar e o filtro de valor mínimo.

## 3. Desenho

### 3.1 Dados (0004)

| Objeto | O que é | Quem lê / escreve |
|---|---|---|
| `perfil` (novo) | uma linha por pessoa: nome, modelo de origem, `valor_min_usd` | dono lê e edita a própria; criação só pela função `convidar` |
| `modelo_termo` (novo) | os modelos **Dados** (= perfil atual do Jean) e **Vídeo** | todo convidado lê; ninguém escreve pela tela |
| `perfil_termo` | ganha `user_id`; chave vira `(user_id, termo)` | **cada um só vê e edita as próprias linhas** |
| `vaga`, `vaga_bruta`, `coleta` | vagas são compartilhadas | qualquer convidado lê (leitura só para `authenticated`; cadastro fechado ⇒ autenticado = convidado) |
| `vaga_radar` | ganha `abaixo_minimo` (valor máximo da vaga < valor mínimo da pessoa) | — |

**Ninguém digita expressão regular.** Na tela a pessoa escreve "After Effects"; um gatilho monta o termo de busca (escapa caracteres especiais, põe marca de começo/fim de palavra quando a ponta é letra ou número).

**Valor mínimo** compara com o valor máximo da vaga na unidade dela (por hora ou pelo projeto inteiro). Vaga sem valor nunca é escondida.

### 3.2 Funções

- **`convidar`** (nova, chamada pela tela do Jean): confere que o token é do Jean (e-mail do dono) e faz `listar`, `criar` (cria a conta já confirmada com senha provisória, cria o `perfil` e copia os termos do modelo) e `nova_senha`. A chave de serviço nunca vai para o navegador.
- **`coletar`** ganha a fonte **freelancer**:
  - busca `projects/active` com cada habilidade distinta de todos os perfis (25 por busca), junta por id e descarta os projetos locais;
  - converte o orçamento para US$ com a cotação que vem no próprio projeto;
  - grava `tipo = freela`, `prazo = semanas` e `unidade` = hora ou projeto;
  - grava a versão bruta **sem os campos nulos** (~7 KB → poucos KB por projeto) e deixa os contadores de propostas fora do hash.

### 3.3 Tela

- **Login:** e-mail + senha; "receber link no e-mail" fica como opção (é o login do Jean).
- **Topo:** botão **Configurar** (janela própria — regra "configuração fora da lista").
- **Configurar:** minhas habilidades (peso 1 ou ½, remover, adicionar) · áreas para esconder · valor mínimo · trocar senha · **Convidar** (só o Jean): e-mail + modelo → senha provisória com botão copiar; lista de convidados com "gerar nova senha".
- **Lista de vagas:** esconde `abaixo_minimo`; Freelancer aparece como fonte.

### 3.4 Desktop e celular

Mesma coluna única de até 560 px; a Configurar empilha as seções. Nada depende de hover.

## 4. Impacto medido antes

- 1 usuário (o Jean), 21 linhas em `perfil_termo`, 0 linhas de perfil.
- Vagas abertas: Mercor 286 · Braintrust 148. Vagas de vídeo que aceitam Brasil: **3** (todas Mercor).
- Freelancer.com: 1.062 projetos ativos para "video editing" (busca por palavra é solta: "premiere pro" trouxe "migrar Xero"). O ranking de encaixe é o que separa o relevante.

## 5. Risco real — e como evitar (blast radius)

| Pode ser afetado | Como evitar / conferir |
|---|---|
| A nota de encaixe do Jean mudar | os termos dele ganham o `user_id` dele; conferir a mesma ordem do topo (BI 100, Excel 100, Data Analysis 83) depois da migração |
| Um amigo ver o perfil de outra pessoa | regra `user_id = auth.uid()` em `perfil_termo` e `perfil`; teste com o usuário de teste tentando ler o perfil do Jean |
| Amigo convidar gente | `convidar` confere o e-mail do dono no token; teste com o usuário de teste → 403 |
| Chave de serviço no navegador | só dentro das funções; varredura do `index.html` |
| Banco grátis (500 MB) lotar com a Freelancer | bruto sem nulos + 25 por busca; medir o tamanho depois da 1ª coleta |
| Freelancer bloquear | busca sequencial, 1 vez por hora; falha da fonte vira coleta com erro (as outras seguem) |

Backup antes: as tabelas atuais têm só dado regerável (vagas) e o perfil do Jean (21 linhas, também no `0002`).

## 6. Critérios de aceite (binários)

1. O Jean logado vê o mesmo topo de antes (BI 100 · Excel 100 · Data Analysis 83).
2. Pela tela Convidar, o Jean cria um amigo de teste com o modelo Vídeo e recebe uma senha provisória.
3. O amigo de teste entra com e-mail e senha e vê as vagas de vídeo da Mercor no topo, com a nota calculada pelo modelo Vídeo.
4. O amigo de teste não lê o perfil do Jean (0 linhas) e a função `convidar` devolve 403 para ele.
5. Adicionar uma habilidade na Configurar muda a nota sem recoletar.
6. Valor mínimo esconde as vagas abaixo dele; em branco não esconde nada.
7. A coleta grava projetos da Freelancer com valor em US$ e o tamanho do banco segue folgado.
8. O usuário de teste é apagado no fim.

## 7. O que este SDD não faz

- Candidaturas e dinheiro (parte 3).
- Cadastro aberto, e-mail próprio (SMTP), recuperação de senha por e-mail.
- Upwork, Workana, 99Freelas, Fiverr (sem API pública) — entram como link na parte 4.

## 8. Relatório (13/10/2026)

**Entregue:** `0004_multiusuario.sql`, função `convidar` (nova), `coletar` v3 com a Freelancer, `index.html` com login por senha, Configurar e valor mínimo.

| # | Critério | Resultado |
|---|---|---|
| 1 | Topo do Jean igual | ✅ Excel 100 · BI 100 · Data Analysis 83 (DIAS); no SEMANAS entram projetos reais da Freelancer (PostgreSQL Optimization US$394, Sales Data Pipeline US$250) |
| 2 | Convite cria amigo com modelo Vídeo + senha provisória | ✅ |
| 3 | Amigo entra com senha e vê vídeo no topo | ✅ Video Editing Professional 100 · Premiere 83 · DaVinci 83 (DIAS); 68 projetos de vídeo da Freelancer no SEMANAS |
| 4 | Amigo isolado | ✅ lê só os 12 termos dele e só o próprio perfil; `convidar` → **403** |
| 5 | Habilidade nova muda a nota sem recoletar | ✅ "Canva" → termo `\mcanva\M`; vaga com Canva 17 → 83 |
| 6 | Valor mínimo | ✅ em branco esconde 0; US$45 esconde 237 |
| 7 | Freelancer em US$ e banco folgado | ✅ 247 projetos (só perfil Dados) → 332 com o modelo Vídeo, 2,2 s; banco 15 → 17 MB (bruto da Freelancer 626 KB sem os nulos) |
| 8 | Usuário de teste apagado | ✅ sobra 1 usuário (o Jean), 1 perfil, 21 termos |

**Verificação de tela:** prints em 500 px (Jean: vagas e Configurar; amigo: vagas), 0 erros de JavaScript. Sessões de teste geradas pelo admin (sem e-mail) e encerradas em seguida.

**Desvios e achados:**
- Projeto por hora da Freelancer quase sempre pede 30h+/semana → vai para o bloco de mercado pela mesma regra da Braintrust (70 de 70 na 1ª coleta).
- A busca da Freelancer é solta; o que separa o relevante é a nota de cada perfil ("mostrar as outras N" guarda o resto).
- O template do e-mail de login não é editável no plano grátis; o Jean continua recebendo "Your sign-in link" em inglês.

**Riscos que ficam:** "autenticado = convidado" só vale com o cadastro fechado; se um dia abrir, revisar as regras de leitura das vagas. A cada perfil novo, a coleta faz mais buscas na Freelancer (uma por habilidade distinta) — com dezenas de amigos, medir o tempo da função.

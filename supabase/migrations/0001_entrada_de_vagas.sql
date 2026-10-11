-- 0001 — Entrada de vagas do Radar (parte 1)
--
-- Por que existe: o coletor (coletor/coletar.py) roda de hora em hora e precisa de
-- um lugar onde a vaga entra sem perder o original e sem duplicar.
--
-- Guardar entrada, calcular saída:
--   coleta      → uma linha por execução por fonte (é o termômetro de frescor da tela)
--   vaga_bruta  → o JSON como a fonte mandou; versão nova só quando o conteúdo estável muda
--   vaga        → a vaga organizada, uma linha por (fonte, id_externo)
--   vaga_aberta → "está aberta?" é CALCULADO, nunca gravado (ver a view)
--
-- Armadilha: nada aqui é apagado pelo coletor. Vaga que some da fonte continua na
-- tabela `vaga` (é histórico pro termômetro de mercado da v2); só sai da view.

create table public.coleta (
  id            bigint generated always as identity primary key,
  fonte         text        not null,
  iniciada_em   timestamptz not null default now(),
  terminada_em  timestamptz,
  ok            boolean,              -- null = ainda gravando
  n_vagas       integer,
  erro          text
);
create index coleta_fonte_ok_idx on public.coleta (fonte, id desc) where ok;

create table public.vaga_bruta (
  fonte        text        not null,
  id_externo   text        not null,
  hash         text        not null,  -- sha256 do payload SEM os contadores voláteis
  payload      jsonb       not null,
  recebida_em  timestamptz not null default now(),
  primary key (fonte, id_externo, hash)
);

create table public.vaga (
  fonte              text        not null,
  id_externo         text        not null,
  titulo             text,
  empresa            text,
  url                text        not null,
  descricao          text,
  area               text,
  habilidades        text[]      not null default '{}',
  compromisso        text,                          -- como a fonte chama (hourly, freelance, direct_hire…)
  tipo               text        not null check (tipo in ('freela', 'integral')),
  prazo              text        not null check (prazo in ('dias', 'semanas', 'meses')),
  valor_min          numeric,
  valor_max          numeric,
  unidade            text        check (unidade in ('hora', 'tarefa', 'projeto', 'ano')),
  horas_semana       integer,
  entrevista_falada  boolean,                       -- null = não sabemos; etiqueta só quando true
  aceita_brasil      boolean,
  publicada_em       timestamptz,
  primeira_vez_em    timestamptz not null default now(),  -- só vale na 1ª inserção (coletor não envia)
  ultima_vez_em      timestamptz not null default now(),
  ultima_coleta_id   bigint      not null references public.coleta (id),
  primary key (fonte, id_externo)
);
create index vaga_ultima_coleta_idx on public.vaga (fonte, ultima_coleta_id);

-- Aberta = apareceu na última coleta BOA da fonte (ou numa mais nova, que ainda está gravando).
-- Por que ">=" e não "=": durante os segundos em que uma coleta grava, as vagas já atualizadas
-- carregam o id novo, ainda não confirmado. Com "=" elas sumiriam da tela até o fim da gravação.
-- Se a fonte falhar, a última coleta boa não muda → as vagas dela continuam na tela.
create view public.vaga_aberta with (security_invoker = true) as
with ultima_boa as (
  select fonte, max(id) as coleta_id
  from public.coleta
  where ok
  group by fonte
)
select v.*
from public.vaga v
join ultima_boa u on u.fonte = v.fonte and v.ultima_coleta_id >= u.coleta_id;

-- Frescor por fonte: a tela mostra "última busca há X min" e o erro, se houver.
-- Sem isso, robô quebrado parece "não tem vaga".
create view public.frescor_fonte with (security_invoker = true) as
select
  fonte,
  max(terminada_em) filter (where ok)            as ultima_coleta_boa,
  (array_agg(ok   order by id desc))[1]          as ultima_deu_certo,
  (array_agg(erro order by id desc))[1]          as ultimo_erro
from public.coleta
group by fonte;

-- Acesso: só o Jean lê (login por e-mail). O coletor usa a chave de serviço, que ignora RLS.
-- Ninguém de fora (anon) enxerga nada.
alter table public.coleta     enable row level security;
alter table public.vaga_bruta enable row level security;
alter table public.vaga       enable row level security;

create policy jean_le_coleta     on public.coleta     for select to authenticated
  using (auth.jwt() ->> 'email' = 'jeanfelipecr@gmail.com');
create policy jean_le_vaga_bruta on public.vaga_bruta for select to authenticated
  using (auth.jwt() ->> 'email' = 'jeanfelipecr@gmail.com');
create policy jean_le_vaga       on public.vaga       for select to authenticated
  using (auth.jwt() ->> 'email' = 'jeanfelipecr@gmail.com');

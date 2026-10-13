-- 0002 — Perfil de encaixe e a visão que a tela lê (parte 2)
--
-- Por que existe: o Radar ordena as vagas pelo que o Jean sabe entregar. O "saber entregar"
-- mora numa TABELA (perfil_termo), não no código: mudou a stack, muda uma linha e o ranking
-- inteiro se recalcula na próxima leitura — sem recoletar nada (guardar entrada, calcular saída).
--
-- Como a nota funciona (vaga_radar.encaixe, 0–100):
--   termo no TÍTULO                 → vale o dobro do peso (o título diz o que a vaga é)
--   termo na área ou nas habilidades → vale o peso
--   termo só na descrição            → vale metade (descrição longa cita de tudo)
--   3 pontos = 100. dbt vale 0,5 porque ainda está em estudo (Zoomcamp).
--   Calibrado em 13/10/2026: com "título = peso" e 4 pontos, o próprio "Data Analysis Expert"
--   tirava 38 — abaixo de vaga genérica que só citava análise de dados na descrição.
-- Termo do tipo 'esconder' (formação específica: médico, advogado, químico) tira a vaga da tela,
-- mas ela continua no banco.
--
-- Armadilha: os termos são expressões regulares do Postgres. \m e \M marcam início/fim de
-- palavra — sem eles "bi" acharia "am-BI-tion".

create table public.perfil_termo (
  termo   text primary key,                         -- regex, minúsculo
  rotulo  text not null,                            -- como aparece na tela
  peso    numeric not null default 1,
  tipo    text not null check (tipo in ('encaixe', 'esconder'))
);

insert into public.perfil_termo (termo, rotulo, peso, tipo) values
  ('\msql\M',                                   'SQL',                  1,   'encaixe'),
  ('bigquery',                                  'BigQuery',             1,   'encaixe'),
  ('\mpostgres',                                'Postgres',             1,   'encaixe'),
  ('\mpython\M',                                'Python',               1,   'encaixe'),
  ('\mpandas\M',                                'pandas',               1,   'encaixe'),
  ('\mexcel\M',                                 'Excel',                1,   'encaixe'),
  ('power ?bi',                                 'Power BI',             1,   'encaixe'),
  ('looker',                                    'Looker Studio',        1,   'encaixe'),
  ('dashboard',                                 'Dashboard',            1,   'encaixe'),
  ('\metl\M|\melt\M',                           'ETL',                  1,   'encaixe'),
  ('data analy|análise de dados|analista de dados', 'Análise de dados', 1,   'encaixe'),
  ('business intelligence|\mbi\M',              'BI',                   1,   'encaixe'),
  ('marketing analytics|marketing data',        'Marketing analytics',  1,   'encaixe'),
  ('meta ads|facebook ads',                     'Meta Ads',             1,   'encaixe'),
  ('attribution|atribui',                       'Atribuição',           1,   'encaixe'),
  ('\mfunnel|\mfunil',                          'Funil',                1,   'encaixe'),
  ('\mcrm\M',                                   'CRM',                  1,   'encaixe'),
  ('\mdbt\M',                                   'dbt',                  0.5, 'encaixe'),
  ('medicine|medical|physician|clinical|\mnurs', 'Medicina',            1,   'esconder'),
  ('\mlaw\M|lawyer|attorney|\mlegal\M|paralegal', 'Direito',            1,   'esconder'),
  ('chemist|chemistry',                         'Química',              1,   'esconder');

-- A visão que a tela lê: só vaga aberta, com nota de encaixe, termos achados e "nova" (24 h).
create or replace view public.vaga_radar with (security_invoker = true) as
select
  v.fonte, v.id_externo, v.titulo, v.empresa, v.url, v.area, v.habilidades, v.compromisso,
  v.tipo, v.prazo, v.valor_min, v.valor_max, v.unidade, v.horas_semana,
  v.entrevista_falada, v.aceita_brasil, v.publicada_em, v.primeira_vez_em,
  n.encaixe, n.termos, n.escondida,
  v.primeira_vez_em > now() - interval '24 hours' as nova
from public.vaga_aberta v
cross join lateral (
  select
    least(100, round(100.0 / 3 * coalesce(sum(
      case when t.tipo <> 'encaixe' then 0
           when c.titulo ~ t.termo then t.peso * 2
           when c.extra ~ t.termo then t.peso
           when c.corpo ~ t.termo then t.peso * 0.5
           else 0 end), 0)))::int                                         as encaixe,
    coalesce(array_agg(t.rotulo order by t.peso desc, t.rotulo)
      filter (where t.tipo = 'encaixe' and (c.titulo ~ t.termo or c.extra ~ t.termo or c.corpo ~ t.termo)), '{}') as termos,
    coalesce(bool_or(t.tipo = 'esconder' and (c.titulo ~ t.termo or c.extra ~ t.termo)), false) as escondida
  from (select lower(coalesce(v.titulo, ''))                                                as titulo,
               lower(coalesce(v.area, '') || ' ' || array_to_string(v.habilidades, ' '))   as extra,
               lower(coalesce(v.descricao, ''))                                            as corpo) c
  cross join public.perfil_termo t
) n;

-- Acesso: só o Jean lê e edita o perfil (a tela de "Configurar" escreve aqui).
alter table public.perfil_termo enable row level security;
create policy jean_perfil on public.perfil_termo for all to authenticated
  using (auth.jwt() ->> 'email' = 'jeanfelipecr@gmail.com')
  with check (auth.jwt() ->> 'email' = 'jeanfelipecr@gmail.com');

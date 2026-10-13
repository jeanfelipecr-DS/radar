-- 0005 — Freelas brasileiros (Workana, 99Freelas), idioma e moeda da vaga
-- (ver docs/SDD_freelas_br_e_layout.md)
--
-- Por que existe: o Jean quer ver só vaga em português quando quiser (botão Todos | Português,
-- salvo no perfil) e ver o valor na moeda da vaga. Ordenar e comparar com o valor mínimo continua
-- em US$: rupia ao lado de dólar não se compara.
--
-- Armadilha: as views que usam "v.*" congelam a lista de colunas no dia em que foram criadas.
-- Coluna nova na `vaga` só aparece na tela depois de recriar vaga_aberta e vaga_radar.

-- ------------------------------------------------------------------ vaga: idioma e moeda
alter table public.vaga
  add column idioma             text,                          -- 'en', 'pt', 'es'… (null = a fonte não diz)
  add column moeda              text not null default 'USD',   -- moeda em que a fonte publicou o valor
  add column valor_min_original numeric,                       -- valor como a fonte mandou, na moeda acima
  add column valor_max_original numeric;
comment on column public.vaga.valor_min is 'em US$: é o que ordena e o que se compara com o valor mínimo da pessoa';
comment on column public.vaga.valor_max is 'em US$: é o que ordena e o que se compara com o valor mínimo da pessoa';

-- Mercor e Braintrust: sempre em inglês e em dólar
update public.vaga set idioma = 'en', valor_min_original = valor_min, valor_max_original = valor_max
where fonte in ('mercor', 'braintrust');

-- Freelancer: idioma e moeda saem da última versão bruta de cada projeto (a coleta só reescreve os abertos)
update public.vaga v set
  idioma             = b.payload ->> 'language',
  moeda              = coalesce(b.payload -> 'currency' ->> 'code', 'USD'),
  valor_min_original = (b.payload -> 'budget' ->> 'minimum')::numeric,
  valor_max_original = (b.payload -> 'budget' ->> 'maximum')::numeric
from (select distinct on (id_externo) id_externo, payload
      from public.vaga_bruta where fonte = 'freelancer'
      order by id_externo, recebida_em desc) b
where v.fonte = 'freelancer' and v.id_externo = b.id_externo;

-- Workana publica a data como "há 5 dias". A primeira leitura é a mais precisa que existe
-- ("há 17 minutos" vira "há 2 semanas" com o tempo), então ela fica.
create function public.manter_primeira_data() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.publicada_em is not null then new.publicada_em := old.publicada_em; end if;
  return new;
end $$;
create trigger vaga_manter_primeira_data before update on public.vaga
  for each row when (old.fonte = 'workana') execute function public.manter_primeira_data();

-- ------------------------------------------------------------------ perfil: idioma das vagas
alter table public.perfil
  add column idioma_vagas text not null default 'todos' check (idioma_vagas in ('todos', 'pt'));

-- ------------------------------------------------------------------ views com as colunas novas
create or replace view public.vaga_aberta with (security_invoker = true) as
with ultima_boa as (
  select fonte, max(id) as coleta_id
  from public.coleta
  where ok
  group by fonte
)
select v.*
from public.vaga v
join ultima_boa u on u.fonte = v.fonte and v.ultima_coleta_id >= u.coleta_id;

create or replace view public.vaga_radar with (security_invoker = true) as
select
  v.fonte, v.id_externo, v.titulo, v.empresa, v.url, v.area, v.habilidades, v.compromisso,
  v.tipo, v.prazo, v.valor_min, v.valor_max, v.unidade, v.horas_semana,
  v.entrevista_falada, v.aceita_brasil, v.publicada_em, v.primeira_vez_em,
  n.encaixe, n.termos, n.escondida,
  -- "nova" = o Radar viu pela 1ª vez nas últimas 24 h E a fonte publicou nas últimas 48 h.
  -- Só a 1ª condição marcava como nova toda vaga antiga de uma fonte recém-chegada
  -- (no dia em que Workana e 99Freelas entraram, até vaga de 8 meses da Mercor aparecia como nova).
  v.primeira_vez_em > now() - interval '24 hours'
    and coalesce(v.publicada_em, v.primeira_vez_em) > now() - interval '48 hours' as nova,
  -- valor mínimo da pessoa logada, na unidade da vaga (hora ou projeto); vaga sem valor nunca some
  coalesce(v.valor_max < (select p.valor_min_usd from public.perfil p where p.user_id = auth.uid()), false) as abaixo_minimo,
  v.idioma, v.moeda, v.valor_min_original, v.valor_max_original
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
  cross join public.perfil_termo t           -- RLS: só os termos de quem está logado
) n;

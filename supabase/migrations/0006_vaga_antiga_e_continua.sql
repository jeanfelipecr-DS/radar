-- 0006 — Projeto antigo some; vaga contínua da Mercor ganha nome (ver docs/SDD_freelas_br_e_layout.md §8)
--
-- Por que existe: "aberta" no Radar = a plataforma ainda lista a vaga. Isso não basta:
--   - a Workana deixa projeto "Aberto" até o cliente fechar (um de BigQuery publicado em 09/03/2026
--     seguia "Aberto" em 14/10, com 0 propostas). 21 de 140 tinham mais de 30 dias;
--   - o 99Freelas fecha sozinho em 30 dias — então 30 dias é a régua para projeto de cliente
--     (decisão do Jean em 14/10/2026), igual nas três fontes de projeto: Workana, Freelancer, 99Freelas.
--   - a Mercor mantém de propósito redes de especialistas abertas por meses ("talent networks"):
--     essas são abertas de verdade, então NÃO somem; ganham o nome "vaga contínua".
-- Braintrust fica fora das duas regras (vaga de empresa, fecha quando preenche).
--
-- Armadilha: a idade usa publicada_em (data da fonte); sem data, vale a 1ª vez que o Radar viu.

create or replace view public.vaga_radar with (security_invoker = true) as
select
  v.fonte, v.id_externo, v.titulo, v.empresa, v.url, v.area, v.habilidades, v.compromisso,
  v.tipo, v.prazo, v.valor_min, v.valor_max, v.unidade, v.horas_semana,
  v.entrevista_falada, v.aceita_brasil, v.publicada_em, v.primeira_vez_em,
  n.encaixe, n.termos, n.escondida,
  -- "nova" = o Radar viu pela 1ª vez nas últimas 24 h E a fonte publicou nas últimas 48 h.
  -- Só a 1ª condição marcava como nova toda vaga antiga de uma fonte recém-chegada.
  v.primeira_vez_em > now() - interval '24 hours'
    and coalesce(v.publicada_em, v.primeira_vez_em) > now() - interval '48 hours' as nova,
  -- valor mínimo da pessoa logada, na unidade da vaga (hora ou projeto); vaga sem valor nunca some
  coalesce(v.valor_max < (select p.valor_min_usd from public.perfil p where p.user_id = auth.uid()), false) as abaixo_minimo,
  v.idioma, v.moeda, v.valor_min_original, v.valor_max_original,
  -- projeto de cliente com mais de 30 dias: aberto no papel, quase sempre abandonado → a tela esconde
  v.fonte in ('workana', 'freelancer', '99freelas')
    and coalesce(v.publicada_em, v.primeira_vez_em) < now() - interval '30 days' as antiga,
  -- rede de especialistas da Mercor aberta há mais de 30 dias: aberta de propósito
  v.fonte = 'mercor'
    and coalesce(v.publicada_em, v.primeira_vez_em) < now() - interval '30 days' as continua
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

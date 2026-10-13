-- 0004 — Radar para o Jean e amigos (ver docs/SDD_multiusuario.md)
--
-- Por que existe: o Radar era de uma pessoa só (regra de acesso pelo e-mail do Jean, um perfil).
-- Agora: vagas COMPARTILHADAS entre convidados; perfil, habilidades e valor mínimo DE CADA UM.
--
-- O truque que evita reescrever a nota de encaixe: a view vaga_radar é security_invoker, então
-- ela já lê perfil_termo com os direitos de quem está logado. Filtrando perfil_termo por dono,
-- cada pessoa vê a nota calculada com o próprio perfil — a fórmula não muda.
--
-- Armadilha: "authenticated" = convidado SÓ porque o cadastro está fechado (disable_signup).
-- Se um dia o cadastro abrir, as regras de leitura de vaga/coleta precisam ser revistas.

-- ------------------------------------------------------------------ modelos prontos
create table public.modelo_termo (
  modelo  text not null check (modelo in ('dados', 'video')),
  termo   text not null,
  rotulo  text not null,
  peso    numeric not null default 1,
  tipo    text not null check (tipo in ('encaixe', 'esconder')),
  primary key (modelo, termo)
);

-- Dados = o perfil do Jean como está hoje
insert into public.modelo_termo (modelo, termo, rotulo, peso, tipo)
select 'dados', termo, rotulo, peso, tipo from public.perfil_termo;

-- Vídeo = a lista combinada com o Jean (Q9) + "edição de vídeo" genérico, que é o título das vagas
insert into public.modelo_termo (modelo, termo, rotulo, peso, tipo) values
  ('video', 'video edit|editor de v[ií]deo|edi[cç][aã]o de v[ií]deo|\mvideo editor', 'Edição de vídeo', 1, 'encaixe'),
  ('video', '\mpremiere',                         'Premiere',          1, 'encaixe'),
  ('video', 'after effects',                      'After Effects',     1, 'encaixe'),
  ('video', 'davinci',                            'DaVinci Resolve',   1, 'encaixe'),
  ('video', 'final cut',                          'Final Cut',         1, 'encaixe'),
  ('video', '\mmotion',                           'Motion',            1, 'encaixe'),
  ('video', 'youtube',                            'YouTube',           1, 'encaixe'),
  ('video', '\mreels?\M|tiktok|\mshorts\M',       'Reels / TikTok',    1, 'encaixe'),
  ('video', 'color grading|color correction|corre[cç][aã]o de cor|coloriza', 'Correção de cor', 1, 'encaixe'),
  ('video', 'medicine|medical|physician|clinical|\mnurs',      'Medicina', 1, 'esconder'),
  ('video', '\mlaw\M|lawyer|attorney|\mlegal\M|paralegal',     'Direito',  1, 'esconder'),
  ('video', 'chemist|chemistry',                               'Química',  1, 'esconder');

-- ------------------------------------------------------------------ perfil de cada pessoa
create table public.perfil (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  nome           text,
  modelo         text check (modelo in ('dados', 'video')),
  valor_min_usd  numeric check (valor_min_usd is null or valor_min_usd >= 0),
  criado_em      timestamptz not null default now()
);
insert into public.perfil (user_id, nome, modelo)
select id, 'Jean', 'dados' from auth.users where email = 'jeanfelipecr@gmail.com';

-- ------------------------------------------------------------------ perfil_termo passa a ter dono
alter table public.perfil_termo add column user_id uuid references auth.users (id) on delete cascade;
update public.perfil_termo set user_id = (select id from auth.users where email = 'jeanfelipecr@gmail.com');
alter table public.perfil_termo alter column user_id set not null;
alter table public.perfil_termo alter column user_id set default auth.uid();
alter table public.perfil_termo drop constraint perfil_termo_pkey;
alter table public.perfil_termo add primary key (user_id, termo);

-- Ninguém digita expressão regular: a tela manda só o rótulo ("After Effects") e este gatilho
-- monta o termo — escapa os caracteres especiais e marca começo/fim de palavra quando a ponta
-- é letra/número (sem isso "bi" acharia "am-BI-tion").
create function public.montar_termo() returns trigger
language plpgsql set search_path = public as $$
declare t text;
begin
  if new.termo is null or btrim(new.termo) = '' then
    t := regexp_replace(lower(btrim(new.rotulo)), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g');
    if t ~ '^\w' then t := '\m' || t; end if;
    if t ~ '\w$' then t := t || '\M'; end if;
    new.termo := t;
  end if;
  return new;
end $$;
create trigger perfil_termo_montar before insert on public.perfil_termo
  for each row execute function public.montar_termo();

-- ------------------------------------------------------------------ a tela lê: nota + valor mínimo
create or replace view public.vaga_radar with (security_invoker = true) as
select
  v.fonte, v.id_externo, v.titulo, v.empresa, v.url, v.area, v.habilidades, v.compromisso,
  v.tipo, v.prazo, v.valor_min, v.valor_max, v.unidade, v.horas_semana,
  v.entrevista_falada, v.aceita_brasil, v.publicada_em, v.primeira_vez_em,
  n.encaixe, n.termos, n.escondida,
  v.primeira_vez_em > now() - interval '24 hours' as nova,
  -- valor mínimo da pessoa logada, na unidade da vaga (hora ou projeto); vaga sem valor nunca some
  coalesce(v.valor_max < (select p.valor_min_usd from public.perfil p where p.user_id = auth.uid()), false) as abaixo_minimo
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

-- ------------------------------------------------------------------ regras de acesso
-- perfil e habilidades: cada um só os seus
drop policy jean_perfil on public.perfil_termo;
create policy dono_termo on public.perfil_termo for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.perfil enable row level security;
create policy dono_perfil_le on public.perfil for select to authenticated using (user_id = auth.uid());
create policy dono_perfil_edita on public.perfil for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- (perfil novo só nasce pela função convidar, com a chave de serviço)

alter table public.modelo_termo enable row level security;
create policy convidado_le_modelo on public.modelo_termo for select to authenticated using (true);

-- vagas: compartilhadas entre convidados (cadastro fechado ⇒ autenticado = convidado)
drop policy jean_le_coleta on public.coleta;
drop policy jean_le_vaga_bruta on public.vaga_bruta;
drop policy jean_le_vaga on public.vaga;
create policy convidado_le_coleta on public.coleta for select to authenticated using (true);
create policy convidado_le_vaga_bruta on public.vaga_bruta for select to authenticated using (true);
create policy convidado_le_vaga on public.vaga for select to authenticated using (true);

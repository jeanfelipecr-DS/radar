-- 0007 — Filtro por plataforma, salvo no perfil (ver docs/SDD_freelas_br_e_layout.md §9)
--
-- Por que existe: o Jean ainda não consegue mandar proposta na Workana (perfil em análise) e
-- quer tirar a plataforma da lista enquanto isso. A escolha vale no celular e no computador,
-- como o idioma (perfil.idioma_vagas).
--
-- Guarda as plataformas ESCONDIDAS, não as visíveis: assim uma fonte nova que entrar no Radar
-- aparece para todo mundo sem precisar mexer no perfil de ninguém.

alter table public.perfil
  add column fontes_ocultas text[] not null default '{}';

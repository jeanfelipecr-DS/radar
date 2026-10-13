// Coletor do Radar — função do Supabase, chamada de hora em hora pelo pg_cron do próprio banco.
//
// Por que aqui e não no GitHub Actions: o agendador do GitHub é "best-effort" — no repositório
// novo ele pulou os primeiros horários sem rodar nenhuma vez. Dentro do Supabase, quem agenda
// é o banco (pg_cron + pg_net), no mesmo lugar onde a vaga é gravada.
//
// Regra da casa — guardar entrada, calcular saída:
//   vaga_bruta  → o JSON como a fonte mandou; versão nova só quando o conteúdo ESTÁVEL muda
//   vaga        → a vaga organizada, uma linha por (fonte, id_externo)
//   "aberta"    → calculado na view vaga_aberta, nunca gravado (fonte que falha não some da tela)
//
// Segurança: a função não exige JWT; quem chama precisa mandar o cabeçalho x-radar-segredo
// igual ao segredo RADAR_SEGREDO (guardado no cofre do banco para o pg_cron).

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const UA = "Radar/0.2 (+https://jeanfelipecr-ds.github.io/radar/)";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

type Vaga = Record<string, unknown>;
type Par = [Record<string, unknown>, Vaga];

async function http(url: string, tentativas = 3): Promise<string> {
  for (let n = 1; ; n++) {
    try {
      const r = await fetch(url, { headers: { "User-Agent": UA } });
      if (r.status >= 400 && r.status < 500) throw new Error(`GET ${url} -> ${r.status}`);   // erro nosso: não repete
      if (!r.ok) throw Object.assign(new Error(`GET ${url} -> ${r.status}`), { repetir: true });
      return await r.text();
    } catch (e) {
      if (n >= tentativas || !(e as { repetir?: boolean }).repetir && !(e instanceof TypeError)) throw e;
      await new Promise((ok) => setTimeout(ok, 2 ** n * 1000));
    }
  }
}

// Datas da Mercor vêm sem fuso; o banco recebe sempre UTC explícito.
const iso = (v: unknown) => !v ? null : /Z$|[+-]\d\d:\d\d$/.test(String(v)) ? String(v) : String(v) + "Z";
const numero = (v: unknown) => v === null || v === undefined || v === "" || isNaN(Number(v)) ? null : Number(v);

// ------------------------------------------------------------------ Mercor
// Sem API pública: as vagas vêm num JSON (__NEXT_DATA__) dentro da página /explore.
// Toda vaga passa por entrevista em vídeo com IA, falada em inglês → entrevista_falada = true.
// Horas: a Mercor marca "full-time" à parte; nas "hourly"/"part-time", o número de horas é o TETO
// (paga por hora, horas definidas por projeto) — decisão do Jean em 13/10/2026.
const UNIDADE_MERCOR: Record<string, string> = { hourly: "hora", "per-task": "tarefa", "one-time": "projeto", yearly: "ano" };

async function mercor(): Promise<Par[]> {
  const html = await http("https://work.mercor.com/explore");
  const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error("Mercor: __NEXT_DATA__ não encontrado — a página mudou de formato");
  const queries = JSON.parse(m[1]).props.pageProps.dehydratedState.queries as { state: { data: unknown } }[];
  const listings = queries.flatMap((q) => (q.state.data as { listings?: Record<string, unknown>[] })?.listings ?? []);
  if (!listings.length) throw new Error("Mercor: nenhuma vaga no JSON — a página mudou de formato");
  return listings.map((l) => {
    const eleg = new Set([...(l.eligibleLocation as string[] ?? []), ...(l.eligibleResidenceLocation as string[] ?? [])]);
    const ineleg = new Set([...(l.ineligibleLocation as string[] ?? []), ...(l.ineligibleResidenceLocation as string[] ?? [])]);
    return [l, {
      fonte: "mercor", id_externo: l.listingId, titulo: l.title,
      empresa: l.companyBrandVisible ? l.companyName : null,
      url: `https://work.mercor.com/jobs/${l.listingId}`,
      descricao: l.description, area: l.listingDomain, habilidades: [], compromisso: l.commitment,
      tipo: l.commitment === "full-time" ? "integral" : "freela",
      prazo: "dias",
      valor_min: numero(l.rateMin), valor_max: numero(l.rateMax),
      unidade: UNIDADE_MERCOR[l.payRateFrequency as string] ?? null,
      horas_semana: l.hoursPerWeek ?? null,
      entrevista_falada: true,
      aceita_brasil: !ineleg.has("BRA") && (eleg.size === 0 || eleg.has("BRA")),
      publicada_em: iso(l.postedAt ?? l.createdAt),
    }];
  });
}

// ------------------------------------------------------------------ Braintrust
// API pública paginada. O campo de horas é "horas ESPERADAS por semana": 30h ou mais é tempo
// integral na prática → vai para o bloco de mercado (decisão do Jean em 13/10/2026).
const UNIDADE_BRAINTRUST: Record<string, string> = { hourly: "hora", fixed_project: "projeto", fixed_price: "projeto", annual: "ano" };
// Treino de IA começa em dias; "AI" sozinho NÃO entra ("AI Automation Engineer" é projeto de cliente).
const TREINO_IA = /\b(contributor|annotation|annotator|labell?ing|rater|data collection|evaluation|evaluator|benchmark|reviewer|ai trainer|ai training|rlhf)\b/i;
const REGIOES_BRASIL = /anywhere|worldwide|global|latin america|latam|south america|americas\b|brazil|brasil/i;
const HORAS_INTEGRAL = 30;

async function braintrust(): Promise<Par[]> {
  let url: string | null = "https://app.usebraintrust.com/api/jobs/?page=1";
  const saida: Par[] = [];
  while (url) {
    const pagina = JSON.parse(await http(url.replace("http://", "https://")));
    for (const j of pagina.results ?? []) {
      const locais = (j.locations ?? []) as { location?: string; country?: string }[];
      const nomes = locais.map((x) => `${x.location ?? ""} ${x.country ?? ""}`).join(" | ");
      const horas = j.expected_hours_per_week ?? null;
      saida.push([j, {
        fonte: "braintrust", id_externo: String(j.id), titulo: j.title, empresa: j.employer?.name ?? null,
        url: `https://app.usebraintrust.com/jobs/${j.id}/`,
        descricao: null, area: j.role?.name ?? null,
        habilidades: (j.main_skills ?? []).map((s: { name?: string }) => s?.name).filter(Boolean),
        compromisso: j.job_type,
        tipo: j.job_type === "direct_hire" || (horas ?? 0) >= HORAS_INTEGRAL ? "integral" : "freela",
        prazo: TREINO_IA.test(j.title ?? "") ? "dias" : "semanas",
        valor_min: numero(j.budget_minimum_usd), valor_max: numero(j.budget_maximum_usd),
        unidade: UNIDADE_BRAINTRUST[j.payment_type] ?? null,
        horas_semana: horas,
        entrevista_falada: null,   // não sabemos; a etiqueta só aparece quando é certeza
        aceita_brasil: locais.length === 0 || REGIOES_BRASIL.test(nomes),
        publicada_em: iso(j.created),
      }]);
    }
    url = pagina.next ?? null;
  }
  return saida;
}

// ------------------------------------------------------------------ Freelancer.com
// API pública. A busca é por PALAVRA e é solta ("premiere pro" já trouxe "migrar Xero"): por isso
// busca com as habilidades de TODOS os perfis e deixa a nota de encaixe de cada pessoa separar o
// que importa. Orçamento vem em várias moedas, com a cotação para US$ no próprio projeto.
// Projeto por hora com 30h+/semana segue a regra da Braintrust → bloco de mercado.
const POR_BUSCA = 25;
const EM_PARALELO = 4;

// O JSON da Freelancer é quase todo campo nulo (~7 KB/projeto). Guardar sem os nulos não perde
// informação e faz a fonte caber no plano grátis.
function semNulos(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(semNulos);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.entries(v as Record<string, unknown>)
      .filter(([, x]) => x !== null).map(([k, x]) => [k, semNulos(x)]));
  }
  return v;
}

async function freelancer(): Promise<Par[]> {
  const { data, error } = await sb.from("perfil_termo").select("rotulo").eq("tipo", "encaixe");
  if (error) throw error;
  const buscas = [...new Set((data ?? []).map((r) => String(r.rotulo).trim()).filter(Boolean))];
  const porId = new Map<number, Record<string, unknown>>();
  for (let i = 0; i < buscas.length; i += EM_PARALELO) {
    const lote = buscas.slice(i, i + EM_PARALELO).map((termo) => http(
      `https://www.freelancer.com/api/projects/0.1/projects/active/?query=${encodeURIComponent(termo)}` +
      `&limit=${POR_BUSCA}&job_details=true&full_description=true`));
    for (const texto of await Promise.all(lote)) {
      for (const p of JSON.parse(texto).result?.projects ?? []) porId.set(p.id, p);
    }
  }
  return [...porId.values()].filter((p) => !p.local).map((p) => {
    const moeda = p.currency as { exchange_rate?: number } | undefined;
    const taxa = Number(moeda?.exchange_rate) || null;
    const usd = (v: unknown) => v === null || v === undefined || !taxa ? null : Math.round(Number(v) * taxa * 100) / 100;
    const orc = (p.budget ?? {}) as { minimum?: number; maximum?: number };
    const porHora = p.type === "hourly";
    const comp = (p.hourly_project_info as { commitment?: { hours?: number; interval?: string } } | undefined)?.commitment;
    const horas = porHora && comp?.interval === "week" ? comp.hours ?? null : null;
    const jobs = (p.jobs ?? []) as { name?: string; category?: { name?: string } }[];
    return [semNulos(p) as Record<string, unknown>, {
      fonte: "freelancer", id_externo: String(p.id), titulo: p.title, empresa: null,
      url: `https://www.freelancer.com/projects/${p.seo_url}`,
      descricao: p.description ?? p.preview_description ?? null,
      area: jobs[0]?.category?.name ?? null,
      habilidades: jobs.map((j) => j.name).filter(Boolean),
      compromisso: p.type,
      tipo: (horas ?? 0) >= HORAS_INTEGRAL ? "integral" : "freela",
      prazo: "semanas",
      valor_min: usd(orc.minimum), valor_max: usd(orc.maximum),
      unidade: porHora ? "hora" : "projeto",
      horas_semana: horas,
      entrevista_falada: null,
      aceita_brasil: true,          // projeto não-local da Freelancer é aberto a qualquer país
      publicada_em: p.time_submitted ? new Date(Number(p.time_submitted) * 1000).toISOString() : null,
    }];
  });
}

const FONTES: Record<string, () => Promise<Par[]>> = { mercor, braintrust, freelancer };

// ------------------------------------------------------------------ versão bruta
// Contadores que mudam a toda hora sem a vaga mudar ficam FORA do hash — senão cada coleta
// gravaria uma versão nova de quase toda vaga e o plano grátis (500 MB) lotaria em semanas.
const VOLATEIS: Record<string, Set<string>> = {
  mercor: new Set(["recentCandidatesCount", "remainingSlots", "suppliedSlots", "matchQuality", "searchSimilarityScore",
    "userSimilarityScore", "isMostRecent", "isRecommended", "applicationStepsCompleted", "applicationStepsPending", "submittedOn"]),
  braintrust: new Set(["openings_left"]),
  freelancer: new Set(["bid_stats", "time_updated", "time_free_bids_expire"]),
};

// Mesmo texto que o json.dumps(sort_keys=True, ensure_ascii=False) do coletor Python antigo:
// assim as versões já gravadas continuam batendo e a troca de coletor não duplica a base bruta.
function jsonPython(v: unknown): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return Number.isInteger(v) ? String(v) : String(v);
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(jsonPython).join(", ") + "]";
  const o = v as Record<string, unknown>;
  return "{" + Object.keys(o).sort().map((k) => JSON.stringify(k) + ": " + jsonPython(o[k])).join(", ") + "}";
}

// Listas que a fonte devolve em ordem aleatória: ordenadas SÓ para o hash (o payload gravado fica como veio).
// Visto em 13/10/2026: em 25 de 27 "versões novas" da Braintrust, só a ordem de job_skills tinha mudado.
const SEM_ORDEM: Record<string, Set<string>> = { braintrust: new Set(["job_skills"]) };

async function hashEstavel(fonte: string, payload: Record<string, unknown>) {
  const estavel = Object.fromEntries(Object.entries(payload)
    .filter(([k]) => !VOLATEIS[fonte]?.has(k))
    .map(([k, v]) => [k, SEM_ORDEM[fonte]?.has(k) && Array.isArray(v) ? [...v].sort() : v]));
  const dig = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(jsonPython(estavel)));
  return [...new Uint8Array(dig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function emLotes<T>(xs: T[], n = 300): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

async function gravar(fonte: string, pares: Par[]) {
  const { data: c, error: e1 } = await sb.from("coleta").insert({ fonte }).select("id").single();
  if (e1) throw e1;
  const agora = () => new Date().toISOString();
  try {
    const brutas = await Promise.all(pares.map(async ([p, v]) =>
      ({ fonte, id_externo: v.id_externo, hash: await hashEstavel(fonte, p), payload: p })));
    // primeira_vez_em fica de fora de propósito: o default do banco só vale na 1ª inserção
    const vagas = pares.map(([, v]) => ({ ...v, ultima_coleta_id: c.id, ultima_vez_em: agora() }));
    for (const l of emLotes(brutas)) {
      const { error } = await sb.from("vaga_bruta").upsert(l, { onConflict: "fonte,id_externo,hash", ignoreDuplicates: true });
      if (error) throw error;
    }
    for (const l of emLotes(vagas)) {
      const { error } = await sb.from("vaga").upsert(l, { onConflict: "fonte,id_externo" });
      if (error) throw error;
    }
    await sb.from("coleta").update({ ok: true, n_vagas: vagas.length, terminada_em: agora() }).eq("id", c.id);
  } catch (e) {
    await sb.from("coleta").update({ ok: false, erro: String((e as Error).message ?? e).slice(0, 500), terminada_em: agora() }).eq("id", c.id);
    throw e;
  }
}

Deno.serve(async (req) => {
  if (req.headers.get("x-radar-segredo") !== Deno.env.get("RADAR_SEGREDO")) {
    return new Response("não autorizado", { status: 401 });
  }
  const resumo: Record<string, unknown> = {};
  // Falha de uma fonte não impede a outra. Busca e gravação falham de jeitos diferentes:
  // se a BUSCA falha, ainda não existe linha em `coleta` → registra uma com erro (é o que a tela mostra);
  // se a GRAVAÇÃO falha, gravar() já marcou a própria coleta como falha.
  for (const [nome, buscar] of Object.entries(FONTES)) {
    const inicio = Date.now();
    const msg = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 500);
    let pares: Par[];
    try {
      pares = await buscar();
    } catch (e) {
      await sb.from("coleta").insert({ fonte: nome, ok: false, erro: msg(e), terminada_em: new Date().toISOString() });
      resumo[nome] = { erro: "busca: " + msg(e) };
      continue;
    }
    try {
      await gravar(nome, pares);
      const vs = pares.map(([, v]) => v);
      resumo[nome] = { vagas: vs.length, freela: vs.filter((v) => v.tipo === "freela").length,
        aceitam_brasil: vs.filter((v) => v.aceita_brasil).length, segundos: (Date.now() - inicio) / 1000 };
    } catch (e) {
      resumo[nome] = { erro: "gravação: " + msg(e) };
    }
  }
  const falhou = Object.values(resumo).some((r) => (r as { erro?: string }).erro);
  return new Response(JSON.stringify(resumo), { status: falhou ? 500 : 200, headers: { "Content-Type": "application/json" } });
});

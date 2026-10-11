"""Coletor do Radar: busca vagas de freela nas fontes com API e grava no Supabase.

Por que existe: o Jean quer ver as vagas de dados que cabem fora do horário
comercial sem abrir plataforma por plataforma. Este script roda de hora em hora
no GitHub Actions e é a única porta de entrada de vagas no banco.

Regra da casa — guardar entrada, calcular saída:
  - `vaga_bruta` guarda o JSON exatamente como a fonte mandou, uma versão nova
    só quando o conteúdo muda (hash). Nada é reescrito.
  - `vaga` guarda a versão organizada, uma linha por vaga.
  - "Está aberta?" NÃO é gravado: é calculado na view `vaga_aberta` comparando
    a última coleta em que a vaga apareceu com a última coleta boa da fonte.
    Assim, se uma fonte falhar, as vagas dela não somem da tela por engano.

Uso:
  python coletor/coletar.py --seco      # só busca e organiza; grava em saida/
  python coletor/coletar.py             # busca e grava no Supabase
                                        # (precisa SUPABASE_URL e SUPABASE_SERVICE_KEY)
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

UA = "Radar/0.1 (+https://jeanfelipecr-ds.github.io/radar)"


# ---------------------------------------------------------------- HTTP

def http(url, metodo="GET", corpo=None, cabecalhos=None, tentativas=3):
    """GET/POST/PATCH com nova tentativa — fonte instável não pode derrubar a coleta inteira."""
    dados = json.dumps(corpo).encode() if corpo is not None else None
    cab = {"User-Agent": UA, **(cabecalhos or {})}
    if dados is not None:
        cab["Content-Type"] = "application/json"
    for n in range(1, tentativas + 1):
        try:
            req = urllib.request.Request(url, data=dados, headers=cab, method=metodo)
            with urllib.request.urlopen(req, timeout=40) as r:
                texto = r.read().decode("utf-8", errors="replace")
                return texto
        except urllib.error.HTTPError as e:
            # 4xx é erro nosso (payload, permissão): repetir não adianta
            if 400 <= e.code < 500:
                raise RuntimeError(f"{metodo} {url} -> {e.code}: {e.read().decode(errors='replace')[:300]}")
            if n == tentativas:
                raise
        except (urllib.error.URLError, TimeoutError):
            if n == tentativas:
                raise
        time.sleep(2 ** n)


def iso(valor):
    """Datas das fontes vêm sem fuso (Mercor) ou com Z (Braintrust); o banco recebe sempre UTC explícito."""
    if not valor:
        return None
    if valor.endswith("Z") or re.search(r"[+-]\d\d:\d\d$", valor):
        return valor
    return valor + "Z"


def numero(valor):
    try:
        return float(valor) if valor not in (None, "") else None
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- fontes
# Cada fonte devolve uma lista de (payload_bruto, vaga_organizada).

UNIDADE_MERCOR = {"hourly": "hora", "per-task": "tarefa", "one-time": "projeto", "yearly": "ano"}


def mercor():
    """A Mercor não tem API pública: as vagas vêm num JSON (__NEXT_DATA__) dentro da página /explore.

    Toda vaga da Mercor passa por uma entrevista em vídeo com IA, falada em inglês
    (~20 min, uma vez por tipo de vaga) — por isso entrevista_falada = True.
    """
    html = http("https://work.mercor.com/explore")
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        raise RuntimeError("Mercor: __NEXT_DATA__ não encontrado — a página mudou de formato")
    queries = json.loads(m.group(1))["props"]["pageProps"]["dehydratedState"]["queries"]
    listings = [l for q in queries if isinstance(q["state"].get("data"), dict)
                for l in q["state"]["data"].get("listings", [])]
    if not listings:
        raise RuntimeError("Mercor: nenhuma vaga no JSON — a página mudou de formato")

    saida = []
    for l in listings:
        elegiveis = set(l.get("eligibleLocation") or []) | set(l.get("eligibleResidenceLocation") or [])
        inelegiveis = set(l.get("ineligibleLocation") or []) | set(l.get("ineligibleResidenceLocation") or [])
        aceita_brasil = "BRA" not in inelegiveis and (not elegiveis or "BRA" in elegiveis)
        saida.append((l, {
            "fonte": "mercor",
            "id_externo": l["listingId"],
            "titulo": l.get("title"),
            "empresa": l.get("companyName") if l.get("companyBrandVisible") else None,
            "url": f"https://work.mercor.com/jobs/{l['listingId']}",
            "descricao": l.get("description"),
            "area": l.get("listingDomain"),
            "habilidades": [],
            "compromisso": l.get("commitment"),
            # contrato de 40h/semana não cabe fora do horário comercial: vai pro bloco de mercado
            "tipo": "integral" if l.get("commitment") == "full-time" else "freela",
            "prazo": "dias",
            "valor_min": numero(l.get("rateMin")),
            "valor_max": numero(l.get("rateMax")),
            "unidade": UNIDADE_MERCOR.get(l.get("payRateFrequency")),
            "horas_semana": l.get("hoursPerWeek"),
            "entrevista_falada": True,
            "aceita_brasil": aceita_brasil,
            "publicada_em": iso(l.get("postedAt") or l.get("createdAt")),
        }))
    return saida


UNIDADE_BRAINTRUST = {"hourly": "hora", "fixed_project": "projeto", "fixed_price": "projeto", "annual": "ano"}
# Trabalho de treino de IA começa em dias (sem cliente nem proposta); o resto é projeto com cliente.
# "AI" sozinho NÃO entra: "AI Automation Engineer" é projeto de cliente, não treino de modelo.
TREINO_IA = re.compile(r"\b(contributor|annotation|annotator|labell?ing|rater|data collection|evaluation|"
                       r"evaluator|benchmark|reviewer|ai trainer|ai training|rlhf)\b", re.I)
# Regiões que incluem o Brasil no filtro de localização da Braintrust.
REGIOES_BRASIL = re.compile(r"anywhere|worldwide|global|latin america|latam|south america|americas\b|brazil|brasil", re.I)


def braintrust():
    """API pública e paginada da Braintrust (sem chave)."""
    url, saida = "https://app.usebraintrust.com/api/jobs/?page=1", []
    while url:
        pagina = json.loads(http(url.replace("http://", "https://")))
        for j in pagina.get("results", []):
            locais = j.get("locations") or []
            nomes = " | ".join(f"{x.get('location') or ''} {x.get('country') or ''}" for x in locais)
            aceita_brasil = True if not locais else bool(REGIOES_BRASIL.search(nomes))
            habilidades = [s.get("name") for s in (j.get("main_skills") or []) if isinstance(s, dict)]
            saida.append((j, {
                "fonte": "braintrust",
                "id_externo": str(j["id"]),
                "titulo": j.get("title"),
                "empresa": (j.get("employer") or {}).get("name"),
                "url": f"https://app.usebraintrust.com/jobs/{j['id']}/",
                "descricao": None,  # a listagem não traz descrição; o detalhe abre no link
                "area": (j.get("role") or {}).get("name"),
                "habilidades": habilidades,
                "compromisso": j.get("job_type"),
                "tipo": "integral" if j.get("job_type") == "direct_hire" else "freela",
                "prazo": "dias" if TREINO_IA.search(j.get("title") or "") else "semanas",
                "valor_min": numero(j.get("budget_minimum_usd")),
                "valor_max": numero(j.get("budget_maximum_usd")),
                "unidade": UNIDADE_BRAINTRUST.get(j.get("payment_type")),
                "horas_semana": j.get("expected_hours_per_week"),
                "entrevista_falada": None,  # não sabemos; a etiqueta só aparece quando é certeza
                "aceita_brasil": aceita_brasil,
                "publicada_em": iso(j.get("created")),
            }))
        url = pagina.get("next")
    return saida


FONTES = {"mercor": mercor, "braintrust": braintrust}


# ---------------------------------------------------------------- Supabase (PostgREST)

class Banco:
    def __init__(self):
        self.base = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1"
        chave = os.environ["SUPABASE_SERVICE_KEY"]
        self.cab = {"apikey": chave, "Authorization": f"Bearer {chave}"}

    def inserir(self, tabela, linhas, conflito=None, ao_conflitar="merge-duplicates", devolver=False):
        url = f"{self.base}/{tabela}" + (f"?on_conflict={conflito}" if conflito else "")
        prefer = [f"return={'representation' if devolver else 'minimal'}"]
        if conflito:
            prefer.append(f"resolution={ao_conflitar}")
        resposta = http(url, "POST", linhas, {**self.cab, "Prefer": ",".join(prefer)})
        return json.loads(resposta) if devolver else None

    def atualizar(self, tabela, filtro, valores):
        http(f"{self.base}/{tabela}?{filtro}", "PATCH", valores, {**self.cab, "Prefer": "return=minimal"})


# Contadores que mudam a toda hora sem a vaga mudar. Ficam FORA do hash: se entrassem, cada coleta
# gravaria uma versão bruta nova de quase toda vaga e o plano grátis (500 MB) lotaria em semanas.
# O payload completo continua sendo gravado quando a versão é nova.
VOLATEIS = {
    "mercor": {"recentCandidatesCount", "remainingSlots", "suppliedSlots", "matchQuality",
               "searchSimilarityScore", "userSimilarityScore", "isMostRecent", "isRecommended",
               "applicationStepsCompleted", "applicationStepsPending", "submittedOn"},
    "braintrust": {"openings_left"},
}


def hash_estavel(fonte, payload):
    estavel = {k: v for k, v in payload.items() if k not in VOLATEIS.get(fonte, set())}
    return hashlib.sha256(json.dumps(estavel, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def em_lotes(linhas, tamanho=300):
    for i in range(0, len(linhas), tamanho):
        yield linhas[i:i + tamanho]


def gravar(banco, fonte, pares):
    coleta_id = banco.inserir("coleta", [{"fonte": fonte}], devolver=True)[0]["id"]
    try:
        brutas, vagas = [], []
        for payload, vaga in pares:
            brutas.append({"fonte": fonte, "id_externo": vaga["id_externo"],
                           "hash": hash_estavel(fonte, payload), "payload": payload})
            # primeira_vez_em fica de fora de propósito: o default do banco só vale na 1ª inserção
            vagas.append({**vaga, "ultima_coleta_id": coleta_id,
                          "ultima_vez_em": datetime.now(timezone.utc).isoformat()})
        for lote in em_lotes(brutas):
            banco.inserir("vaga_bruta", lote, conflito="fonte,id_externo,hash", ao_conflitar="ignore-duplicates")
        for lote in em_lotes(vagas):
            banco.inserir("vaga", lote, conflito="fonte,id_externo")
        banco.atualizar("coleta", f"id=eq.{coleta_id}",
                        {"ok": True, "n_vagas": len(vagas), "terminada_em": datetime.now(timezone.utc).isoformat()})
    except Exception as e:
        banco.atualizar("coleta", f"id=eq.{coleta_id}",
                        {"ok": False, "erro": str(e)[:500], "terminada_em": datetime.now(timezone.utc).isoformat()})
        raise


def registrar_falha(banco, fonte, erro):
    banco.inserir("coleta", [{"fonte": fonte, "ok": False, "erro": str(erro)[:500],
                              "terminada_em": datetime.now(timezone.utc).isoformat()}])


# ---------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--seco", action="store_true", help="não grava no banco; salva o resultado em saida/")
    p.add_argument("--fonte", choices=sorted(FONTES), action="append", help="rodar só esta fonte (repetível)")
    args = p.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # console do Windows não é UTF-8 por padrão
    sys.stderr.reconfigure(encoding="utf-8")

    banco = None if args.seco else Banco()
    falhas = []
    for nome in args.fonte or FONTES:
        inicio = time.time()
        try:
            pares = FONTES[nome]()
        except Exception as e:
            falhas.append(nome)
            print(f"[{nome}] FALHOU ao buscar: {e}", file=sys.stderr)
            if banco:
                registrar_falha(banco, nome, e)
            continue

        vagas = [v for _, v in pares]
        n_freela = sum(1 for v in vagas if v["tipo"] == "freela")
        n_br = sum(1 for v in vagas if v["aceita_brasil"])
        print(f"[{nome}] {len(vagas)} vagas · {n_freela} freela · {n_br} aceitam Brasil · {time.time() - inicio:.1f}s")

        if banco:
            try:
                gravar(banco, nome, pares)
            except Exception as e:
                falhas.append(nome)
                print(f"[{nome}] FALHOU ao gravar: {e}", file=sys.stderr)
        else:
            os.makedirs("saida", exist_ok=True)
            with open(f"saida/{nome}.json", "w", encoding="utf-8") as f:
                json.dump(vagas, f, ensure_ascii=False, indent=1)

    # Falha de uma fonte não impede as outras, mas o job fica vermelho no GitHub pra ser visto.
    sys.exit(1 if falhas else 0)


if __name__ == "__main__":
    main()

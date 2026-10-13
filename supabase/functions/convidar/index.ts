// Convites do Radar — chamada pela tela Configurar, só funciona para o dono (o Jean).
//
// Por que é uma função e não a tela direto: criar conta e trocar senha de outra pessoa exige a
// chave de serviço, que NUNCA pode ir para o navegador. A tela manda o token de login; aqui o
// token é conferido no servidor de autenticação e só o e-mail do dono passa.
//
// Ações (corpo JSON):
//   { acao: "listar" }                          → convidados (e-mail, modelo, último acesso)
//   { acao: "criar", email, modelo }            → conta confirmada + senha provisória + perfil do modelo
//   { acao: "nova_senha", user_id }             → senha provisória nova (o plano grátis não manda e-mail de redefinição)

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const DONO = "jeanfelipecr@gmail.com";
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// Senha provisória fácil de ditar/copiar no WhatsApp: sem 0/O/1/l, 3 blocos de 4.
function senhaProvisoria() {
  const letras = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const s = [...bytes].map((b) => letras[b % letras.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: quem } = await admin.auth.getUser(token);
  if (quem?.user?.email !== DONO) return resposta({ erro: "só o dono do Radar pode convidar" }, 403);

  let corpo: { acao?: string; email?: string; modelo?: string; user_id?: string };
  try { corpo = await req.json(); } catch { return resposta({ erro: "corpo inválido" }, 400); }

  if (corpo.acao === "listar") {
    const { data, error } = await admin.auth.admin.listUsers({ perPage: 200 });
    if (error) return resposta({ erro: error.message }, 500);
    const { data: perfis } = await admin.from("perfil").select("user_id, modelo, nome");
    const porId = new Map((perfis ?? []).map((p) => [p.user_id, p]));
    const convidados = data.users
      .filter((u) => u.email !== DONO)
      .map((u) => ({ user_id: u.id, email: u.email, modelo: porId.get(u.id)?.modelo ?? null,
        ultimo_acesso: u.last_sign_in_at, criado_em: u.created_at }))
      .sort((a, b) => String(b.criado_em).localeCompare(String(a.criado_em)));
    return resposta({ convidados });
  }

  if (corpo.acao === "criar") {
    const email = String(corpo.email ?? "").trim().toLowerCase();
    const modelo = corpo.modelo === "video" ? "video" : corpo.modelo === "dados" ? "dados" : null;
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return resposta({ erro: "e-mail inválido" }, 400);
    if (!modelo) return resposta({ erro: "modelo precisa ser 'video' ou 'dados'" }, 400);
    const senha = senhaProvisoria();
    const { data: novo, error } = await admin.auth.admin.createUser({ email, password: senha, email_confirm: true });
    if (error) return resposta({ erro: /already|registered|exists/i.test(error.message) ? "esse e-mail já tem acesso — use 'gerar nova senha'" : error.message }, 400);
    const uid = novo.user.id;
    // perfil + habilidades do modelo; se algo falhar, desfaz a conta para não sobrar convidado pela metade
    const { data: termos } = await admin.from("modelo_termo").select("termo, rotulo, peso, tipo").eq("modelo", modelo);
    const e1 = (await admin.from("perfil").insert({ user_id: uid, nome: email.split("@")[0], modelo })).error;
    const e2 = e1 ? null : (await admin.from("perfil_termo").insert((termos ?? []).map((t) => ({ ...t, user_id: uid })))).error;
    if (e1 || e2) {
      await admin.auth.admin.deleteUser(uid);
      return resposta({ erro: "não consegui montar o perfil: " + (e1 ?? e2)!.message }, 500);
    }
    return resposta({ user_id: uid, email, modelo, senha });
  }

  if (corpo.acao === "nova_senha") {
    if (!corpo.user_id) return resposta({ erro: "falta user_id" }, 400);
    const { data: alvo } = await admin.auth.admin.getUserById(corpo.user_id);
    if (!alvo?.user || alvo.user.email === DONO) return resposta({ erro: "convidado não encontrado" }, 404);
    const senha = senhaProvisoria();
    const { error } = await admin.auth.admin.updateUserById(corpo.user_id, { password: senha });
    if (error) return resposta({ erro: error.message }, 500);
    return resposta({ email: alvo.user.email, senha });
  }

  return resposta({ erro: "ação desconhecida" }, 400);
});

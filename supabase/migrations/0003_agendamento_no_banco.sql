-- 0003 — O agendamento da coleta mora no banco (pg_cron + pg_net)
--
-- Por que existe: o agendador do GitHub Actions é "best-effort". No repositório novo ele perdeu
-- os primeiros horários sem rodar nenhuma vez. Agora quem chama a função `coletar` (Supabase
-- Edge Function) de hora em hora é o próprio banco — no mesmo lugar onde a vaga é gravada.
--
-- Segurança: a função não exige JWT; ela confere o cabeçalho x-radar-segredo. O valor fica no
-- COFRE do banco (vault), com o nome 'radar_segredo', e é lido na hora da chamada.
-- Armadilha: este arquivo é público — o segredo NUNCA entra aqui. Ele é criado à parte, uma vez:
--   select vault.create_secret('<valor>', 'radar_segredo', 'cabeçalho x-radar-segredo da função coletar');
-- e o mesmo valor vai nos segredos da função (RADAR_SEGREDO).
--
-- Conferir se rodou: select * from cron.job_run_details order by start_time desc limit 5;
--                    select status_code, created from net._http_response order by created desc limit 5;
-- (a tela do Radar também mostra "última busca há X" e fica laranja se passar de 2h30)

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'radar-coletar',
  '17 * * * *',                       -- de hora em hora, fora do minuto 0
  $$
  select net.http_post(
    url := 'https://kagwnqkhatulpswqigzm.supabase.co/functions/v1/coletar',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-radar-segredo', (select decrypted_secret from vault.decrypted_secrets where name = 'radar_segredo')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000    -- a coleta leva ~10 s; folga para a Braintrust lenta
  );
  $$
);

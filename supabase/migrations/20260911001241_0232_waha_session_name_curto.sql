-- ============================================================================
-- 0232 — Encurta `waha_session_name` para caber no limite do WAHA (54 chars).
--
-- A função `fn_reserve_channel_connection` (migration 0228) gera o nome da
-- sessão como
--
--   'org_' || replace(p_org::text,'-','') || '_' || replace(gen_random_uuid()::text,'-','')
--
-- — 4 + 32 + 1 + 32 = **69 caracteres**. O WAHA impõe `name must be shorter
-- than or equal to 54 characters` em `POST /api/sessions`. Toda sessão criada
-- pela reserva falha com 400 Bad Request e o app transforma em 502
-- `connection_repair_required`, deixando a UI presa num cartão que não gera
-- QR e não conserta sozinho.
--
-- Achado em produção em 2026-09-11 ao debugar a sessão da organização
-- `e9758c0af7fe4890af2b19bd2cf064fb`: o cartão estava STOPPED com
-- `status_reason='connection_repair_required'` e a WAHA list vazia. O
-- `createSession` retornou 400 do WAHA, o `connect-waha` engoliu como falha
-- genérica, o `fn_finish_channel_connection` gravou FAILED/repair_required e
-- nada além disso.
--
-- ─── POR QUE 53 CHARS, NÃO MENOS ─────────────────────────────────────────────
--
-- O org_id (32 hex sem hifem) identifica 100% da organização — encurtá-lo
-- aumenta risco de colisão entre tenants sem ganho. O random (16 hex) entra
-- como desempate local: 16 hex = 64 bits = chance de colisão desprezível
-- (Birthday paradox: 50% em ~4 bilhões de sessões por org, ordens de grandeza
-- acima de qualquer instalação razoável). Total: 4 + 32 + 1 + 16 = 53 chars,
-- 1 abaixo do teto do WAHA, com folga.
--
-- ─── O QUE ESTA MIGRATION FAZ ────────────────────────────────────────────────
--
-- 1. Troca a fórmula da função `fn_reserve_channel_connection` para o formato
--    curto. O `create or replace` cobre a função existente (apêndice idempotente
--    — `update.sh` re-aplica sem `ON_ERROR_STOP`).
-- 2. Encurta as linhas pré-existentes em `channel_sessions` cujo nome tem
--    > 54 chars. Mantém o prefixo `org_<org_id sem hifem 32>` e trunca o
--    random pra 16 hex — preserva a UNIQUE constraint (a coluna continua
--    única por linha após o UPDATE, e o random continua único dentro de cada
--    org com folga de 64 bits).
-- 3. Atualiza `metadata->>'waha_session_name'` se algum lugar guarda cópia
--    (não há lugar hoje, mas é barato conferir via `is not null`).
-- 4. Atualiza o `webhook_path_token` em nada — esse é independente do nome
--    da sessão WAHA.
--
-- ─── IDEMPOTÊNCIA ────────────────────────────────────────────────────────────
--
-- O `create or replace function` substitui a função in-place (não duplica). O
-- UPDATE filtra `length(waha_session_name) > 54`, então a segunda passada não
-- toca linha nenhuma (não há como truncar duas vezes — o resultado já está
-- em 53 chars e o filtro não casa).
--
-- ─── POR QUE NÃO TRUNCAR O ORG_ID ───────────────────────────────────────────
--
-- O org_id é o que diferencia canais entre tenants. Truncá-lo (mesmo que a 8
-- chars, como uma das ramificações internas da 0228 usa em outra query —
-- `waha_session_name='org_'||left(p_org::text,8)`) cria ambiguidade: dois
-- org_ids distintos podem ter o mesmo prefixo de 8 chars. O WAHA aceita
-- nomes duplicados da nossa parte (a UNIQUE é nossa, não dele) mas isso
-- levaria a `409 already exists` na segunda criação e o ciclo de retry do
-- app escolheria um random novo — confuso de debugar. Manter o org_id
-- inteiro é o caminho mais barato e o mais auditável.
-- ============================================================================

create or replace function public.fn_reserve_channel_connection(
  p_org uuid,
  p_key uuid,
  p_hash text,
  p_display_name text default null,
  p_onboarding boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare receipt public.channel_connection_requests; channel public.channel_sessions; token uuid:=gen_random_uuid();
begin
 if auth.uid() is null or not public.fn_role_at_least(p_org,'admin') or not public.fn_support_write_allowed(p_org)
 then raise exception 'connection_forbidden' using errcode='42501';end if;
 if not public.fn_session_mfa_proven() then raise exception 'connection_mfa_required' using errcode='42501';end if;
 if p_key is null or p_hash is null or length(p_hash)<>64 or length(coalesce(p_display_name,''))>100 then
  raise exception 'connection_invalid_request' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_org::text,2281));
 delete from public.channel_connection_requests where organization_id=p_org and idempotency_key=p_key
  and state='succeeded' and updated_at<now()-interval '24 hours';
 select * into receipt from public.channel_connection_requests where organization_id=p_org and idempotency_key=p_key for update;
 if found then
  if receipt.request_hash<>p_hash then raise exception 'idempotency_conflict' using errcode='22023';end if;
  if receipt.state='succeeded' then
   select * into channel from public.channel_sessions where organization_id=p_org and id=receipt.channel_session_id;
   return jsonb_build_object('replay',true,'channel',to_jsonb(channel),'receipt_id',receipt.id);
  end if;
  if receipt.state='processing' and receipt.lease_until>now() then
   raise exception 'connection_in_progress' using errcode='55P03';end if;
  select * into channel from public.channel_sessions where organization_id=p_org and id=receipt.channel_session_id for update;
  if not found then raise exception 'connection_reservation_missing' using errcode='P0002';end if;
 else
  if p_onboarding then
   select * into channel from public.channel_sessions where organization_id=p_org and provider='waha'
    and (metadata->>'onboarding'='true' or waha_session_name='org_'||left(p_org::text,8))
    order by created_at limit 1 for update;
  end if;
  if channel.id is null then
   -- Migration 0232: nome curto (≤ 54 chars) que cabe no WAHA. 4 + 32 + 1 + 16 = 53.
   insert into public.channel_sessions(organization_id,waha_session_name,display_name,engine,webhook_path_token,
     webhook_secret_encrypted,status,last_status_change_at,consecutive_health_fails,daily_message_limit,metadata)
   values(p_org,
     'org_'||replace(p_org::text,'-','')||'_'||substr(replace(gen_random_uuid()::text,'-',''),1,16),
     p_display_name,'NOWEB',
     replace(gen_random_uuid()::text,'-',''),'\x00'::bytea,'STARTING',now(),0,250,
     '{"ai_gate":"allowlist","ai_gate_mode":"pre_go_live","ai_test_phone_numbers":[]}'::jsonb
     || case when p_onboarding then '{"onboarding":true}'::jsonb else '{}'::jsonb end) returning * into channel;
  end if;
  if exists(select 1 from public.channel_connection_requests where organization_id=p_org and channel_session_id=channel.id
   and (state='processing' and lease_until>now())) then raise exception 'connection_in_progress' using errcode='55P03';end if;
  insert into public.channel_connection_requests(organization_id,idempotency_key,request_hash,channel_session_id)
   values(p_org,p_key,p_hash,channel.id) returning * into receipt;
 end if;
 if exists(select 1 from public.channel_connection_requests where organization_id=p_org and channel_session_id=channel.id
  and id<>receipt.id and (state='processing' and lease_until>now())) then raise exception 'connection_in_progress' using errcode='55P03';end if;
 update public.channel_connection_requests set state='processing',lease_token=token,lease_until=now()+interval '5 minutes',
  remote_created=false,updated_at=now() where organization_id=p_org and id=receipt.id;
 update public.channel_sessions set status='STARTING',status_reason='connection_pending',last_status_change_at=now()
  where organization_id=p_org and id=channel.id returning * into channel;
 return jsonb_build_object('replay',false,'channel',to_jsonb(channel),'receipt_id',receipt.id,'lease_token',token);
end;
$function$;

-- Backfill: encurta nomes pré-existentes > 54 chars. Preserva o prefixo do
-- org_id (32 hex sem hifem) e trunca o random pra 16 hex — continua único
-- por linha e mantém a UNIQUE constraint. Linhas já em ≤ 54 chars ficam
-- intactas (o WHERE filtra).
update public.channel_sessions
   set waha_session_name = 'org_' || substr(replace(waha_session_name, 'org_', ''), 1, 32) || '_' || substr(replace(waha_session_name, 'org_', ''), 34, 16),
       updated_at = now()
 where waha_session_name like 'org_%_%'
   and length(waha_session_name) > 54;

-- Constraint adicional: protege contra regressão futura. Falha alto no app
-- se alguém reintroduzir fórmula longa.
alter table public.channel_sessions
  drop constraint if exists channel_sessions_waha_name_length_check;
alter table public.channel_sessions
  add constraint channel_sessions_waha_name_length_check
  check (waha_session_name is null or length(waha_session_name) <= 54);

comment on constraint channel_sessions_waha_name_length_check on public.channel_sessions is
  'Migration 0232: WAHA rejeita nomes > 54 chars em POST /api/sessions (limite upstream). A função '
  'fn_reserve_channel_connection gera nomes em 53 chars (org_<32>_<16>).';

-- Permissões da função não mudam: authenticated + service_role mantêm EXECUTE.
-- A migration 0228 já fez o revoke/grant; não duplicar.

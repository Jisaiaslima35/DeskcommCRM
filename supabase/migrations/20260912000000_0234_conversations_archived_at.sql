-- ============================================================================
-- 0234 — `conversations.archived_at`: timestamp da última vez que a conversa
--        foi marcada como `status='archived'`.
--
-- ─── CONTEXTO ───────────────────────────────────────────────────────────────
--
-- Isaías precisa iterar prompt de agente sem perder tempo: mudar o
-- `system_prompt` da versão publicada e testar do WhatsApp, repetidas vezes.
-- O problema: a conversa ativa por (contact_id, channel_session_id) é uma só
-- (`uniq_conversations_1to1_per_contact_session`), e o LLM sempre vê o
-- histórico empilhado — então uma resposta anterior contamina o teste do
-- novo prompt.
--
-- A coluna `status` já aceita 'archived' (CHECK desde a 0009); faltava o
-- carimbo de tempo para distinguir "sempre arquivada" de "agora arquivada".
--
-- ─── O QUE ESSE PRIMEIRO CAMPO RESOLVE ─────────────────────────────────────
--
-- A) Endpoint `POST /api/v1/conversations/[id]/reset` faz
--    `UPDATE conversations SET status='archived', archived_at=now() WHERE
--    id=$1 AND organization_id=$2`. Soft delete: nada de messages é apagado,
--    nada de contact, nada de RAG index. Próxima msg vinda do WhatsApp cai em
--    `fn_upsert_wa_conversation` (0027), que cria uma NOVA `conversations`
--    (a UNIQUE 1:1 não acha a antiga porque `status='archived'` é excluído
--    do índice parcial — ver migration 0027, `WHERE status NOT IN
--    ('closed','archived')`), e o histórico começa do zero, já com o
--    `active_ai_agent_version_id` da versão publicada vigente.
--
-- B) `WHERE status='archived' AND archived_at > now() - 90 days` no
--    `messages_select` (futuro): RAG não ingere conversa arquivada
--    recente. Por enquanto não mudamos RLS — Isaías pediu reset pra TESTE,
--    não pra apagar histórico.
--
-- ─── POR QUE NÃO RECRIAR A CONVERSA ────────────────────────────────────────
--
-- A versão pública do agente é ponteiro (`ai_agent_versions`), e a
-- `conversations` carrega `active_ai_agent_version_id` por FK. Mudar o
-- prompt = publicar nova versão = o ponteiro PUBLISHED muda, MAS a linha da
-- conversa mantém o `active_ai_agent_version_id` que tinha no momento da
-- criação (resolve-turn-agent.ts:261 lê DE conversations, NÃO de
-- ai_agents.published_version_id). Por isso o reset soft delete é o caminho
-- mais simples: nova conversa → nova leitura do ponteiro publicado atual →
-- agente novo, histórico limpo.
--
-- ─── IDEMPOTÊNCIA ───────────────────────────────────────────────────────────
--
-- `add column if not exists archived_at ...` cobre (a) install fresh, (b)
-- update de clone já com colunas legadas, (c) re-aplicação do `update.sh`.
-- A coluna é nullable: linhas pré-existentes ficam NULL, e o invariante é
-- "NULL = nunca arquivada explicitamente, distinto de 'arquivada pelo seed'".
--
-- O índice parcial só conta conversas realmente arquivadas — o scan do
-- inbox ignora-as, e qualquer query "mostre-me as últimas arquivadas" fica
-- O(1) sem inflar o `conversations_*_perf` da 0009.
-- ============================================================================

alter table public.conversations
  add column if not exists archived_at timestamp with time zone;

create index if not exists idx_conversations_org_archived_at
  on public.conversations (organization_id, archived_at desc)
  where status = 'archived';

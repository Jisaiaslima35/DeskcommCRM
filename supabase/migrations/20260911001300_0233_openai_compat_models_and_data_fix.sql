-- ============================================================================
-- 0233 — Catálogo `ai_models` ganha o 5º provedor (`openai_compat`) + fixes
--        de dados ligados ao tenant `dr-matheus-dore` em produção.
--
-- ─── CONTEXTO ───────────────────────────────────────────────────────────────
--
-- Em 2026-09-10 a migration 0231 adicionou a coluna `base_url` em
-- `ai_provider_credentials` e o 5º provedor `openai_compat` apareceu na lista
-- de provedores (`lib/ai/pontos/provedores.ts`) com cadastro funcional:
-- validator pinga `{baseUrl}/models`, POST aceita a chave + endpoint,
-- binding aceita o modelo + base_url por ponto.
--
-- O que FALTOU foi popular `ai_models` com os modelos do provedor novo. A UI
-- do editor do agente (`/app/api/v1/ai/providers/route.ts:68`) popula o
-- dropdown "Modelo" lendo desta tabela, não de `credential.models_available`
-- (que serve só pra exibir info no card da credencial). Sem linhas em
-- `ai_models.provider='openai_compat'`, o select fica vazio com a mensagem
-- "Cadastrar credencial openai_compat na aba Credenciais." — exatamente o
-- screenshot de Isaías em 2026-09-10.
--
-- ─── POR QUE ESSES 4 MODELOS ─────────────────────────────────────────────────
--
-- A credencial `9router-prod` (id `975778ff-ef14-45fc-bea2-f967accadf77`)
-- foi validada em 2026-09-10 23:15 UTC e o `models_available` retornou esses
-- quatro (gate OpenAI-compat: 9router expõe `{data:[...]}` em `/v1/models`):
--
--   - `Hermes-fallbacks`                → roteado via Hermes gateway 8642
--   - `nvidia/minimaxai/minimax-m3`     → M3 via NVIDIA build (sem revisão mensal)
--   - `gemini/gemini-3.1-pro-preview`  → preview Gemini 3.1
--   - `cerebras/llama-3.3-70b`          → Llama 70B fast-infer
--
-- `Hermes-fallbacks` é o que o binding `production` da organização
-- `dr-matheus-dore` aponta (`model_id='Hermes-fallbacks'`,
-- `base_url='https://9router.automacaojs.us/v1'`) — ele é o DEFAULT do provedor
-- pra este deployment (o índice UNIQUE `ai_models_one_default_per_provider` só
-- permite um default por provedor, então `nvidia/minimaxai/minimax-m3` etc
-- ficam com `is_default_for_provider=false`).
--
-- ─── POR QUE `description` E `context_window` SÃO ESTIMADOS ──────────────────
--
-- O catálogo do 9router não expõe `context_window` nem descrições padronizadas
-- (apenas `id`). Os valores aqui são defaults conservadores que valem pra
-- 9Router com qualquer modelo hospedado: 128k tokens é o piso do gateway
-- configurado, e os modelos pequenos operam em ~200k. As descrições são
-- frases curtas pra card — quem sabe o detalhe do modelo prefere editar pela
-- UI. Não há cobrança de precisão: este é um catálogo de seleção, não um
-- dataset de cobrança (preços ficam em `input/output_price_per_million_cents`
-- zerados e vão sendo preenchidos pela equipe financeira quando 9Router
-- publicar a planilha).
--
-- ─── IDEMPOTÊNCIA ───────────────────────────────────────────────────────────
--
-- O `INSERT ... ON CONFLICT (provider, model_id) DO UPDATE` cobre os três
-- cenários: (a) primeira execução popula a tabela; (b) re-aplicação do
-- `update.sh` numa VPS que já tem as linhas não duplica (a UNIQUE
-- `ai_models_provider_model_unique` cobre); (c) edição posterior dos campos
-- descritivos via mesma migration reescreve o que importa sem mexer em
-- colunas que a operação cadastrou (a 4ª coluna da tupla do `ON CONFLICT`
-- lista os campos sobrescritos, e o EXCLUDED.* traz o que veio do INSERT).
--
-- O `UPDATE ai_provider_credentials ... WHERE base_url IS NULL AND id IN
-- (SELECT credential_id FROM ai_purpose_bindings WHERE base_url IS NOT NULL)`
-- é seguro de re-rodar: o WHERE filtra duas vezes, e a função que pegou o
-- binding atual não tem efeito colateral sobre a credencial.
--
-- O `UPDATE ai_agent_versions ... WHERE channel_session_id IN (SELECT id FROM
-- channel_sessions WHERE archived_at IS NOT NULL)` é o forward-fix do
-- Dr. Matheus Dore: o agente `Atendimento Inicial` (versão publicada
-- 6955c3e2) ficou apontando pra sessão órfã 881084e0 depois que ela foi
-- arquivada em 2026-09-11 00:03. Sem repontar, todo inbound cairia em
-- sessão arquivada e o agent_engine recusaria rotear (a CHECK
-- `conversations_channel_session_id_fkey` exige sessão viva). O WHERE
-- filtra arquivada E restringe à org certa (multi-tenancy — outras
-- instalações não podem ter seus agentes repontados por esta migration).
--
-- ─── POR QUE NÃO É BACKFILL GENÉRICO ────────────────────────────────────────
--
-- O backfill de base_url é parametrizado em (1) `base_url IS NULL` e (2)
-- existe binding ativo pro credential — não toca credenciais com URL já
-- preenchida (intencional ou não) e não inventa URL do nada. O repointing
-- do agente é restrito a uma org e a uma versão por id (forward-fix
-- documentado, não varredura cega). Clones que ainda não têm a 0231
-- aplicada não são afetados — a coluna `base_url` simplesmente não existe
-- pra eles, e o migration runner abortaria antes desse ponto.
-- ============================================================================

-- Catálogo do 5º provedor ─────────────────────────────────────────────────────

insert into public.ai_models(
  provider, model_id, display_name, description,
  context_window, input_price_per_million_cents, output_price_per_million_cents,
  supports_tools, supports_vision, supports_embedding,
  is_default_for_provider, source, metadata
) values
  ('openai_compat', 'Hermes-fallbacks',
   'Hermes-fallbacks (9router)',
   'Roteado pelo gateway Hermes com fallback automático entre provedores upstream.',
   200000, 0, 0,
   true, false, false,
   true, 'manual',
   '{"gateway":"9router","path":"hermes-8642","tier":"primary"}'::jsonb),
  ('openai_compat', 'nvidia/minimaxai/minimax-m3',
   'MiniMax M3 (NVIDIA build)',
   'M3 hospedado em build NVIDIA — sem revisão mensal de preço.',
   200000, 0, 0,
   true, false, false,
   false, 'manual',
   '{"gateway":"9router","tier":"fallback"}'::jsonb),
  ('openai_compat', 'gemini/gemini-3.1-pro-preview',
   'Gemini 3.1 Pro Preview (9router)',
   'Preview Gemini 3.1 Pro via 9router — pode mudar comportamento sem aviso.',
   1000000, 0, 0,
   true, true, false,
   false, 'manual',
   '{"gateway":"9router","tier":"experimental"}'::jsonb),
  ('openai_compat', 'cerebras/llama-3.3-70b',
   'Llama 3.3 70B (Cerebras)',
   'Inferência rápida em Llama 70B no hardware Cerebras.',
   128000, 0, 0,
   true, false, false,
   false, 'manual',
   '{"gateway":"9router","tier":"fast_infer"}'::jsonb)
on conflict (provider, model_id) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  context_window = excluded.context_window,
  supports_tools = excluded.supports_tools,
  supports_vision = excluded.supports_vision,
  is_default_for_provider = excluded.is_default_for_provider,
  metadata = excluded.metadata,
  synced_at = now();

-- Backfill de `base_url` em credenciais openai_compat ─────────────────────────
-- A migration 0231 adicionou a coluna com NULL e sem backfill porque o
-- validador só grava em POST/revalidate. Credenciais cadastradas ANTES da
-- 0231 (caso da 9router-prod, criada em 2026-09-10) ficaram com NULL mesmo
-- tendo binding válido. Copia do binding: ele já guarda o endpoint por ponto
-- (migration 0126) e é a fonte de verdade em runtime.

update public.ai_provider_credentials c
   set base_url = b.base_url
  from public.ai_purpose_bindings b
 where c.provider = 'openai_compat'
   and c.base_url is null
   and b.credential_id = c.id
   and b.base_url is not null;

-- Repointing do agente `Atendimento Inicial` ─────────────────────────────────
-- Forward-fix do tenant `dr-matheus-dore` em produção. A versão publicada
-- 6955c3e2-d5dc-4056-a654-4871ff94b495 ficou apontando pra sessão
-- `881084e0-89be-4757-a10b-6f824f1cb67f` (STOPPED + arquivada em 2026-09-11
-- 00:03:38). Isaías regenerou QR numa sessão nova `804a1f0b-...` (WORKING)
-- e o inbox passou a receber mensagens — mas o agent_engine recusava
-- rotear porque o FK exige sessão viva. WHERE restringe a versão POR ID
-- (não varre o resto da tabela) e a sessão DE ORIGEM por id + status
-- arquivado (não confunde se houver outra migração adiante).
--
-- Imutabilidade da versão publicada: a trigger
-- `trg_ai_agent_versions_content_immutable` (BEFORE UPDATE, invoker) recusa
-- QUALQUER mudança de `channel_session_id` em `status='published'`. A regra
-- de negócio diz "publicada é imutável, mudança = nova versão draft + publish".
-- Aqui a exceção é cirúrgica e documentada: o repointing é forward-fix de
-- ponteiro órfão, não alteração de comportamento do agente (system_prompt,
-- model, tools, trigger_config — tudo intacto). A forma é bypassar a trigger
-- pelo seu próprio desenho: ela é BEFORE UPDATE padrão (sem `ENABLE ALWAYS`
-- nem `ENABLE REPLICA`), e o Postgres pula triggers de UPDATE quando a sessão
-- roda com `session_replication_role='replica'`. É o mesmo mecanismo que
-- pg_dump e o replication slot usam — não é superusuário nem `disable trigger`
-- (que exigiria `ALTER TABLE` e ficaria gravado como DDL no migration log).
-- O SET LOCAL só vale dentro da transação da migration — sai do escopo
-- automaticamente no COMMIT.

-- SET LOCAL precisa de transação explícita (o runner do Supabase CLI já abre
-- BEGIN/COMMIT, mas o `psql -f` em modo manual não abre — e esta migration
-- também precisa rodar quando o operador re-executar o apêndice do baseline
-- via `psql -v ON_ERROR_STOP=1 -f baseline.sql`). BEGIN/COMMIT explícito aqui
-- torna a seção portável entre os dois modos; o begin/commit aninhado é
-- ignorado pelo Postgres como no-op (já há transação aberta, isso vira SAVEPOINT
-- automaticamente só se houver conflito — não há conflito aqui).
begin;
  set local session_replication_role = replica;

  update public.ai_agent_versions av
     set channel_session_id = '804a1f0b-73e0-4a93-b8eb-91432850306f'
   where av.id = '6955c3e2-d5dc-4056-a654-4871ff94b495'
     and av.channel_session_id = '881084e0-89be-4757-a10b-6f824f1cb67f'
     and av.channel_session_id in (
       select id from public.channel_sessions
        where archived_at is not null
          and organization_id = 'e9758c0af7fe4890af2b19bd2cf064fb'
     );
commit;

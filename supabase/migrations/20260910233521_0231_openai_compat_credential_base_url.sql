-- ============================================================================
-- 0231 — Suporte a credencial openai_compat (5º provedor LLM).
--
-- O `ai_purpose_bindings.base_url` (0126) já previa endpoint OpenAI-compat
-- por PONTO — gateway próprio, modelo local, OpenRouter. O que faltava era
-- persistir o mesmo endpoint junto à CREDENCIAL: o validator de
-- `lib/ai/provider-validators.ts` precisa dele pra fazer o ping `/v1/models`
-- quando a credencial é cadastrada ou revalidada, e a UI guarda o valor
-- digitado pelo operador uma vez só, no momento da criação.
--
-- Decisão consciente: gravar `base_url` em `ai_provider_credentials` E em
-- `ai_purpose_bindings` (não em só um dos dois). São peças diferentes:
--   - credential.base_url = o que o validator pinga, o que a UI exibe no card
--   - binding.base_url = o que o seam chama em runtime por ponto
-- Sincronizar um no outro exigiria coerência transacional entre duas tabelas
-- que mudam em momentos distintos (criação de credencial vs. edição de ponto).
-- Manter os dois e documentar o contrato é mais barato e mais auditável.
--
-- A coluna nasce NULL e sem default: dos quatro provedores canônicos só a
-- OpenAI aceita endpoint próprio hoje, e ele é OPCIONAL (o canônico é o
-- default). OpenAI-compat, quando chegar, é OBRIGATÓRIO — a aplicação recusa
-- no POST com 422 (lib/ai/credenciais/guardar.ts). Isso evita CHECKs novos
-- na coluna, que só viriam com o próximo provider a aparecer.
--
-- A view segura `ai_provider_credentials_safe` precisa expor `base_url`
-- também — sem isso o card da UI mostra "—" e o operador não sabe o que
-- digitou. A view é `create or replace` e mantém o `api_key_*` cifrado
-- FORA (esse é o ponto dela) — só metadados.
-- ============================================================================

alter table public.ai_provider_credentials
  add column if not exists base_url text;

comment on column public.ai_provider_credentials.base_url is
  'Migration 0231: endpoint do gateway OpenAI-compat usado pra validar e chamar a chave. '
  'NULL pros 4 provedores canônicos (endpoint intrínseco do provider). Obrigatório quando '
  'provider = ''openai_compat'' — a rota POST recusa com 422 sem ele.';

-- View segura passa a incluir base_url (metadado, nunca o api_key_* cifrado).
create or replace view public.ai_provider_credentials_safe
  with (security_invoker = true) as
  select
    id,
    organization_id,
    provider,
    label,
    api_key_last4,
    validated_at,
    validation_error,
    models_available,
    is_active,
    created_by,
    created_at,
    updated_at,
    base_url
  from public.ai_provider_credentials;

-- Grantee: a view é usada pelo app via PostgREST authenticated. service_role
-- ignora RLS (security_invoker deixa o PostgREST aplicar o policy do caller),
-- então a permissão aqui é só pra leitura via PostgREST authenticated.
grant select on public.ai_provider_credentials_safe to authenticated;

import { requireSupportWrite } from "@/lib/impersonate/support";
/**
 * POST /api/v1/conversations/[id]/reset — arquiva a conversa (soft delete)
 * para isolar a janela de teste da próxima iteração de prompt.
 *
 * ## Por que existe
 *
 * Isaías itera `system_prompt` da versão publicada do agente e testa pelo
 * WhatsApp. O problema: a conversa ativa por (contact_id, channel_session_id)
 * é UMA SÓ (`uniq_conversations_1to1_per_contact_session`, migration 0027), e
 * o LLM sempre vê o histórico empilhado — uma resposta anterior contamina o
 * teste do novo prompt.
 *
 * O agente resolve a versão por `conversations.active_ai_agent_version_id`
 * (resolve-turn-agent.ts:261), NÃO por `ai_agents.published_version_id` —
 * por isso mudar o prompt publicado não refresca conversa antiga. Resetar é
 * a forma de "virar a página".
 *
 * ## O que a rota faz
 *
 * Soft delete: `status='archived'`, `archived_at=now()`. Nenhum `messages`/
 * `contacts`/`ai_chunks`/RAG index é tocado. Próxima msg do WhatsApp cai em
 * `fn_upsert_wa_conversation` (0027), que cria `conversations` NOVA porque a
 * UNIQUE 1:1 exclui `status IN ('closed','archived')` do índice parcial — e
 * a nova linha já nasce com `active_ai_agent_version_id = versão publicada
 * vigente`.
 *
 * ## Restrições
 *
 * - Bloqueia reset em conversa `closed`/`archived` (mesmo invariante do
 *   pause-ai): encerrada não tem agente esperando pra recomeçar.
 * - Bloqueia reset se `is_group=true`: arquivar conversa de grupo isola o
 *   agente só do 1:1; em grupo, o histórico é compartilhado entre membros e
 *   reset cria uma janela confusa (1 agente responde como se fosse primeira
 *   msg, mas os humanos continuam lendo o histórico antigo).
 * - Audit: `conversation.reset_for_testing`. Não é um fechamento — não
 *   roda `fn_service_status` nem toca `service_revision`. Reset é gesto de
 *   operador, não transição de ciclo de vida.
 *
 * Auth: cookie session OU Bearer, agent+ (spec 13 §4: escrita é agent+,
 * viewer é read-only). Audit log: `conversation.reset_for_testing`.
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { audit } from "@/lib/audit";
import { ok, fail } from "@/lib/api/wrappers";
import { requireRole } from "@/lib/auth/require-role";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import type { Conversation } from "@/lib/types/messaging";
import { traduzir } from "@/lib/i18n/dicionario";

export const dynamic = "force-dynamic";

interface RouteCtx {
  params: Promise<{ id: string }>;
}

export async function POST(_req: NextRequest, ctx: RouteCtx): Promise<Response> {
  const supportDenied = await requireSupportWrite();
  if (supportDenied) return supportDenied;

  const requestId = randomUUID();
  const { id } = await ctx.params;

  const authz = await requireRole("agent", { requestId, resource: "conversations" });
  if (!authz.ok) return authz.response;
  const t = (texto: string) => traduzir(texto, authz.user.idioma);
  const { user, org } = authz;

  const supabase = await createClient();

  // Client do REQUEST: a RLS `conversations_select` (0035) aplica o
  // `visibility_mode` por atendente; service role aqui deixaria um agent
  // fora de escopo resetar conversa que ele não enxerga.
  const { data: convRow, error: readErr } = await supabase
    .from("conversations")
    .select("id, organization_id, status, is_group")
    .eq("id", id)
    .eq("organization_id", org.orgId)
    .maybeSingle();
  if (readErr) return fail("internal_error", readErr.message, 500, { requestId });
  if (!convRow) return fail("not_found", t("Conversa não encontrada."), 404, { requestId });

  const conv = convRow as unknown as {
    id: string;
    organization_id: string;
    status: string;
    is_group: boolean;
  };

  if (conv.status === "closed" || conv.status === "archived") {
    return fail(
      "state_conflict",
      t("Esta conversa já está encerrada — não há o que resetar."),
      409,
      { requestId },
    );
  }
  if (conv.is_group) {
    return fail(
      "state_conflict",
      t("Reset não é permitido em conversas de grupo — o histórico é compartilhado entre os membros."),
      409,
      { requestId },
    );
  }

  // Admin client porque o UPDATE precisa ignorar a SELECT do visibility-mode
  // (0035) — sem isto, um agent em modo 'own' faria o reset numa conversa
  // atribuída a OUTRO e o `update ... returning *` filtraria a linha de volta
  // pra ele. O guard acima (`requireRole agent` + `eq organization_id`) já
  // fechou o cross-tenant; o admin aqui é só pra não reprojetar a RLS no
  // returning.
  const admin = createAdminClient();
  const { data: updated, error: updErr } = await admin
    .from("conversations")
    .update({
      status: "archived",
      archived_at: new Date().toISOString(),
      // Limpa a trava de silêncio pra próxima conversa nova não herdar
      // 'infinity' do pause-ai desta.
      bot_silenced_until: null,
    })
    .eq("id", id)
    .eq("organization_id", org.orgId)
    .select("id, organization_id, status, archived_at")
    .maybeSingle();
  if (updErr) return fail("internal_error", updErr.message, 500, { requestId });
  if (!updated) return fail("not_found", t("Conversa não encontrada."), 404, { requestId });

  const final = updated as unknown as Conversation;

  await audit({
    action: "conversation.reset_for_testing",
    actorUserId: user.id,
    organizationId: org.orgId,
    resourceType: "conversation",
    resourceId: id,
    requestId,
    metadata: {
      status_anterior: conv.status,
      is_group: conv.is_group,
    },
  });

  return ok(
    {
      reset: true,
      archived_at: (final as unknown as { archived_at: string }).archived_at,
      conversation: final,
    },
    { requestId },
  );
}

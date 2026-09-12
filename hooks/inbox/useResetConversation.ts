"use client";
import { useMutation, useQueryClient } from "@tanstack/react-query";

import { showApiError } from "@/components/feedback/ApiErrorToast";
import { apiClient } from "@/lib/api/client";

interface ResetArgs {
  conversation_id: string;
}

interface ResetResponse {
  data: { reset: boolean; archived_at: string };
}

/**
 * Reseta a janela de teste da conversa (soft delete).
 *
 * Isaías itera `system_prompt` da versão publicada do agente — o reset
 * arquiva a conversa ativa pra próxima msg do WhatsApp abrir uma NOVA com
 * o ponteiro da versão publicada atual, sem histórico da conversa anterior
 * contaminando o teste. Ver `app/api/v1/conversations/[id]/reset/route.ts`.
 *
 * Invalida `conversations` (lista some da inbox) + `conversation` (header
 * zera) + `conversation-counts` (badge da aba esquerda precisa recontar).
 */
export function useResetConversation() {
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (args: ResetArgs) =>
      apiClient.post<ResetResponse>(
        `/api/v1/conversations/${args.conversation_id}/reset`,
        {},
      ),
    onError: (err) => showApiError(err),
    onSuccess: (_data, args) => {
      qc.invalidateQueries({ queryKey: ["conversations"] });
      qc.invalidateQueries({ queryKey: ["conversation", args.conversation_id] });
      qc.invalidateQueries({ queryKey: ["conversation-counts"] });
    },
  });
}

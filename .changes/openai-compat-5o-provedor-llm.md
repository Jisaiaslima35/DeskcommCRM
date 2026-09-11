---
impacto: capacidade_nova
secao: adicionado
titulo: A tela de credenciais de IA passa a aceitar gateways OpenAI-compat
---

A lista de provedores LLM na tela **IA › Credenciais** ganha a quinta opção, **OpenAI-compatível (gateway)**, ao lado de Anthropic, OpenAI, Google e OpenRouter. Cobre 9Router, LiteLLM, vLLM, Ollama com servidor e qualquer proxy corporativo que fale a API da OpenAI.

Ao escolher essa opção, a tela pede a **Base URL** do gateway (ex.: `https://9router.automacaojs.us/v1`) — sem ela o cadastro não vai adiante, porque o validator precisa dela para confirmar a chave e o runtime precisa dela para mandar a chamada.

Nada muda para quem já usa os quatro provedores canônicos — o campo Base URL continua opcional para OpenAI e OpenRouter.

Para configurar:

1. **IA › Credenciais › Adicionar credencial** → provedor **OpenAI-compatível (gateway)** → nome (ex.: `9router-prod`) → API key → **Base URL**.
2. **IA › Pontos** (ou ao publicar a versão do agente) → selecione a credencial criada em `production`.

Quem opera a VPS não precisa rodar migration nem atualizar variável de ambiente: a migration já entra pelo `update.sh` na próxima execução.

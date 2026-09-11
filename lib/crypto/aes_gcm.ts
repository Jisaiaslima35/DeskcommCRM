/**
 * AES-256-GCM helpers para `ai_provider_credentials`.
 *
 * Key source: `process.env.AI_CRED_AES_KEY` — 32 bytes, hex OU base64.
 *
 * O `.env` deste CRM foi gerado com `openssl rand -hex 32` em algum momento
 * da história (64 chars), mas o helper foi escrito esperando base64 (44 chars
 * → 32 bytes decodificados). Em hex, `Buffer.from(raw, "base64")` ignora
 * chars não-base64 e devolve um buffer MENOR que 32 bytes; o throw de runtime
 * só dispara quando alguém chama `encryptKey`/`decryptKey` — e a feature de
 * credenciais nunca foi exercitada nessa instalação limpa.
 *
 * O instalador (`scripts/gerar-env-e2e.sh`) gera base64 com
 * `openssl rand -base64 32`. O `.env.hostgator.example` e o comentário
 * interno também dizem base64. Para preservar os DOIS caminhos (instalações
 * antigas que podem ter qualquer um dos formatos), este helper tenta HEX
 * primeiro quando o formato bate (64 chars `[0-9a-fA-F]`); se não, cai pra
 * base64. Falha se nenhum dos dois produz 32 bytes.
 *
 * Output do `encryptKey`: três `Buffer`s separados (ciphertext, IV de 12 bytes,
 * tag de 16 bytes) que são gravados como `bytea` na tabela. Pra uso via PostgREST
 * use o helper `bufToBytea()` que produz a literal `\x<hex>`.
 *
 * Plaintext NUNCA deve ser logado, persistido ou retornado em response — apenas
 * o `last4` é exposto via view `ai_provider_credentials_safe`.
 */
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

import { env } from "@/lib/env";

const KEY_LENGTH_BYTES = 32;
const IV_LENGTH_BYTES = 12;
const TAG_LENGTH_BYTES = 16;

let cachedKey: Buffer | null = null;

function getKey(): Buffer {
  if (cachedKey) return cachedKey;
  const raw = env.AI_CRED_AES_KEY;
  if (!raw) {
    throw new Error(
      "AI_CRED_AES_KEY não configurada. Defina em .env.local (32 bytes hex ou base64).",
    );
  }

  const trimmed = raw.trim();

  // Caminho 1: 64 chars hex (formato desta instalação atual — gerado por
  // `openssl rand -hex 32` em algum momento). É o caso que o código original
  // rejeitava silenciosamente.
  let buf: Buffer | null = null;
  if (/^[0-9a-fA-F]{64}$/.test(trimmed)) {
    buf = Buffer.from(trimmed, "hex");
  }

  // Caminho 2: base64 canônico (formato do instalador e do `.env.example`).
  // Mantido para que `scripts/gerar-env-e2e.sh` continue funcionando — ele
  // produz base64 com `openssl rand -base64 32`.
  if (!buf || buf.length !== KEY_LENGTH_BYTES) {
    try {
      buf = Buffer.from(trimmed, "base64");
    } catch {
      buf = null;
    }
  }

  if (!buf || buf.length !== KEY_LENGTH_BYTES) {
    throw new Error(
      `AI_CRED_AES_KEY deve ter exatamente 32 bytes (lido: ${buf?.length ?? 0}). ` +
        `Use hex 64 chars (openssl rand -hex 32) ou base64 44 chars (openssl rand -base64 32).`,
    );
  }
  cachedKey = buf;
  return buf;
}

export interface EncryptedSecret {
  ciphertext: Buffer;
  iv: Buffer;
  tag: Buffer;
  /** Últimos 4 chars do plaintext, mostrados na UI pra identificação. */
  last4: string;
}

export function encryptKey(plaintext: string): EncryptedSecret {
  if (!plaintext || typeof plaintext !== "string") {
    throw new Error("plaintext inválido pra encryptKey()");
  }
  const key = getKey();
  const iv = randomBytes(IV_LENGTH_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  if (tag.length !== TAG_LENGTH_BYTES) {
    throw new Error(`tag length inesperada: ${tag.length}`);
  }
  const last4 = plaintext.slice(-4);
  return { ciphertext, iv, tag, last4 };
}

export function decryptKey(input: {
  ciphertext: Buffer;
  iv: Buffer;
  tag: Buffer;
}): string {
  const { ciphertext, iv, tag } = input;
  const key = getKey();
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return plaintext.toString("utf8");
}

/**
 * Converte um Buffer em literal hex aceito pelo PostgREST pra colunas `bytea`.
 */
export function bufToBytea(buf: Buffer): string {
  return `\\x${buf.toString("hex")}`;
}

/**
 * Inverso de `bufToBytea`: aceita o que o PostgREST devolve em colunas bytea
 * (string `\xHEX` em modo padrão, ou Buffer/Uint8Array dependendo do driver).
 */
export function byteaToBuffer(value: unknown): Buffer {
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (typeof value === "string") {
    const hex = value.startsWith("\\x") ? value.slice(2) : value;
    return Buffer.from(hex, "hex");
  }
  throw new Error("byteaToBuffer: formato inesperado");
}

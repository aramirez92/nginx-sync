import type { Logger } from "../domain/types.ts";

export interface RetryPolicy {
  /** Espera fija entre intentos, en ms. */
  delayMs: number;
  /** Intentos totales. 0 = reintentar indefinidamente. */
  maxAttempts: number;
}

export interface RetryOptions {
  policy: RetryPolicy;
  logger: Logger;
  /** Aborta la espera y corta los reintentos (shutdown). */
  signal?: AbortSignal;
}

export class RetryAbortedError extends Error {
  override readonly name = "RetryAbortedError";
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new RetryAbortedError("Reintentos cancelados."));
      return;
    }

    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);

    function onAbort() {
      clearTimeout(timer);
      reject(new RetryAbortedError("Reintentos cancelados."));
    }

    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/**
 * Ejecuta `fn` reintentando con un delay fijo. Delay fijo y no backoff: cuando
 * el endpoint vuelve, conviene recuperar rápido y de forma predecible.
 */
export async function withRetry<T>(fn: () => Promise<T>, options: RetryOptions): Promise<T> {
  const { policy, logger, signal } = options;
  const unlimited = policy.maxAttempts <= 0;

  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (error instanceof RetryAbortedError) throw error;

      const reason = error instanceof Error ? error.message : String(error);
      const isLast = !unlimited && attempt >= policy.maxAttempts;

      if (isLast) {
        logger.error(`intento ${attempt}/${policy.maxAttempts} falló: ${reason}`);
        throw error;
      }

      const total = unlimited ? "∞" : String(policy.maxAttempts);
      logger.warn(
        `intento ${attempt}/${total} falló: ${reason}. Reintento en ${Math.round(policy.delayMs / 1000)}s.`,
      );
      await sleep(policy.delayMs, signal);
    }
  }
}

import type { Logger, SyncResult } from "../domain/types.ts";
import type { SyncService } from "./sync-service.ts";
import { withRetry, RetryAbortedError, type RetryPolicy } from "./retry.ts";

export type SyncStatus =
  | { state: "idle" }
  | { state: "running"; since: string }
  | { state: "ok"; result: SyncResult }
  | { state: "failing"; error: string; at: string; nextRetryInMs: number };

export interface SyncSupervisorDeps {
  service: SyncService;
  policy: RetryPolicy;
  logger: Logger;
}

/**
 * Mantiene el sync vivo en el servidor: si falla, reintenta cada `delayMs` en
 * background sin bloquear el arranque ni las peticiones HTTP.
 */
export class SyncSupervisor {
  private status: SyncStatus = { state: "idle" };
  private controller: AbortController | null = null;

  constructor(private readonly deps: SyncSupervisorDeps) {}

  getStatus(): SyncStatus {
    return this.status;
  }

  /** Un sync puntual (lo usa POST /sync): sin reintentos, el cliente decide. */
  async syncOnce(): Promise<SyncResult> {
    this.status = { state: "running", since: new Date().toISOString() };
    try {
      const result = await this.deps.service.run();
      this.status = { state: "ok", result };
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.status = {
        state: "failing",
        error: message,
        at: new Date().toISOString(),
        nextRetryInMs: 0,
      };
      throw error;
    }
  }

  /**
   * Sync con reintentos en background. No lanza: los fallos quedan en el estado
   * y en los logs, para que el servidor arranque igual.
   */
  start(): void {
    if (this.controller) return;

    const { service, policy, logger } = this.deps;
    this.controller = new AbortController();
    this.status = { state: "running", since: new Date().toISOString() };

    void withRetry(
      async () => {
        try {
          const result = await service.run();
          this.status = { state: "ok", result };
          return result;
        } catch (error) {
          // Estado visible en /health mientras se espera el próximo intento.
          this.status = {
            state: "failing",
            error: error instanceof Error ? error.message : String(error),
            at: new Date().toISOString(),
            nextRetryInMs: policy.delayMs,
          };
          throw error;
        }
      },
      {
        policy,
        logger,
        signal: this.controller.signal,
      },
    )
      .then((result) => {
        logger.info(
          `sync ok: ${result.bytes} bytes → ${result.path} (changed=${result.changed}, reloaded=${result.reloaded}, ${result.durationMs}ms)`,
        );
      })
      .catch((error: unknown) => {
        if (error instanceof RetryAbortedError) return;
        const message = error instanceof Error ? error.message : String(error);
        this.status = {
          state: "failing",
          error: message,
          at: new Date().toISOString(),
          nextRetryInMs: 0,
        };
        logger.error(`sync agotó los reintentos: ${message}`);
      })
      .finally(() => {
        this.controller = null;
      });
  }

  /** Corta los reintentos pendientes (shutdown). */
  stop(): void {
    this.controller?.abort();
    this.controller = null;
  }
}

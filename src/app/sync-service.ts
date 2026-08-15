import type { ConfigSource, ConfigStore, Logger, Reloader, SyncResult } from "../domain/types.ts";

export interface SyncServiceDeps {
  source: ConfigSource;
  store: ConfigStore;
  reloader: Reloader;
  logger: Logger;
}

/**
 * Orquesta el ciclo completo: descargar → escribir → recargar nginx si cambió.
 * No sabe de HTTP, de archivos ni de procesos: sólo compone los contratos.
 */
export class SyncService {
  private inFlight: Promise<SyncResult> | null = null;

  constructor(private readonly deps: SyncServiceDeps) {}

  /** Dos llamadas concurrentes comparten la misma ejecución: nunca dos escrituras a la vez. */
  run(): Promise<SyncResult> {
    if (this.inFlight) return this.inFlight;

    this.inFlight = this.execute().finally(() => {
      this.inFlight = null;
    });

    return this.inFlight;
  }

  private async execute(): Promise<SyncResult> {
    const { source, store, reloader, logger } = this.deps;
    const startedAt = performance.now();

    const content = await source.fetch();
    const written = await store.write(content);

    let reloaded = false;
    let reloadError: string | undefined;

    if (written.changed) {
      try {
        reloaded = await reloader.reload();
      } catch (error) {
        // El archivo ya está escrito y es válido a nivel descarga: no se pierde.
        // El fallo se reporta, pero no invalida el sync.
        reloadError = error instanceof Error ? error.message : String(error);
        logger.error(`reload falló: ${reloadError}`);
      }
    } else {
      logger.info("sin cambios; no se recarga nginx.");
    }

    return {
      path: written.path,
      bytes: written.bytes,
      changed: written.changed,
      reloaded,
      ...(reloadError !== undefined ? { reloadError } : {}),
      durationMs: Math.round(performance.now() - startedAt),
      fetchedAt: new Date().toISOString(),
    };
  }
}

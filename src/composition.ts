import type { Config } from "./config.ts";
import type { Logger, Reloader } from "./domain/types.ts";
import { ConsoleLogger } from "./infra/console-logger.ts";
import { HttpConfigSource } from "./infra/http-config-source.ts";
import { FileConfigStore } from "./infra/file-config-store.ts";
import { NginxReloader, NoopReloader } from "./infra/nginx-reloader.ts";
import { SyncService } from "./app/sync-service.ts";
import { SyncSupervisor } from "./app/sync-supervisor.ts";
import type { RetryPolicy } from "./app/retry.ts";

/**
 * Composition root: el único lugar que conoce las clases concretas.
 * El resto de la app depende sólo de los contratos de domain/types.ts.
 */

export function buildReloader(config: Config, logger: Logger): Reloader {
  if (!config.nginxReload) return new NoopReloader(logger);

  return new NginxReloader({
    testCommand: config.nginxTestCmd,
    reloadCommand: config.nginxReloadCmd,
    logger,
  });
}

export function buildSyncService(config: Config, logger: Logger, reloader: Reloader): SyncService {
  return new SyncService({
    source: new HttpConfigSource({
      url: config.endpointUrl,
      authHeader: config.endpointAuth,
      timeoutMs: config.requestTimeoutMs,
    }),
    store: new FileConfigStore(config.outputPath),
    reloader,
    logger,
  });
}

export function serverRetryPolicy(config: Config): RetryPolicy {
  return { delayMs: config.retryDelayMs, maxAttempts: config.retryMaxAttempts };
}

export function cliRetryPolicy(config: Config): RetryPolicy {
  return { delayMs: config.retryDelayMs, maxAttempts: config.cliRetryMaxAttempts };
}

export interface App {
  logger: Logger;
  reloader: Reloader;
  service: SyncService;
  supervisor: SyncSupervisor;
}

/** Arma el grafo completo. Lo usan los dos entrypoints. */
export function buildApp(config: Config, logger: Logger = new ConsoleLogger("sync")): App {
  const reloader = buildReloader(config, logger);
  const service = buildSyncService(config, logger, reloader);
  const supervisor = new SyncSupervisor({
    service,
    policy: serverRetryPolicy(config),
    logger,
  });

  return { logger, reloader, service, supervisor };
}

import { config } from "./config.ts";
import { buildApp, cliRetryPolicy } from "./composition.ts";
import { ConsoleLogger } from "./infra/console-logger.ts";
import { withRetry } from "./app/retry.ts";

/**
 * Entrypoint CLI one-shot: `bun run sync`.
 * Reintenta ante fallos de red o del endpoint y sale 0/1 para el que lo invoque.
 *
 * Sin top-level await a propósito: así el módulo también se puede cargar con
 * `require()`, que no soporta módulos async.
 */
async function main(): Promise<number> {
  const logger = new ConsoleLogger("sync");
  const { service } = buildApp(config, logger);

  try {
    const result = await withRetry(() => service.run(), {
      policy: cliRetryPolicy(config),
      logger,
    });

    logger.info(
      `${result.bytes} bytes → ${result.path} ` +
        `(changed=${result.changed}, reloaded=${result.reloaded}, ${result.durationMs}ms)`,
    );
    // Un reload fallido se reporta como fallo para que el supervisor lo registre.
    return result.reloadError ? 1 : 0;
  } catch (error) {
    logger.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

// exit() explícito: si el supervisor deja un canal IPC abierto, el event loop
// sigue vivo y el proceso no terminaría solo. Es seguro porque ConsoleLogger
// escribe con writeSync, así que no queda salida sin volcar.
void main().then((code) => process.exit(code));

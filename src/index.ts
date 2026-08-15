import { config } from "./config.ts";
import { buildApp } from "./composition.ts";
import { createServer } from "./server.ts";
import { ConsoleLogger } from "./infra/console-logger.ts";

const logger = new ConsoleLogger("server");
const { supervisor, reloader } = buildApp(config, new ConsoleLogger("sync"));

if (config.syncOnBoot) {
  // No bloquea el arranque: si falla, el supervisor reintenta en background
  // cada RETRY_DELAY_MS mientras la config anterior sigue sirviendo.
  supervisor.start();
}

const server = createServer({ supervisor, reloader, config }).listen(config.port, () => {
  logger.info(`escuchando en http://localhost:${config.port}`);
  logger.info(`endpoint: ${config.endpointUrl}`);
  logger.info(`salida:   ${config.outputPath}`);
  logger.info(`reload:   ${reloader.description}`);
  logger.info(
    `reintentos: cada ${Math.round(config.retryDelayMs / 1000)}s ` +
      `(${config.retryMaxAttempts === 0 ? "sin límite" : `${config.retryMaxAttempts} intentos`})`,
  );
  if (!config.syncToken) {
    logger.warn("SYNC_TOKEN vacío → POST /sync responde 503.");
  }
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    logger.info(`${signal} recibido, cerrando...`);
    supervisor.stop();
    server.close(() => process.exit(0));
    // Si alguna conexión queda colgada, no esperar para siempre.
    setTimeout(() => process.exit(0), 5000).unref();
  });
}

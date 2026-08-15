import { config } from "./config.ts";
import { createServer, runSync } from "./server.ts";

if (config.syncOnBoot) {
  try {
    const result = await runSync();
    console.log(`[boot] sync ok: ${result.bytes} bytes → ${result.path} (${result.durationMs}ms)`);
  } catch (error) {
    // Un endpoint caído no debe impedir que el servidor arranque:
    // el archivo previo sigue sirviendo y /sync permite reintentar.
    console.error(`[boot] sync falló: ${error instanceof Error ? error.message : String(error)}`);
  }
}

const server = createServer().listen(config.port, () => {
  console.log(`[server] escuchando en http://localhost:${config.port}`);
  console.log(`[server] endpoint: ${config.endpointUrl}`);
  console.log(`[server] salida:   ${config.outputPath}`);
  if (!config.syncToken) {
    console.warn("[server] SYNC_TOKEN vacío → POST /sync responde 503.");
  }
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`\n[server] ${signal} recibido, cerrando...`);
    server.close(() => process.exit(0));
    // Si alguna conexión queda colgada, no esperar para siempre.
    setTimeout(() => process.exit(0), 5000).unref();
  });
}

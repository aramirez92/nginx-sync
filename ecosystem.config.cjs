// Configuración de PM2. Extensión .cjs a propósito: package.json declara
// "type": "module" y PM2 carga este archivo como CommonJS.
//
//   pm2 start ecosystem.config.cjs
//   pm2 start ecosystem.config.cjs --only nginx-sync
//
// Las variables sensibles NO van acá: viven en .env, que Bun carga solo desde `cwd`.

const path = require("node:path");

const cwd = __dirname;
const interpreter = process.env.BUN_PATH || "bun";

module.exports = {
  apps: [
    {
      // Webservice: GET /health y POST /sync.
      name: "nginx-sync",
      cwd,
      script: "src/index.ts",
      interpreter,
      // fork y una sola instancia: cluster no aplica con un intérprete externo,
      // y dos procesos escribiendo el mismo archivo no tendría sentido.
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      exp_backoff_restart_delay: 5000,
      max_memory_restart: "200M",
      time: true,
      // Sin sufijo -0/-1 en los nombres de archivo de log.
      merge_logs: true,
      out_file: path.join(cwd, "logs", "nginx-sync.out.log"),
      error_file: path.join(cwd, "logs", "nginx-sync.err.log"),
      env: {
        NODE_ENV: "production",
      },
    },
    {
      // Sincronización periódica. Corre `bun run src/sync.ts` y termina;
      // si la descarga falla, reintenta cada RETRY_DELAY_MS antes de rendirse.
      name: "nginx-sync-cron",
      cwd,
      script: "src/sync.ts",
      interpreter,
      exec_mode: "fork",
      instances: 1,
      autorestart: false,
      cron_restart: "*/5 * * * *",
      time: true,
      // Sin sufijo -0/-1 en los nombres de archivo de log.
      merge_logs: true,
      out_file: path.join(cwd, "logs", "nginx-sync-cron.out.log"),
      error_file: path.join(cwd, "logs", "nginx-sync-cron.err.log"),
      env: {
        NODE_ENV: "production",
      },
    },
  ],
};

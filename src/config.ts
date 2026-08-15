import { resolve, join, isAbsolute } from "node:path";
import { writeSync } from "node:fs";

// Raíz del proyecto: src/ está un nivel adentro. Se resuelve contra el archivo,
// no contra process.cwd(), para poder invocar el script desde cualquier lugar.
const PROJECT_ROOT = resolve(import.meta.dir, "..");

export interface Config {
  endpointUrl: string;
  endpointAuth: string | undefined;
  outputDir: string;
  outputFilename: string;
  outputPath: string;
  port: number;
  syncToken: string | undefined;
  requestTimeoutMs: number;
  syncOnBoot: boolean;
  nginxReload: boolean;
  nginxTestCmd: string;
  nginxReloadCmd: string;
  retryDelayMs: number;
  /** 0 = reintentar indefinidamente (servidor). */
  retryMaxAttempts: number;
  /** Intentos del CLI one-shot antes de rendirse. */
  cliRetryMaxAttempts: number;
}

class ConfigError extends Error {}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new ConfigError(
      `Falta la variable de entorno ${name}. Copiá .env.example a .env y completala.`,
    );
  }
  return value;
}

function optional(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value ? value : undefined;
}

function num(name: string, fallback: number): number {
  const raw = optional(name);
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new ConfigError(`${name} debe ser un número positivo, recibí "${raw}".`);
  }
  return parsed;
}

function count(name: string, fallback: number): number {
  const raw = optional(name);
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new ConfigError(`${name} debe ser un entero >= 0, recibí "${raw}".`);
  }
  return parsed;
}

function bool(name: string, fallback: boolean): boolean {
  const raw = optional(name)?.toLowerCase();
  if (raw === undefined) return fallback;
  if (["true", "1", "yes", "on"].includes(raw)) return true;
  if (["false", "0", "no", "off"].includes(raw)) return false;
  throw new ConfigError(`${name} debe ser true o false, recibí "${raw}".`);
}

function parseEndpointUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ConfigError(`ENDPOINT_URL no es una URL válida: "${raw}".`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new ConfigError(`ENDPOINT_URL debe ser http o https, recibí "${url.protocol}".`);
  }
  return url.toString();
}

// El nombre viene del entorno, así que se valida igual: nada de barras ni "..".
function parseFilename(raw: string): string {
  if (raw.includes("/") || raw.includes("\\")) {
    throw new ConfigError(`OUTPUT_FILENAME no puede contener barras: "${raw}".`);
  }
  if (raw === "." || raw === "..") {
    throw new ConfigError(`OUTPUT_FILENAME inválido: "${raw}".`);
  }
  return raw;
}

function parseOutputDir(raw: string): string {
  return isAbsolute(raw) ? raw : resolve(PROJECT_ROOT, raw);
}

function build(): Config {
  const outputDir = parseOutputDir(optional("OUTPUT_DIR") ?? "sites-enabled");
  const outputFilename = parseFilename(optional("OUTPUT_FILENAME") ?? "default.conf");

  return {
    endpointUrl: parseEndpointUrl(required("ENDPOINT_URL")),
    endpointAuth: optional("ENDPOINT_AUTH"),
    outputDir,
    outputFilename,
    outputPath: join(outputDir, outputFilename),
    port: num("PORT", 3000),
    syncToken: optional("SYNC_TOKEN"),
    requestTimeoutMs: num("REQUEST_TIMEOUT_MS", 15_000),
    syncOnBoot: bool("SYNC_ON_BOOT", true),
    nginxReload: bool("NGINX_RELOAD", false),
    nginxTestCmd: optional("NGINX_TEST_CMD") ?? "sudo nginx -t",
    nginxReloadCmd: optional("NGINX_RELOAD_CMD") ?? "sudo systemctl reload nginx",
    retryDelayMs: num("RETRY_DELAY_MS", 30_000),
    retryMaxAttempts: count("RETRY_MAX_ATTEMPTS", 0),
    cliRetryMaxAttempts: count("CLI_RETRY_MAX_ATTEMPTS", 3),
  };
}

export function loadConfig(): Config {
  try {
    return build();
  } catch (error) {
    if (error instanceof ConfigError) {
      // writeSync: un console.error seguido de process.exit se trunca cuando la
      // salida está capturada por un pipe (PM2, systemd).
      writeSync(2, `[config] ${error.message}\n`);
      process.exit(1);
    }
    throw error;
  }
}

export const config = loadConfig();
export { PROJECT_ROOT };

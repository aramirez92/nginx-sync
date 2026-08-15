import { mkdir, writeFile, rename, unlink } from "node:fs/promises";
import { config } from "./config.ts";

export interface SyncResult {
  path: string;
  bytes: number;
  durationMs: number;
  fetchedAt: string;
}

export class SyncError extends Error {}

async function download(): Promise<string> {
  const headers: Record<string, string> = { Accept: "text/plain, */*" };
  if (config.endpointAuth) headers.Authorization = config.endpointAuth;

  let response: Response;
  try {
    response = await fetch(config.endpointUrl, {
      headers,
      redirect: "follow",
      signal: AbortSignal.timeout(config.requestTimeoutMs),
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new SyncError(`No se pudo alcanzar el endpoint: ${reason}`);
  }

  const body = await response.text();

  if (!response.ok) {
    const preview = body.slice(0, 200).replace(/\s+/g, " ").trim();
    throw new SyncError(`El endpoint respondió ${response.status} ${response.statusText}: ${preview}`);
  }

  // Una respuesta vacía dejaría a nginx sin config; mejor conservar la anterior.
  if (body.trim().length === 0) {
    throw new SyncError("El endpoint respondió vacío; se conserva el archivo anterior.");
  }

  return body;
}

export async function sync(): Promise<SyncResult> {
  const startedAt = performance.now();
  const content = await download();

  await mkdir(config.outputDir, { recursive: true });

  // Escritura atómica: nginx nunca debe leer un archivo a medio escribir.
  const tmpPath = `${config.outputPath}.tmp`;
  try {
    await writeFile(tmpPath, content, "utf8");
    await rename(tmpPath, config.outputPath);
  } catch (error) {
    await unlink(tmpPath).catch(() => {});
    const reason = error instanceof Error ? error.message : String(error);
    throw new SyncError(`No se pudo escribir ${config.outputPath}: ${reason}`);
  }

  return {
    path: config.outputPath,
    bytes: Buffer.byteLength(content, "utf8"),
    durationMs: Math.round(performance.now() - startedAt),
    fetchedAt: new Date().toISOString(),
  };
}

// Modo CLI one-shot: `bun run sync`.
if (import.meta.main) {
  try {
    const result = await sync();
    console.log(`[sync] ${result.bytes} bytes → ${result.path} (${result.durationMs}ms)`);
    process.exit(0);
  } catch (error) {
    console.error(`[sync] ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}

import { type ConfigSource, SyncError } from "../domain/types.ts";

export interface HttpConfigSourceOptions {
  url: string;
  authHeader?: string | undefined;
  timeoutMs: number;
}

/** Descarga la configuración por HTTP. */
export class HttpConfigSource implements ConfigSource {
  constructor(private readonly options: HttpConfigSourceOptions) {}

  async fetch(): Promise<string> {
    const headers: Record<string, string> = { Accept: "text/plain, */*" };
    if (this.options.authHeader) headers.Authorization = this.options.authHeader;

    let response: Response;
    try {
      response = await globalThis.fetch(this.options.url, {
        headers,
        redirect: "follow",
        signal: AbortSignal.timeout(this.options.timeoutMs),
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      throw new SyncError(`No se pudo alcanzar el endpoint: ${reason}`);
    }

    const body = await response.text();

    if (!response.ok) {
      const preview = body.slice(0, 200).replace(/\s+/g, " ").trim();
      throw new SyncError(
        `El endpoint respondió ${response.status} ${response.statusText}: ${preview}`,
      );
    }

    // Una respuesta vacía dejaría a nginx sin config; mejor conservar la anterior.
    if (body.trim().length === 0) {
      throw new SyncError("El endpoint respondió vacío; se conserva el archivo anterior.");
    }

    return body;
  }
}

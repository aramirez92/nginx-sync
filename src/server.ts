import express, { type Request, type Response } from "express";
import { timingSafeEqual } from "node:crypto";
import type { Config } from "./config.ts";
import type { Reloader } from "./domain/types.ts";
import type { SyncSupervisor } from "./app/sync-supervisor.ts";

export interface ServerDeps {
  supervisor: SyncSupervisor;
  reloader: Reloader;
  config: Config;
}

function tokenMatches(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

function authorize(req: Request, res: Response, syncToken: string | undefined): boolean {
  if (!syncToken) {
    res
      .status(503)
      .json({ ok: false, error: "SYNC_TOKEN no configurado; /sync está deshabilitado." });
    return false;
  }

  const header = req.get("authorization") ?? "";
  const [scheme, ...rest] = header.split(" ");
  const provided = rest.join(" ").trim();

  if (scheme?.toLowerCase() !== "bearer" || !provided || !tokenMatches(provided, syncToken)) {
    res.status(401).json({ ok: false, error: "No autorizado." });
    return false;
  }

  return true;
}

/** Transporte HTTP: sólo traduce peticiones al SyncSupervisor inyectado. */
export function createServer({ supervisor, reloader, config }: ServerDeps) {
  const app = express();
  app.disable("x-powered-by");

  app.get("/health", (_req, res) => {
    res.json({
      ok: true,
      endpoint: config.endpointUrl,
      outputPath: config.outputPath,
      reload: reloader.description,
      retry: { delayMs: config.retryDelayMs, maxAttempts: config.retryMaxAttempts },
      sync: supervisor.getStatus(),
    });
  });

  app.post("/sync", async (req, res) => {
    if (!authorize(req, res, config.syncToken)) return;

    try {
      const result = await supervisor.syncOnce();
      res.json({ ok: true, ...result });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      res.status(502).json({ ok: false, error: message });
    }
  });

  app.use((_req, res) => {
    res.status(404).json({ ok: false, error: "Not found" });
  });

  return app;
}

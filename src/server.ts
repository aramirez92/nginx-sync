import express, { type Request, type Response } from "express";
import { timingSafeEqual } from "node:crypto";
import { config } from "./config.ts";
import { sync, type SyncResult } from "./sync.ts";

type LastSync =
  | { ok: true; result: SyncResult }
  | { ok: false; error: string; at: string }
  | null;

let lastSync: LastSync = null;
let inFlight: Promise<SyncResult> | null = null;

/** Corre un sync, reusando el que ya esté en vuelo para no escribir dos veces a la vez. */
export function runSync(): Promise<SyncResult> {
  if (inFlight) return inFlight;

  inFlight = sync()
    .then((result) => {
      lastSync = { ok: true, result };
      return result;
    })
    .catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      lastSync = { ok: false, error: message, at: new Date().toISOString() };
      throw error;
    })
    .finally(() => {
      inFlight = null;
    });

  return inFlight;
}

function tokenMatches(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

function authorize(req: Request, res: Response): boolean {
  if (!config.syncToken) {
    res.status(503).json({ ok: false, error: "SYNC_TOKEN no configurado; /sync está deshabilitado." });
    return false;
  }

  const header = req.get("authorization") ?? "";
  const [scheme, ...rest] = header.split(" ");
  const provided = rest.join(" ").trim();

  if (scheme?.toLowerCase() !== "bearer" || !provided || !tokenMatches(provided, config.syncToken)) {
    res.status(401).json({ ok: false, error: "No autorizado." });
    return false;
  }

  return true;
}

export function createServer() {
  const app = express();
  app.disable("x-powered-by");

  app.get("/health", (_req, res) => {
    res.json({
      ok: true,
      endpoint: config.endpointUrl,
      outputPath: config.outputPath,
      lastSync,
    });
  });

  app.post("/sync", async (req, res) => {
    if (!authorize(req, res)) return;

    try {
      const result = await runSync();
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

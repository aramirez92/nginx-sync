import { describe, expect, it } from "bun:test";
import { withRetry, RetryAbortedError } from "./retry.ts";
import { SilentLogger } from "../infra/console-logger.ts";

const logger = new SilentLogger();

describe("withRetry", () => {
  it("devuelve al primer éxito sin reintentar", async () => {
    let calls = 0;
    const result = await withRetry(
      async () => {
        calls++;
        return "ok";
      },
      { policy: { delayMs: 1, maxAttempts: 3 }, logger },
    );

    expect(result).toBe("ok");
    expect(calls).toBe(1);
  });

  it("reintenta hasta que la operación se recupera", async () => {
    let calls = 0;
    const result = await withRetry(
      async () => {
        calls++;
        if (calls < 3) throw new Error("endpoint caído");
        return "ok";
      },
      { policy: { delayMs: 1, maxAttempts: 5 }, logger },
    );

    expect(result).toBe("ok");
    expect(calls).toBe(3);
  });

  it("se rinde tras maxAttempts y propaga el último error", async () => {
    let calls = 0;
    const run = withRetry(
      async () => {
        calls++;
        throw new Error("sigue caído");
      },
      { policy: { delayMs: 1, maxAttempts: 3 }, logger },
    );

    await expect(run).rejects.toThrow("sigue caído");
    expect(calls).toBe(3);
  });

  it("respeta el delay entre intentos", async () => {
    const started = performance.now();
    let calls = 0;

    await withRetry(
      async () => {
        calls++;
        if (calls < 3) throw new Error("fallo");
        return true;
      },
      { policy: { delayMs: 25, maxAttempts: 5 }, logger },
    );

    // Dos esperas de 25 ms entre los tres intentos.
    expect(performance.now() - started).toBeGreaterThanOrEqual(45);
  });

  it("corta los reintentos cuando se aborta", async () => {
    const controller = new AbortController();
    let calls = 0;

    const run = withRetry(
      async () => {
        calls++;
        throw new Error("fallo");
      },
      { policy: { delayMs: 10_000, maxAttempts: 0 }, logger, signal: controller.signal },
    );

    await Bun.sleep(10);
    controller.abort();

    await expect(run).rejects.toThrow(RetryAbortedError);
    expect(calls).toBe(1);
  });
});

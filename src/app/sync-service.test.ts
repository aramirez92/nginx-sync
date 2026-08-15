import { describe, expect, it } from "bun:test";
import { SyncService } from "./sync-service.ts";
import { SilentLogger } from "../infra/console-logger.ts";
import { ReloadError, type ConfigSource, type ConfigStore, type Reloader } from "../domain/types.ts";

class FakeSource implements ConfigSource {
  calls = 0;
  constructor(private readonly content: string | Error) {}
  async fetch(): Promise<string> {
    this.calls++;
    if (this.content instanceof Error) throw this.content;
    return this.content;
  }
}

class FakeStore implements ConfigStore {
  writes = 0;
  constructor(private readonly changed: boolean) {}
  async write(content: string) {
    this.writes++;
    return { path: "/tmp/fake.conf", bytes: content.length, changed: this.changed };
  }
}

class FakeReloader implements Reloader {
  readonly description = "fake";
  calls = 0;
  constructor(private readonly outcome: boolean | Error = true) {}
  async reload(): Promise<boolean> {
    this.calls++;
    if (this.outcome instanceof Error) throw this.outcome;
    return this.outcome;
  }
}

function build(source: FakeSource, store: FakeStore, reloader: FakeReloader) {
  return new SyncService({ source, store, reloader, logger: new SilentLogger() });
}

describe("SyncService", () => {
  it("recarga nginx cuando la config cambió", async () => {
    const reloader = new FakeReloader();
    const result = await build(new FakeSource("server {}"), new FakeStore(true), reloader).run();

    expect(result.changed).toBe(true);
    expect(result.reloaded).toBe(true);
    expect(reloader.calls).toBe(1);
  });

  it("no recarga nginx cuando la config es idéntica", async () => {
    const reloader = new FakeReloader();
    const result = await build(new FakeSource("server {}"), new FakeStore(false), reloader).run();

    expect(result.changed).toBe(false);
    expect(result.reloaded).toBe(false);
    expect(reloader.calls).toBe(0);
  });

  it("un reload fallido no invalida la escritura", async () => {
    const store = new FakeStore(true);
    const result = await build(
      new FakeSource("server {}"),
      store,
      new FakeReloader(new ReloadError("nginx -t falló")),
    ).run();

    expect(store.writes).toBe(1);
    expect(result.changed).toBe(true);
    expect(result.reloaded).toBe(false);
    expect(result.reloadError).toContain("nginx -t falló");
  });

  it("propaga el fallo de descarga sin escribir", async () => {
    const store = new FakeStore(true);
    const service = build(new FakeSource(new Error("endpoint caído")), store, new FakeReloader());

    await expect(service.run()).rejects.toThrow("endpoint caído");
    expect(store.writes).toBe(0);
  });

  it("dos llamadas concurrentes comparten una sola ejecución", async () => {
    const source = new FakeSource("server {}");
    const store = new FakeStore(true);
    const service = build(source, store, new FakeReloader());

    const [a, b] = await Promise.all([service.run(), service.run()]);

    expect(source.calls).toBe(1);
    expect(store.writes).toBe(1);
    expect(a).toEqual(b);
  });

  it("permite un nuevo sync después de que terminó el anterior", async () => {
    const source = new FakeSource("server {}");
    const service = build(source, new FakeStore(true), new FakeReloader());

    await service.run();
    await service.run();

    expect(source.calls).toBe(2);
  });
});

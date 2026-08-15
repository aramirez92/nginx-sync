import { afterEach, describe, expect, it } from "bun:test";
import { mkdtemp, rm, readFile, readdir, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FileConfigStore } from "./file-config-store.ts";
import { SyncError } from "../domain/types.ts";

const dirs: string[] = [];

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "nginx-sync-test-"));
  dirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("FileConfigStore", () => {
  it("escribe el archivo y reporta changed", async () => {
    const path = join(await tempDir(), "default.conf");
    const outcome = await new FileConfigStore(path).write("server {}\n");

    expect(outcome.changed).toBe(true);
    expect(outcome.bytes).toBe(10);
    expect(await readFile(path, "utf8")).toBe("server {}\n");
  });

  it("crea el directorio si no existe", async () => {
    const path = join(await tempDir(), "nested", "deep", "default.conf");
    await new FileConfigStore(path).write("server {}\n");

    expect(await readFile(path, "utf8")).toBe("server {}\n");
  });

  it("no reescribe cuando el contenido es idéntico", async () => {
    const path = join(await tempDir(), "default.conf");
    const store = new FileConfigStore(path);

    await store.write("server {}\n");
    const second = await store.write("server {}\n");

    expect(second.changed).toBe(false);
  });

  it("detecta el cambio cuando el contenido difiere", async () => {
    const path = join(await tempDir(), "default.conf");
    const store = new FileConfigStore(path);

    await store.write("server { listen 80; }\n");
    const second = await store.write("server { listen 8080; }\n");

    expect(second.changed).toBe(true);
    expect(await readFile(path, "utf8")).toContain("8080");
  });

  it("no deja archivos .tmp tras una escritura exitosa", async () => {
    const dir = await tempDir();
    await new FileConfigStore(join(dir, "default.conf")).write("server {}\n");

    expect((await readdir(dir)).filter((f) => f.endsWith(".tmp"))).toHaveLength(0);
  });

  it("lanza SyncError y limpia el .tmp si no puede escribir", async () => {
    const dir = await tempDir();
    const path = join(dir, "default.conf");
    await chmod(dir, 0o500); // sólo lectura

    try {
      await expect(new FileConfigStore(path).write("server {}\n")).rejects.toThrow(SyncError);
      expect((await readdir(dir)).filter((f) => f.endsWith(".tmp"))).toHaveLength(0);
    } finally {
      await chmod(dir, 0o700);
    }
  });
});

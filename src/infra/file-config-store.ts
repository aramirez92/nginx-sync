import { mkdir, readFile, writeFile, rename, unlink } from "node:fs/promises";
import { createHash } from "node:crypto";
import { dirname } from "node:path";
import { type ConfigStore, type WriteOutcome, SyncError } from "../domain/types.ts";

function sha256(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

/**
 * Escribe la configuración en disco de forma atómica (tmp + rename), para que
 * nginx nunca lea un archivo a medio escribir. Si el contenido es idéntico al
 * que ya está en disco, no reescribe y reporta `changed: false`.
 */
export class FileConfigStore implements ConfigStore {
  constructor(private readonly path: string) {}

  private async currentHash(): Promise<string | null> {
    try {
      return sha256(await readFile(this.path, "utf8"));
    } catch {
      // No existe todavía, o no se puede leer: tratamos como "sin contenido previo".
      return null;
    }
  }

  async write(content: string): Promise<WriteOutcome> {
    const bytes = Buffer.byteLength(content, "utf8");

    if ((await this.currentHash()) === sha256(content)) {
      return { path: this.path, bytes, changed: false };
    }

    await mkdir(dirname(this.path), { recursive: true });

    const tmpPath = `${this.path}.tmp`;
    try {
      await writeFile(tmpPath, content, "utf8");
      await rename(tmpPath, this.path);
    } catch (error) {
      await unlink(tmpPath).catch(() => {});
      const reason = error instanceof Error ? error.message : String(error);
      throw new SyncError(`No se pudo escribir ${this.path}: ${reason}`);
    }

    return { path: this.path, bytes, changed: true };
  }
}

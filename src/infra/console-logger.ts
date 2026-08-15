import { writeSync } from "node:fs";
import type { Logger } from "../domain/types.ts";

const STDOUT = 1;
const STDERR = 2;

/**
 * Escribe con `writeSync` en vez de `console.log`: cuando systemd/journald captura
 * la salida por un pipe, `console.log` es asíncrono y un `process.exit()` posterior
 * trunca el mensaje. Los procesos one-shot (`bun run sync`) perderían todo su log.
 */
export class ConsoleLogger implements Logger {
  constructor(private readonly scope: string) {}

  info(message: string): void {
    writeSync(STDOUT, `[${this.scope}] ${message}\n`);
  }

  warn(message: string): void {
    writeSync(STDERR, `[${this.scope}] ${message}\n`);
  }

  error(message: string): void {
    writeSync(STDERR, `[${this.scope}] ${message}\n`);
  }
}

/** Descarta todo. Útil en tests. */
export class SilentLogger implements Logger {
  info(): void {}
  warn(): void {}
  error(): void {}
}

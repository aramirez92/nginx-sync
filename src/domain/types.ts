/** Contratos del dominio. La infraestructura los implementa; la app sólo depende de esto. */

/** Origen de la configuración. Devuelve el contenido crudo o lanza SyncError. */
export interface ConfigSource {
  fetch(): Promise<string>;
}

export interface WriteOutcome {
  path: string;
  bytes: number;
  /** false si el contenido en disco ya era idéntico. */
  changed: boolean;
}

/** Destino de la configuración. */
export interface ConfigStore {
  write(content: string): Promise<WriteOutcome>;
}

/** Aplica la configuración en el servidor web. */
export interface Reloader {
  /** Devuelve true si efectivamente recargó; false si el reload está desactivado. */
  reload(): Promise<boolean>;
  /** Para logs y /health: describe qué hará el reload. */
  readonly description: string;
}

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

export interface SyncResult {
  path: string;
  bytes: number;
  changed: boolean;
  reloaded: boolean;
  /** Presente si el reload falló pero la escritura fue exitosa. */
  reloadError?: string;
  durationMs: number;
  fetchedAt: string;
}

/** Falla al descargar o escribir la configuración. */
export class SyncError extends Error {
  override readonly name = "SyncError";
}

/** Falla al validar o recargar nginx. No invalida la config ya escrita. */
export class ReloadError extends Error {
  override readonly name = "ReloadError";
}

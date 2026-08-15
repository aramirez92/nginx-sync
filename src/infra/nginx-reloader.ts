import { type Logger, type Reloader, ReloadError } from "../domain/types.ts";

export interface NginxReloaderOptions {
  /** Comando de validación, ej. "sudo nginx -t". Vacío = omitir la validación. */
  testCommand: string;
  /** Comando de recarga, ej. "sudo systemctl reload nginx". */
  reloadCommand: string;
  logger: Logger;
}

interface CommandOutcome {
  exitCode: number;
  output: string;
}

/**
 * Los comandos se parten por espacios y se ejecutan sin shell: no hay
 * interpolación, ni globs, ni encadenamiento con `;` o `&&`.
 */
export function parseCommand(command: string): string[] {
  const argv = command.trim().split(/\s+/).filter(Boolean);
  if (argv.length === 0) {
    throw new ReloadError("Comando vacío.");
  }
  return argv;
}

async function run(command: string): Promise<CommandOutcome> {
  const argv = parseCommand(command);
  const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { exitCode, output: `${stdout}${stderr}`.trim() };
}

/** Valida la configuración y recarga nginx. */
export class NginxReloader implements Reloader {
  readonly description: string;

  constructor(private readonly options: NginxReloaderOptions) {
    this.description = options.testCommand
      ? `${options.testCommand} && ${options.reloadCommand}`
      : options.reloadCommand;
  }

  async reload(): Promise<boolean> {
    const { testCommand, reloadCommand, logger } = this.options;

    if (testCommand) {
      const test = await this.exec(testCommand);
      // Nunca recargar con una config inválida: nginx se quedaría con la vieja
      // y el error pasaría inadvertido.
      if (test.exitCode !== 0) {
        throw new ReloadError(`"${testCommand}" falló (código ${test.exitCode}): ${test.output}`);
      }
      logger.info(`configuración válida (${testCommand}).`);
    }

    const reload = await this.exec(reloadCommand);
    if (reload.exitCode !== 0) {
      throw new ReloadError(`"${reloadCommand}" falló (código ${reload.exitCode}): ${reload.output}`);
    }
    logger.info(`nginx recargado (${reloadCommand}).`);
    return true;
  }

  private async exec(command: string): Promise<CommandOutcome> {
    try {
      return await run(command);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      throw new ReloadError(`No se pudo ejecutar "${command}": ${reason}`);
    }
  }
}

/** Reload desactivado (NGINX_RELOAD=false, o entornos sin nginx como macOS). */
export class NoopReloader implements Reloader {
  readonly description = "desactivado (NGINX_RELOAD=false)";

  constructor(private readonly logger: Logger) {}

  async reload(): Promise<boolean> {
    this.logger.info("reload de nginx desactivado; sólo se escribió el archivo.");
    return false;
  }
}

import { describe, expect, it } from "bun:test";
import { NginxReloader, NoopReloader, parseCommand } from "./nginx-reloader.ts";
import { SilentLogger } from "./console-logger.ts";
import { ReloadError } from "../domain/types.ts";

const logger = new SilentLogger();

describe("parseCommand", () => {
  it("parte el comando en argv sin shell", () => {
    expect(parseCommand("sudo systemctl reload nginx")).toEqual([
      "sudo",
      "systemctl",
      "reload",
      "nginx",
    ]);
  });

  it("rechaza comandos vacíos", () => {
    expect(() => parseCommand("   ")).toThrow(ReloadError);
  });
});

describe("NginxReloader", () => {
  it("recarga cuando el test pasa", async () => {
    const reloader = new NginxReloader({
      testCommand: "true",
      reloadCommand: "true",
      logger,
    });

    expect(await reloader.reload()).toBe(true);
  });

  it("no recarga si el test de configuración falla", async () => {
    const reloader = new NginxReloader({
      testCommand: "false",
      // Si el reload llegara a ejecutarse, este comando también fallaría;
      // el mensaje del error confirma que se cortó en el test.
      reloadCommand: "true",
      logger,
    });

    await expect(reloader.reload()).rejects.toThrow(/"false" falló/);
  });

  it("falla si el comando de reload sale distinto de 0", async () => {
    const reloader = new NginxReloader({
      testCommand: "",
      reloadCommand: "false",
      logger,
    });

    await expect(reloader.reload()).rejects.toThrow(ReloadError);
  });

  it("reporta el comando inexistente como ReloadError", async () => {
    const reloader = new NginxReloader({
      testCommand: "",
      reloadCommand: "comando-que-no-existe-nginx-sync",
      logger,
    });

    await expect(reloader.reload()).rejects.toThrow(ReloadError);
  });
});

describe("NoopReloader", () => {
  it("no recarga nada y lo reporta", async () => {
    expect(await new NoopReloader(logger).reload()).toBe(false);
  });
});

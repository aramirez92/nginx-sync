# nginx-sync

Descarga la configuración de nginx desde un endpoint HTTP remoto y la deja en el
directorio `sites-enabled/` de este proyecto. Un script con `sudo` enlaza
`/etc/nginx/sites-enabled` a ese directorio, así nginx sirve siempre lo último
que se sincronizó.

Corre con [Bun](https://bun.sh) y TypeScript. Sin paso de build.

- **CLI one-shot** (`bun run sync`) — ideal para cron.
- **Servidor Express** (`bun run start`) — sincroniza al arrancar y expone
  `POST /sync` para disparar la actualización bajo demanda.

---

## Requisitos

- [Bun](https://bun.sh) >= 1.2
- nginx (sólo para `link.sh`, en el servidor Linux)

## Instalación

```bash
git clone https://github.com/aramirez92/nginx-sync.git
cd nginx-sync
bun install
cp .env.example .env
$EDITOR .env          # completar ENDPOINT_URL y SYNC_TOKEN
```

## Configuración

Todas las variables van en `.env` (Bun lo carga solo, no hace falta `dotenv`).

| Variable | Obligatoria | Default | Descripción |
|---|---|---|---|
| `ENDPOINT_URL` | **sí** | — | URL http/https que devuelve el archivo de config en texto plano. |
| `OUTPUT_FILENAME` | no | `default.conf` | Nombre del archivo dentro de `OUTPUT_DIR`. Sin barras ni `..`. |
| `OUTPUT_DIR` | no | `sites-enabled` | Directorio de salida, relativo a la raíz del proyecto. |
| `PORT` | no | `3000` | Puerto del servidor Express. |
| `SYNC_TOKEN` | no | vacío | Token bearer para `POST /sync`. **Vacío ⇒ la ruta responde 503.** |
| `ENDPOINT_AUTH` | no | — | Valor del header `Authorization` al llamar a `ENDPOINT_URL`. Ej: `Bearer abc123`. |
| `REQUEST_TIMEOUT_MS` | no | `15000` | Timeout de la descarga. |
| `SYNC_ON_BOOT` | no | `true` | Sincronizar al arrancar el servidor. |

## Uso

### Sincronización única (cron)

```bash
bun run sync
```

Sale con código `0` si escribió el archivo, `1` si falló. Ejemplo de crontab
(cada 5 minutos):

```cron
*/5 * * * * cd /opt/nginx-sync && /home/USUARIO/.bun/bin/bun run sync >> /var/log/nginx-sync.log 2>&1
```

### Servidor

```bash
bun run start     # producción
bun run dev       # con --watch
```

| Ruta | Auth | Respuesta |
|---|---|---|
| `GET /health` | — | `200` con la config activa y el resultado del último sync. |
| `POST /sync` | `Authorization: Bearer $SYNC_TOKEN` | `200` con `{path, bytes, durationMs, fetchedAt}`. |

```bash
curl localhost:3000/health
curl -X POST -H "Authorization: Bearer $SYNC_TOKEN" localhost:3000/sync
```

Códigos de error de `POST /sync`:

| Código | Motivo |
|---|---|
| `401` | Token ausente o incorrecto. |
| `503` | `SYNC_TOKEN` sin configurar: la ruta está deshabilitada por diseño. |
| `502` | El endpoint remoto falló, respondió vacío, o no se pudo escribir el archivo. |

### Enlazar nginx

```bash
sudo ./link.sh
```

Deja `/etc/nginx/sites-enabled` → `<ruta-del-proyecto>/sites-enabled`, valida con
`nginx -t` y recarga el servicio.

> **Advertencia:** `link.sh` reemplaza `/etc/nginx/sites-enabled` en el sistema y
> corre como root. Antes de mover nada hace un backup con timestamp
> (`/etc/nginx/sites-enabled.bak.AAAAMMDDHHMMSS`) y, si `nginx -t` falla, borra el
> symlink y restaura el backup automáticamente. Aun así conviene probarlo primero
> en una máquina de pruebas.

Ensayo en seco, sin tocar el path real ni recargar nginx:

```bash
NGINX_SITES_ENABLED=/tmp/fake-sites-enabled sudo -E ./link.sh
```

El script es idempotente: si el symlink ya apunta al destino correcto, sale sin
hacer nada.

> `link.sh` es para el servidor **Linux**. En macOS no existen
> `/etc/nginx/sites-enabled` ni `systemctl`.

## Garantías de seguridad y robustez

- **Escritura atómica.** El contenido se escribe en `<archivo>.tmp` y recién
  después se hace `rename()` sobre el destino. nginx nunca lee un archivo a medio
  escribir.
- **Nunca se pisa una config buena con una mala.** Si el endpoint devuelve un
  error HTTP, un cuerpo vacío o se cae la red, el archivo anterior queda intacto.
- **Sin path traversal.** `OUTPUT_FILENAME` se valida: nada de barras ni `..`.
- **`/sync` cerrado por defecto.** Sin `SYNC_TOKEN` la ruta no queda abierta,
  responde `503`. El token se compara con `timingSafeEqual`.
- **Un sync a la vez.** Dos llamadas concurrentes comparten la misma promesa, no
  disparan dos escrituras.
- **Arranque tolerante a fallos.** Si el sync inicial falla, el servidor igual
  levanta: la config previa sigue sirviendo y `/sync` permite reintentar.

## Estructura

```
nginx-sync/
├── src/
│   ├── config.ts      # carga y valida las variables de entorno
│   ├── sync.ts        # descarga y escritura atómica (+ modo CLI)
│   ├── server.ts      # rutas Express y control de concurrencia
│   └── index.ts       # entrypoint: sync inicial, listen, apagado limpio
├── sites-enabled/     # destino de la descarga (contenido no versionado)
├── link.sh            # symlink de /etc/nginx/sites-enabled (root)
├── .env.example
├── tsconfig.json
└── package.json
```

## Scripts

| Comando | Qué hace |
|---|---|
| `bun run start` | Servidor Express. |
| `bun run dev` | Servidor con recarga en caliente. |
| `bun run sync` | Sincronización única y salida. |
| `bun run typecheck` | `tsc --noEmit`. |

## Despliegue sugerido (systemd)

`/etc/systemd/system/nginx-sync.service`:

```ini
[Unit]
Description=nginx-sync
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/nginx-sync
ExecStart=/usr/local/bin/bun run src/index.ts
Restart=on-failure
User=nginx-sync

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now nginx-sync
```

El usuario del servicio necesita permiso de escritura sobre
`/opt/nginx-sync/sites-enabled`.

## Licencia

MIT

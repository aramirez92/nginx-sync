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
- nginx (sólo para `link.sh` y el reload, en el servidor Linux)
- [PM2](https://pm2.keymetrics.io) (opcional, para el despliegue con PM2)

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
| `NGINX_RELOAD` | no | `false` | Recargar nginx cuando la config **cambia**. Requiere sudoers (ver abajo). |
| `NGINX_TEST_CMD` | no | `sudo nginx -t` | Validación previa al reload. Vacío ⇒ se omite (no recomendado). |
| `NGINX_RELOAD_CMD` | no | `sudo systemctl reload nginx` | Comando de recarga. |
| `RETRY_DELAY_MS` | no | `30000` | Espera entre reintentos cuando la descarga falla. |
| `RETRY_MAX_ATTEMPTS` | no | `0` | Intentos del servidor. `0` = reintentar indefinidamente. |
| `CLI_RETRY_MAX_ATTEMPTS` | no | `3` | Intentos del CLI one-shot antes de rendirse. |

## Uso

### Sincronización única (cron)

```bash
bun run sync
```

Sale con código `0` si todo salió bien, `1` si la descarga o el reload fallaron.
Ante un fallo reintenta cada `RETRY_DELAY_MS` hasta `CLI_RETRY_MAX_ATTEMPTS` veces.

Se puede agendar con PM2 (ver más abajo) o con crontab:

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
| `GET /health` | — | `200` con la config activa, la política de reintentos y el estado del último sync. |
| `POST /sync` | `Authorization: Bearer $SYNC_TOKEN` | `200` con `{path, bytes, changed, reloaded, durationMs, fetchedAt}`. |

`changed` indica si el contenido difería del que ya estaba en disco; `reloaded`,
si por eso se recargó nginx. Si el reload falla, la respuesta suma `reloadError`
pero el archivo igual quedó escrito.

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

## Recarga automática de nginx

Con `NGINX_RELOAD=true`, cada vez que la config descargada **cambia** (y sólo
entonces) se ejecuta:

```
sudo nginx -t  &&  sudo systemctl reload nginx
```

Si `nginx -t` falla, **no** se recarga: nginx sigue con la configuración vieja y
el error queda en el log y en `reloadError`. El archivo descargado ya está en
disco, así que se puede corregir y reintentar con `POST /sync`.

Para que el servicio pueda correr esos dos comandos sin contraseña, crear la
regla de sudoers — siempre con `visudo`, que valida la sintaxis antes de guardar:

```bash
sudo visudo -f /etc/sudoers.d/nginx-sync
```

```sudoers
nginx-sync ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /usr/bin/systemctl reload nginx
```

Verificar las rutas reales con `which nginx` y `which systemctl`: si no coinciden
exactamente con las del archivo, sudo pedirá contraseña igual.

> **Seguridad:** listar los comandos exactos, nunca `NOPASSWD: ALL`. Los comandos
> salen de `.env`, así que quien pueda escribir ese archivo elige qué se ejecuta
> como root: dejar `.env` en `600` y con dueño el usuario del servicio
> (`chmod 600 .env && chown nginx-sync .env`). El usuario del servicio debe ser
> dedicado y sin shell de login.

Comprobar la regla sin tocar nginx:

```bash
sudo -u nginx-sync sudo -n nginx -t
```

## Reintentos

Si la descarga falla (endpoint caído, timeout, 5xx, respuesta vacía), se reintenta
cada `RETRY_DELAY_MS` (30 s por defecto):

| Contexto | Intentos | Al agotarlos |
|---|---|---|
| Servidor (`bun run start`) | `RETRY_MAX_ATTEMPTS`, `0` = sin límite | Sigue reintentando; `GET /health` muestra `state: "failing"`. |
| CLI (`bun run sync`) | `CLI_RETRY_MAX_ATTEMPTS` (3) | Sale con código `1`. |

Mientras tanto la configuración anterior sigue en `sites-enabled/` y nginx sigue
sirviéndola. Un fallo del endpoint nunca deja al servidor sin config.

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
  levanta: la config previa sigue sirviendo y se reintenta en background.
- **Sin reloads inútiles.** Se compara el SHA-256 del contenido: si no cambió, no
  se reescribe el archivo ni se recarga nginx.
- **Nunca se recarga una config inválida.** `nginx -t` corre antes del reload y lo
  aborta si falla.
- **Comandos sin shell.** El test y el reload se ejecutan como argv directo, sin
  `sh -c`: no hay interpolación, globs, ni encadenamiento con `;` o `&&`.

## Arquitectura

Separada por capas, con las dependencias apuntando siempre hacia el dominio:

```
nginx-sync/
├── src/
│   ├── domain/
│   │   └── types.ts              # contratos: ConfigSource, ConfigStore, Reloader, Logger
│   ├── infra/
│   │   ├── http-config-source.ts # descarga por HTTP
│   │   ├── file-config-store.ts  # escritura atómica + detección de cambios
│   │   ├── nginx-reloader.ts     # nginx -t + reload (y NoopReloader)
│   │   └── console-logger.ts     # logging síncrono (writeSync)
│   ├── app/
│   │   ├── sync-service.ts       # orquesta descargar → escribir → recargar
│   │   ├── retry.ts              # política de reintentos
│   │   └── sync-supervisor.ts    # reintentos en background + estado para /health
│   ├── config.ts                 # variables de entorno validadas
│   ├── composition.ts            # composition root: arma el grafo de objetos
│   ├── server.ts                 # rutas Express (recibe el supervisor inyectado)
│   ├── index.ts                  # entrypoint del servidor
│   └── sync.ts                   # entrypoint CLI one-shot
├── sites-enabled/                # destino de la descarga (contenido no versionado)
├── ecosystem.config.cjs          # configuración de PM2
├── link.sh                       # symlink de /etc/nginx/sites-enabled (root)
├── .env.example
├── tsconfig.json
└── package.json
```

`app/` y `domain/` no conocen `fetch`, ni el sistema de archivos, ni PM2:
sólo los contratos. `composition.ts` es el único lugar que instancia las clases
concretas, así que cambiar el origen de la config o el servidor a recargar es
cambiar una línea ahí. Los tests inyectan fakes en memoria por eso mismo.

## Scripts

| Comando | Qué hace |
|---|---|
| `bun run start` | Servidor Express. |
| `bun run dev` | Servidor con recarga en caliente. |
| `bun run sync` | Sincronización única y salida. |
| `bun test` | Tests unitarios. |
| `bun run typecheck` | `tsc --noEmit`. |
| `bun run pm2:start` | Arranca las apps de `ecosystem.config.cjs`. |
| `bun run pm2:logs` | Logs del webservice. |
| `bun run pm2:status` | Estado de los procesos. |
| `bun run pm2:restart` / `pm2:stop` / `pm2:delete` | Control de las apps. |

---

# Despliegue

Dos opciones equivalentes: **PM2** (más simple de operar, logs y monitoreo
incluidos) o **systemd** (sin dependencias extra). Elegir una, no las dos: si
ambas corren el mismo servicio, van a competir por el puerto.

Los pasos 1 a 4 son comunes.

### 1. Instalar Bun

```bash
curl -fsSL https://bun.sh/install | bash
sudo ln -sf ~/.bun/bin/bun /usr/local/bin/bun    # ruta estable para PM2/systemd
bun --version
```

### 2. Usuario de servicio y código

```bash
sudo useradd --system --home /opt/nginx-sync --shell /usr/sbin/nologin nginx-sync
sudo git clone https://github.com/aramirez92/nginx-sync.git /opt/nginx-sync
sudo chown -R nginx-sync:nginx-sync /opt/nginx-sync
cd /opt/nginx-sync
sudo -u nginx-sync bun install
```

### 3. Configurar `.env`

```bash
sudo -u nginx-sync cp .env.example .env
sudo -u nginx-sync $EDITOR .env      # ENDPOINT_URL, SYNC_TOKEN, NGINX_RELOAD=true
sudo chmod 600 .env
```

Generar un token: `openssl rand -hex 32`.

### 4. Enlazar nginx y habilitar el reload

```bash
sudo ./link.sh                                    # /etc/nginx/sites-enabled -> ./sites-enabled
sudo visudo -f /etc/sudoers.d/nginx-sync          # ver "Recarga automática de nginx"
sudo -u nginx-sync bun run sync                   # primera descarga, de prueba
```

---

## Opción A — PM2

### A.1 Instalar PM2

```bash
sudo npm install -g pm2      # o: bun install -g pm2
pm2 --version
```

### A.2 Arrancar

```bash
cd /opt/nginx-sync
sudo -u nginx-sync pm2 start ecosystem.config.cjs
sudo -u nginx-sync pm2 status
```

`ecosystem.config.cjs` define dos apps:

| App | Qué hace |
|---|---|
| `nginx-sync` | El webservice (`/health` y `/sync`). Se reinicia solo si se cae. |
| `nginx-sync-cron` | Corre `bun run sync` cada 5 minutos y termina (`cron_restart`). |

Para levantar sólo una: `pm2 start ecosystem.config.cjs --only nginx-sync`.
Para cambiar la frecuencia, editar `cron_restart` en el ecosystem.

Si `bun` no está en el `PATH` del servicio, indicarlo explícitamente:

```bash
BUN_PATH=/usr/local/bin/bun pm2 start ecosystem.config.cjs
```

### A.3 Arranque automático con el sistema

```bash
sudo -u nginx-sync pm2 save                 # guarda la lista de procesos actual
sudo -u nginx-sync pm2 startup              # imprime un comando...
# ...copiar y ejecutar el comando que imprimió (empieza con "sudo env PATH=...")
```

### A.4 Operación diaria

```bash
pm2 status                       # estado de las dos apps
pm2 logs nginx-sync              # logs en vivo
pm2 logs nginx-sync --lines 100  # últimas 100 líneas
pm2 monit                        # CPU y memoria en vivo
pm2 restart nginx-sync           # reiniciar el webservice
pm2 restart nginx-sync-cron      # forzar un sync ya mismo
```

Los logs también quedan en `logs/nginx-sync.out.log` y `logs/nginx-sync.err.log`.

### A.5 Rotación de logs

Sin esto los logs crecen sin límite:

```bash
pm2 install pm2-logrotate
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 7
```

### A.6 Actualizar

```bash
cd /opt/nginx-sync
sudo -u nginx-sync git pull
sudo -u nginx-sync bun install
sudo -u nginx-sync pm2 reload ecosystem.config.cjs
```

---

## Opción B — systemd

### B.1 Crear la unidad

```bash
sudo $EDITOR /etc/systemd/system/nginx-sync.service
```

```ini
[Unit]
Description=nginx-sync
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nginx-sync
Group=nginx-sync
WorkingDirectory=/opt/nginx-sync
ExecStart=/usr/local/bin/bun run src/index.ts
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

`ExecStart` necesita la ruta absoluta de `bun` (`which bun`); systemd no usa el
`PATH` del login.

### B.2 Habilitar y arrancar

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nginx-sync
sudo systemctl status nginx-sync
```

### B.3 Sincronización periódica

Con un timer de systemd — `/etc/systemd/system/nginx-sync-cron.service`:

```ini
[Unit]
Description=nginx-sync (sincronización única)

[Service]
Type=oneshot
User=nginx-sync
WorkingDirectory=/opt/nginx-sync
ExecStart=/usr/local/bin/bun run src/sync.ts
```

`/etc/systemd/system/nginx-sync-cron.timer`:

```ini
[Unit]
Description=Sincroniza la config de nginx cada 5 minutos

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nginx-sync-cron.timer
systemctl list-timers nginx-sync-cron.timer
```

### B.4 Operación diaria

```bash
journalctl -u nginx-sync -f            # logs en vivo
journalctl -u nginx-sync-cron --since today
sudo systemctl restart nginx-sync
```

### B.5 Actualizar

```bash
cd /opt/nginx-sync
sudo -u nginx-sync git pull
sudo -u nginx-sync bun install
sudo systemctl restart nginx-sync
```

---

## Verificar el despliegue

```bash
curl -s localhost:3000/health | jq                                  # sync.state debe ser "ok"
curl -s -X POST -H "Authorization: Bearer $SYNC_TOKEN" localhost:3000/sync | jq
ls -l /etc/nginx/sites-enabled/                                     # symlink al proyecto
sudo nginx -t
```

Si `sync.state` queda en `"failing"`, el campo `error` dice por qué y
`nextRetryInMs` cuándo vuelve a intentar.

## Licencia

MIT

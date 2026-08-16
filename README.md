# nginx-sync

Descarga la configuración de nginx desde un endpoint HTTP remoto y la deja en el
directorio `sites-enabled/` de este proyecto. Un script con `sudo` enlaza
`/etc/nginx/sites-enabled` a ese directorio, así nginx sirve siempre lo último
que se sincronizó.

Corre con [Bun](https://bun.sh) y TypeScript. Sin paso de build.

- **Servidor Express** (`bun run start`) — sincroniza al arrancar y expone
  `POST /sync` para disparar la actualización bajo demanda. Es lo que corre como
  servicio de systemd.
- **CLI one-shot** (`bun run sync`) — una sincronización manual y sale.

---

## Requisitos

- Para desarrollar: [Bun](https://bun.sh) >= 1.2
- Para desplegar: un Linux con systemd. Nada más — un solo comando baja el
  código desde GitHub e instala lo que falte (bun, nginx, curl, unzip, sudo,
  git, y nvm + Node LTS como extra):

```bash
curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh | sudo bash
```

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

### Sincronización manual

```bash
bun run sync
```

Descarga, escribe y sale. Código `0` si todo salió bien, `1` si la descarga o el
reload fallaron. Ante un fallo reintenta cada `RETRY_DELAY_MS` hasta
`CLI_RETRY_MAX_ATTEMPTS` veces.

Con el servicio ya andando, lo normal es usar `POST /sync` en vez de esto.

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

## Recarga automática de nginx

Con `NGINX_RELOAD=true`, cada vez que la config descargada **cambia** (y sólo
entonces) se ejecuta:

```
sudo nginx -t  &&  sudo systemctl reload nginx
```

Si `nginx -t` falla, **no** se recarga: nginx sigue con la configuración vieja y
el error queda en el log y en `reloadError`. El archivo descargado ya está en
disco, así que se puede corregir y reintentar con `POST /sync`.

Para que el servicio pueda correr esos dos comandos sin contraseña hace falta una
regla de sudoers. **`install.sh` la crea sola**, resolviendo las rutas reales y
validándola con `visudo -cf` (`--no-reload` la omite). A mano sería así — siempre
con `visudo`, que valida la sintaxis antes de guardar:

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
├── deploy/
│   └── nginx-sync.service        # plantilla de la unidad de systemd
├── bootstrap.sh                  # one-liner: baja el tar.gz de GitHub y corre install.sh (root)
├── install.sh                    # instalación completa: deps, bun, .env, symlink, servicio (root)
├── .env.example
├── tsconfig.json
└── package.json
```

`app/` y `domain/` no conocen `fetch`, ni el sistema de archivos, ni systemd:
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
| `sudo ./install.sh` | Instala dependencias, runtime, config y servicio de systemd. |
| `curl … bootstrap.sh \| sudo bash` | Lo mismo, bajando antes el código desde GitHub. |

---

# Despliegue

Un servicio de systemd. Probado en Debian/Ubuntu. El servidor sólo necesita
systemd: el resto lo bajan e instalan los scripts.

### 1. Un comando

```bash
curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh | sudo bash
```

`bootstrap.sh` baja el código desde GitHub (tar.gz), lo deja en `/opt/nginx-sync`
y corre `install.sh`. Si no hay `.env`, el instalador lo arma preguntando (URL
del endpoint, token —lo puede generar solo—, puerto, nombre del archivo) y lo
guarda con permisos `600`.

Desatendido, sin preguntas — lo que va después de `--` se le pasa a `install.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh \
  | sudo bash -s -- --non-interactive --endpoint-url https://tu-servidor/nginx.conf
```

Variables del bootstrap:

| Variable | Default | Qué controla |
|---|---|---|
| `NGINX_SYNC_DIR` | `/opt/nginx-sync` | Dónde queda el código. |
| `NGINX_SYNC_REF` | `main` | Rama, tag o commit a bajar. |
| `NGINX_SYNC_REPO` | `aramirez92/nginx-sync` | Repo de origen (un fork, por ejemplo). |

Volver a correrlo actualiza el código: ni `.env` ni los `.conf` descargados están
en el repo, así que la extracción no los pisa.

### 2. O clonando, si preferís git

```bash
sudo git clone https://github.com/aramirez92/nginx-sync.git /opt/nginx-sync
cd /opt/nginx-sync
sudo ./install.sh --dry-run    # ver el plan, sin tocar nada
sudo ./install.sh              # instalar de verdad
```

Con el token fuera del historial: `ENDPOINT_URL=... SYNC_TOKEN=... sudo -E ./install.sh -y`.

Un solo comando hace todo, en este orden:

| Paso | Qué hace |
|---|---|
| Preflight | Detecta gestor de paquetes y systemd, y junta **todo** lo que falta antes de tocar nada. Sin systemd, aborta ahí. |
| Dependencias | Instala lo que falte (`curl`, `unzip`, `git`, `tar`, `sudo`, `nginx`, `useradd`) con `apt/dnf/yum/zypper/apk/pacman`, y re-verifica cada comando. |
| Bun | Si no está, lo baja con `BUN_INSTALL=/usr/local` → binario real en `/usr/local/bin/bun`. Si ya está pero cuelga de un home inaccesible, lo copia ahí — el arreglo del `203/EXEC`. |
| nvm + Node | nvm en `/usr/local/nvm` (versión fijada) + Node LTS, con symlinks en `/usr/local/bin` y `/etc/profile.d/nvm.sh`. Extra del server: si falla, avisa y sigue. |
| Usuario | Crea `nginx-sync` (`--system`, sin home, sin shell) si no existe. |
| Configuración | Wizard o flags/entorno → escribe `.env` conservando los comentarios del ejemplo. Prueba que el endpoint responda (aviso, no error) y corre `bun install` si falta `node_modules/`. |
| Permisos | `chown -R` del proyecto, `.env` a `600`. |
| Verifica | `sudo -u nginx-sync bun --version` **antes** de instalar; si falla, aborta con el motivo. |
| Sudoers | Los dos comandos exactos para recargar nginx, validados con `visudo -cf`. |
| Symlink | `/etc/nginx/sites-enabled` → el proyecto, con backup con timestamp del anterior y rollback si `nginx -t` falla. |
| Servicio | Genera la unidad desde `deploy/nginx-sync.service`, `daemon-reload`, `enable --now`. |
| Verificación | Espera a que la unidad quede activa, consulta `/health` y confirma que el archivo se descargó. Si no arranca, imprime `status` + journal y sale con `1`. |

| Flag | Para qué |
|---|---|
| `--dry-run` | Imprime el plan completo y sale. No escribe nada, no pregunta nada. |
| `--non-interactive`, `-y` | Nunca pregunta. Falla listando la config obligatoria que falte. |
| `--endpoint-url`, `--sync-token`, `--endpoint-auth`, `--port` | Valores del `.env` sin wizard. Equivalen a las variables de entorno del mismo nombre (con `sudo -E`). |
| `--no-install-deps` | Valida las dependencias del sistema pero no instala nada. |
| `--no-nvm` | Omite nvm + Node. |
| `--no-reload` | Sin regla de sudoers ni reload de nginx. |

> **Advertencia:** `install.sh` corre como root: instala paquetes del sistema,
> baja bun y nvm desde internet (`bun.sh`, `raw.githubusercontent.com`),
> reemplaza `/etc/nginx/sites-enabled`, escribe en `/etc/systemd/system/`,
> `/etc/sudoers.d/` y `/etc/profile.d/`, crea un usuario del sistema y hace
> `chown -R` del proyecto.
> El symlink de nginx se hace con backup con timestamp
> (`/etc/nginx/sites-enabled.bak.AAAAMMDDHHMMSS`) y se revierte solo si `nginx -t`
> falla; la regla de sudoers lista los dos comandos exactos, nunca
> `NOPASSWD: ALL`, y se valida antes de instalarse. Conviene correr primero
> `--dry-run`.

Es idempotente: se puede volver a correr después de un `git pull`.

### 3. Verificar

`install.sh` ya hace esta verificación al final. A mano:

```bash
systemctl status nginx-sync                  # Active: active (running)
curl -s localhost:3000/health | jq           # sync.state debe ser "ok"
ls -l /etc/nginx/sites-enabled/              # el symlink al proyecto
journalctl -u nginx-sync -f                  # logs en vivo
```

## Operación

```bash
sudo systemctl restart nginx-sync
sudo systemctl stop nginx-sync
journalctl -u nginx-sync --since "1 hour ago"

# forzar una sincronización sin reiniciar
curl -X POST -H "Authorization: Bearer $SYNC_TOKEN" localhost:3000/sync
```

Actualizar:

```bash
# si instalaste con el one-liner (no toca .env ni sites-enabled/)
curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh | sudo bash

# si clonaste
cd /opt/nginx-sync
sudo git pull
sudo -u nginx-sync bun install
sudo systemctl restart nginx-sync
```

## Diagnóstico

| Síntoma en `systemctl status` | Causa | Arreglo |
|---|---|---|
| `status=203/EXEC` | El usuario del servicio no puede ejecutar el binario de `ExecStart`. Típico: bun bajo `/root/.bun/`, con `/root` en `700`. | Confirmarlo con `sudo -u nginx-sync /usr/local/bin/bun --version`. Reinstalar bun con `BUN_INSTALL=/usr/local`, o correr `install.sh`, que lo copia solo. |
| `status=200/CHDIR` | `WorkingDirectory` no existe o el usuario no puede entrar. | `sudo chown -R nginx-sync /opt/nginx-sync` |
| `status=203/EXEC` con la ruta correcta | El binario perdió el bit de ejecución. | `sudo chmod 755 /usr/local/bin/bun` |
| Arranca y muere: `[config] Falta la variable de entorno ENDPOINT_URL` | Falta `.env`, o el usuario no puede leerlo. | `sudo chown nginx-sync /opt/nginx-sync/.env` |
| En el journal: `sudo: a password is required` | Falta la regla de sudoers, o las rutas no coinciden exactamente. | `sudo ./install.sh`, y comparar con `which nginx`. |
| `Permission denied` al escribir la config | El usuario no puede escribir en `sites-enabled/`. | `sudo chown -R nginx-sync /opt/nginx-sync/sites-enabled` |
| `nginx -t` falla al instalar | La config descargada es inválida. `install.sh` ya restauró el `sites-enabled` anterior. | Revisar el archivo en `sites-enabled/` y volver a correr `install.sh`. |
| `install.sh`: `no reconocí el gestor de paquetes` | Distro fuera de la lista (`apt/dnf/yum/zypper/apk/pacman`). | Instalar a mano lo que liste el preflight y volver a correr. |
| `E: dpkg was interrupted...` | Un `apt` anterior quedó a medias (Ctrl-C, corte, imagen mal cerrada). Es previo a nginx-sync. | `install.sh` lo detecta y corre `dpkg --configure -a` solo. Si aún así falla: `sudo dpkg --configure -a && sudo apt-get -f install`. |
| `install.sh`: `nvm/Node no quedaron instalados` | Sin salida a `raw.githubusercontent.com`, o la instalación de nvm falló. | No es fatal: nginx-sync corre con bun. Repetir con `--no-nvm` para saltearlo. |

Ensayar el symlink sin tocar `/etc/nginx`:

```bash
NGINX_SITES_ENABLED=/tmp/fake-sites-enabled sudo -E ./install.sh
```

Ver el detalle completo del fallo:

```bash
systemctl status nginx-sync --no-pager --full
journalctl -u nginx-sync -n 50 --no-pager
```


## Licencia

MIT

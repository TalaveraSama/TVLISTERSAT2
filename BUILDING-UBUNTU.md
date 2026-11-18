# Mini Astra: compilación en Ubuntu 22.04 y 24.04

Este repositorio es una instantánea antigua de Astra 4.4.187 (2015), no el binario propietario Astra Cesbo 5.65. Se puede compilar como una base de streaming MPEG-TS/Lua, pero no es compatible con la API, interfaz web, licencia ni todas las funciones de Cesbo 5.65.

## Instalación automática desde GitHub

Para compilar e instalar la versión de la rama `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/TalaveraSama/TVLISTERSAT2/main/install.sh -o /tmp/mini-astra-install.sh
sudo bash /tmp/mini-astra-install.sh
```

Para una release concreta, cambia `MINI_ASTRA_REF` por el tag publicado:

```bash
sudo MINI_ASTRA_REF=v0.1.0 bash /tmp/mini-astra-install.sh
```

El instalador requiere Ubuntu 22.04 o 24.04 x86_64, `systemd`, red disponible y permisos de root. Descarga el código, ejecuta las pruebas estáticas, compila localmente y habilita `mini-astra.service`. No descarga binarios ejecutables de terceros. La ausencia de `libdvbcsa-dev`, `libssl-dev` o `libpq-dev` solo desactiva módulos opcionales; el núcleo UDP/HTTP se compila.

Si una instalación anterior muestra `signal=ABRT`, revisa el journal: la causa más común es `getifaddrs() failed`. Esta versión de Astra llama `utils.ifaddrs()` al arrancar y aborta si falla; `getifaddrs()` necesita `AF_NETLINK`, por lo que la unidad debe incluir:

```ini
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
```

Si el servicio responde una petición y luego muere con `signal=SEGV`, el journal mostrará `asc_socket_set_on_read (sock=0x0)`. Motivo: en esta API el callback de ruta se invoca **dos veces**, la segunda con `request == nil` para avisar del cierre de la conexión; responder en ese caso escribe sobre un socket ya cerrado. Todo handler debe empezar por:

```lua
if not request then return end
```

Ambos fallos están cubiertos por `tests/test-static.sh`.

Para desinstalar sin borrar el estado:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/TalaveraSama/TVLISTERSAT2/main/uninstall.sh | bash
```

## Dependencias

```bash
sudo apt update
sudo apt install -y build-essential git curl pkg-config
# Opcional: descifrado DVB-CSA
sudo apt install -y libdvbcsa-dev
# Opcional: DVB y PostgreSQL, según los módulos que se quieran usar
sudo apt install -y linux-headers-$(uname -r) libpq-dev
```

Ubuntu 22.04 y 24.04 usan GCC/glibc modernos. El código trae su propia copia de Lua y no necesita liblua externa.

## Compilación mínima

Desde el directorio del repositorio:

```bash
./configure.sh --debug --bin=/usr/local/bin/astra-mini
make -j"$(nproc)"
```

La compilación normal incluye los módulos presentes en `modules/`. Para instalar el binario:

```bash
sudo install -m 0755 ./astra /usr/local/bin/astra-mini
```

Si se quiere activar DVB-CSA y está disponible la biblioteca:

```bash
./configure.sh --with-libdvbcsa --bin=/usr/local/bin/astra-mini
make -j"$(nproc)"
```

## Ejecución

El ejecutable antiguo espera un script Lua como primer argumento:

```bash
/usr/local/bin/astra-mini ./examples/relay.lua
```

Para una operación tipo servicio se incluye el wrapper [`mini-astra`](mini-astra), una configuración HTTP de estado en [`scripts/mini-astra.lua`](scripts/mini-astra.lua) y la unidad [`systemd/mini-astra.service`](systemd/mini-astra.service):

```bash
sudo install -m 0755 mini-astra /usr/local/bin/mini-astra
sudo /usr/local/bin/mini-astra install
sudo /usr/local/bin/mini-astra init
sudo systemctl enable --now mini-astra
curl --fail http://127.0.0.1:8000/healthz
curl --fail http://127.0.0.1:8000/readyz
curl --fail http://127.0.0.1:8000/api/v1/status
curl --fail http://127.0.0.1:8000/api/v1/streams

# Validación estática sin hardware DVB
sh tests/test-static.sh
```

La interfaz web/API moderna de Astra Cesbo 5.65 no está incluida en esta fuente. La API anterior es una capa propia mínima de salud/estado/streams; no se debe usar `astra init`, licencia, usuarios web o endpoints de 5.65 con este binario.

## Auditoría operativa y límites

- `mini-astra install` copia el binario y la configuración; `mini-astra init` crea el usuario de sistema, el directorio de estado y la unidad systemd.
- La unidad espera que el binario exista en `/usr/local/bin/astra-mini` y la configuración en `/etc/mini-astra/mini-astra.lua`.
- El endpoint `/api/v1/streams` describe el servicio de control y no administra todavía entradas UDP dinámicas.
- El ejemplo [`examples/relay.lua`](examples/relay.lua) sí conecta `udp_input` con `udp_output` usando `input:stream()` y mantiene vivo el proceso con el módulo `timer`.
- El wrapper no intenta instalar ni retirar licencias, ni ejecutar código descargado de Cesbo.
- En este entorno Windows se validaron sintaxis shell y pruebas estáticas; la compilación y prueba de sockets deben ejecutarse en Ubuntu 22.04/24.04.

## Crear streams desde el panel

El panel replica el modelo de creación de Cesbo 5.x: `Enable`, `Name`, `ID`, `Create Multi Program Stream`, `Description`, lista de entradas, lista de salidas y los botones `APPLY`, `CLONE`, `ANALYZE`, `CANCEL`.

Las direcciones usan la misma sintaxis:

| Tipo | Formato | Ejemplo |
|---|---|---|
| DVB | `dvb://frecuencia-polarización-simbolrate#pnr=N&adapter=A&type=S2` | `dvb://11262-h-30000#pnr=1937&adapter=0&type=S2` |
| UDP entrada | `udp://grupo:puerto` | `udp://239.2.2.10:2000` |
| RTP entrada | `rtp://grupo:puerto` | `rtp://239.2.2.10:2000` |
| Archivo | `file:///ruta/archivo.ts?loop=1` | `file:///srv/promo.ts?loop=1` |
| UDP salida | `udp://interfaz@grupo:puerto` | `udp://enp1s0@230.2.2.10:2000` |
| RTP salida | `rtp://interfaz@grupo:puerto` | `rtp://enp1s0@230.2.2.10:2000` |

La interfaz se resuelve a su IPv4 real mediante `utils.ifaddrs()`; también se acepta una IP directamente.

### Equivalencia con los módulos de 4.4.187

| Dirección | Módulo creado |
|---|---|
| `udp://…` / `rtp://…` (entrada) | `udp_input` con `rtp = true/false` |
| `dvb://…#pnr=N` | `dvb_input` + `channel{ pnr = N }` |
| `file://…` | `file_input` con `loop` |
| `udp://iface@…` (salida) | `udp_output` con `localaddr` resuelto |

### API

```bash
# listar
curl -s http://192.168.1.22:8000/api/v1/streams

# crear o actualizar (APPLY)
curl -s -X POST http://192.168.1.22:8000/api/v1/streams \
  -H 'Content-Type: application/json' \
  -d '{"action":"save","stream":{
        "id":"a0jt","name":"America TV HD","enabled":true,
        "inputs":["dvb://11262-h-30000#pnr=1937&adapter=0&type=S2"],
        "outputs":["udp://enp1s0@230.2.2.10:2000"]}}'

# validar sin aplicar (ANALYZE)
curl -s -X POST http://192.168.1.22:8000/api/v1/streams \
  -H 'Content-Type: application/json' \
  -d '{"action":"verify","stream":{"id":"a0jt","inputs":["udp://239.2.2.10:2000"],"outputs":[]}}'

# detener / arrancar / clonar / eliminar
#   "action": "stop" | "start" | "clone" | "delete"
```

Los streams se guardan en `/var/lib/mini-astra/streams.json` y se rearrancan al iniciar el servicio si están habilitados.

### Límites reales de esta base

- `dvb://` requiere adaptador DVB, drivers y permisos; sin hardware el módulo no entrega señal. Se puede desactivar con `Environment=MINI_ASTRA_DVB=0`.
- No hay transcodificación, EPG, ni gestión de usuarios.
- Las pestañas `Groups`, `Service`, `Remap`, `Backup`, `EPG` y `Advanced` se muestran por compatibilidad visual pero no están implementadas.
- Una sola entrada por stream (la primera de la lista); el resto se conserva como configuración.

## Acceso desde el navegador

La configuración incluye una página de estado en `/`. Por defecto el servicio solo escucha en `127.0.0.1`, así que primero hay que abrirlo a la red local mediante un drop-in:

```ini
# /etc/systemd/system/mini-astra.service.d/20-bind.conf
[Service]
Environment=MINI_ASTRA_BIND=0.0.0.0
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart mini-astra
```

Comprueba que escucha en todas las interfaces:

```bash
ss -ltn | grep ':8000'
```

Y abre en el navegador, sustituyendo la IP por la del servidor:

```text
http://192.168.1.22:8000/
```

La página muestra versión, estado y la tabla de streams, y se refresca sola cada 3 segundos. Datos disponibles:

| Ruta | Contenido |
|---|---|
| `/` | Panel HTML de estado |
| `/healthz` | `ok` en texto plano |
| `/readyz` | `{"status":"ready"}` |
| `/api/v1/status` | Estado completo en JSON |
| `/api/v1/streams` | Lista de streams en JSON |

Aviso: el panel no tiene autenticación. Es válido para una LAN de confianza; no lo expongas a Internet sin poner un proxy con autenticación delante. Si `ufw` está activo, abre el puerto:

```bash
sudo ufw allow 8000/tcp
```

## Diagnóstico

- `configure.sh` genera `Makefile` y `config.h`; ambos son artefactos locales ignorados por Git.
- `--static` puede fallar si no están instaladas las bibliotecas estáticas de glibc/pthread/dl.
- El módulo DVB depende de hardware, drivers y permisos del kernel; compilarlo no garantiza que exista un adaptador.
- El módulo PostgreSQL requiere headers y biblioteca de PostgreSQL.
- Para pruebas reproducibles, comenzar con UDP/RTP y MPEG-TS, sin hardware DVB ni softcam.

## Diferencia con Astra Cesbo 5.65

La documentación oficial de Cesbo describe un binario x86_64 con licencia, servicio systemd, interfaz web por defecto en el puerto 8000 y múltiples entradas/salidas (DVB, UDP/RTP, HLS/HTTP, SRT, RTSP, MPTS/SPTS, etc.). Esta instantánea no implementa de forma equivalente ese producto. Cualquier clon debe tratarse como un proyecto independiente y no reutilizar marcas, licencia ni mecanismos propietarios de Cesbo.

Fuentes: https://astra.cesbo.com/en/quick-start/ y https://astra.cesbo.com/en/quick-start/manage-service/

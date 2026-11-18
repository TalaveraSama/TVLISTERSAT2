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

## Diagnóstico

- `configure.sh` genera `Makefile` y `config.h`; ambos son artefactos locales ignorados por Git.
- `--static` puede fallar si no están instaladas las bibliotecas estáticas de glibc/pthread/dl.
- El módulo DVB depende de hardware, drivers y permisos del kernel; compilarlo no garantiza que exista un adaptador.
- El módulo PostgreSQL requiere headers y biblioteca de PostgreSQL.
- Para pruebas reproducibles, comenzar con UDP/RTP y MPEG-TS, sin hardware DVB ni softcam.

## Diferencia con Astra Cesbo 5.65

La documentación oficial de Cesbo describe un binario x86_64 con licencia, servicio systemd, interfaz web por defecto en el puerto 8000 y múltiples entradas/salidas (DVB, UDP/RTP, HLS/HTTP, SRT, RTSP, MPTS/SPTS, etc.). Esta instantánea no implementa de forma equivalente ese producto. Cualquier clon debe tratarse como un proyecto independiente y no reutilizar marcas, licencia ni mecanismos propietarios de Cesbo.

Fuentes: https://astra.cesbo.com/en/quick-start/ y https://astra.cesbo.com/en/quick-start/manage-service/

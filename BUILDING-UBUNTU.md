# Mini Astra: compilación en Ubuntu 22.04 y 24.04

Este repositorio es una instantánea antigua de Astra 4.4.187 (2015), no el binario propietario Astra Cesbo 5.65. Se puede compilar como una base de streaming MPEG-TS/Lua, pero no es compatible con la API, interfaz web, licencia ni todas las funciones de Cesbo 5.65.

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

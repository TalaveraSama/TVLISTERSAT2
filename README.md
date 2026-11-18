# Mini Astra (base heredada)

Este repositorio es una instantánea congelada el 1 de octubre de 2015 y corresponde a Astra **4.4.187**, no a Astra Cesbo 5.65. Es software GPL que proporciona un núcleo Lua para pipelines MPEG-TS y módulos de entrada/salida, pero no contiene la interfaz web, licencia ni la API del producto comercial actual.

## Estado

- Compatible como base de compilación en Linux moderno, incluyendo Ubuntu 22.04 y 24.04.
- Incluye módulos UDP/RTP, HTTP, MPEG-TS, DVB/ASI, archivo, análisis y Lua embebido.
- No es un clon binario ni funcionalmente equivalente a Astra Cesbo 5.65.
- La compilación e instalación están documentadas en [BUILDING-UBUNTU.md](BUILDING-UBUNTU.md).

## Operación Mini Astra

La entrega incluye una capa operativa propia:

- [`mini-astra`](mini-astra): wrapper con `build`, `install`, `init`, `run`, `status`, `logs`, `reload` y `health`.
- [`scripts/mini-astra.lua`](scripts/mini-astra.lua): configuración Lua con `/healthz`, `/readyz` y `/api/v1/status`.
- [`systemd/mini-astra.service`](systemd/mini-astra.service): servicio systemd para Ubuntu.
- [`examples/relay.lua`](examples/relay.lua): relay UDP MPEG-TS.

Las opciones de los módulos son las de esta versión heredada; no deben confundirse con el formato de configuración de Astra 5.x.

Para validar los archivos sin hardware ni Ubuntu local, ejecuta `sh tests/test-static.sh`. La guía completa de despliegue y pruebas está en [`BUILDING-UBUNTU.md`](BUILDING-UBUNTU.md) y [`tests/README.md`](tests/README.md).

## Instalación desde GitHub

El instalador compila desde el tag `main` y registra el servicio systemd:

```bash
curl -fsSL https://raw.githubusercontent.com/TalaveraSama/TVLISTERSAT2/main/install.sh -o /tmp/mini-astra-install.sh
sudo bash /tmp/mini-astra-install.sh
```

Para instalar una versión publicada, usa un tag explícito:

```bash
sudo MINI_ASTRA_REF=v0.1.0 bash /tmp/mini-astra-install.sh
```

El workflow [`release.yml`](.github/workflows/release.yml) genera paquetes separados para Ubuntu 22.04 y 24.04. Cada paquete contiene el binario, configuración, unidad systemd, instalador y suma SHA-256.

## Referencia oficial actual

La documentación de Cesbo describe un binario x86_64 con licencia, servicio systemd, interfaz web por defecto en el puerto 8000 y gestión de streams/adaptadores. Consulta https://astra.cesbo.com/en/quick-start/ para el producto oficial.

## Licencia

Consulta [COPYING](COPYING).
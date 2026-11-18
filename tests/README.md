# Pruebas

## Comprobación estática portable

En Ubuntu:

```bash
sh tests/test-static.sh
```

En PowerShell:

```powershell
pwsh -File tests/test-static.ps1
```

Estas pruebas no requieren hardware DVB, puertos de red abiertos ni un binario compilado. Verifican que la capa Mini Astra contiene sus archivos, endpoints de salud y directivas systemd esenciales.

## Prueba de servicio

Después de compilar e instalar en Ubuntu:

```bash
sudo systemctl enable --now mini-astra
curl --fail http://127.0.0.1:8000/healthz
curl --fail http://127.0.0.1:8000/readyz
curl --fail http://127.0.0.1:8000/api/v1/status
curl --fail http://127.0.0.1:8000/api/v1/streams
sudo systemctl stop mini-astra
```

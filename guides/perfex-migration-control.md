# Centro de migración Perfex

El servicio `perfex-migration` ejecuta una sola etapa y un solo workspace por proceso. El Centro
de control consulta su API en `/_perfex`; un fallo del worker no reinicia el front ni el servicio.

## Imagen

Desde el repositorio de Huly:

```bash
rush bundle --to @hcengineering/perfex-clients
docker build -t wiwo/perfex-migration:latest dev/perfex-clients
```

Publicar la imagen donde la pueda descargar el servidor y definir `PERFEX_MIGRATION_IMAGE` en
`huly.conf`.

## Configuración

Crear `perfex-migration/sync.json` junto a `compose.yml`. Todos los secretos siguen en
`huly.conf`; el JSON sólo referencia sus nombres:

```json
{
  "front": "https://ops.wiwo.me",
  "dirAdjuntos": "/attachments",
  "mapaDuplicados": "/config/duplicados.json",
  "permisosCsv": "/config/permisos.csv",
  "workspaces": [
    { "env": "wiwo", "workspace": "wiwo", "tokenEnv": "HULY_TOKEN_WIWO", "owners": ["gerencia@wiwo.me"] },
    { "env": "palta", "workspace": "palta", "tokenEnv": "HULY_TOKEN_PALTA", "owners": ["gerencia@wiwo.me"] },
    { "env": "mgc", "workspace": "mgc", "tokenEnv": "HULY_TOKEN_MGC", "owners": ["gerencia@wiwo.me"] },
    { "env": "sin-clasificar", "workspace": "sin-clasificar", "tokenEnv": "HULY_TOKEN_SIN_CLASIFICAR", "owners": ["gerencia@wiwo.me"] }
  ]
}
```

Guardar `permisos.csv` y, si corresponde, `duplicados.json` en ese mismo directorio. Definir en
`huly.conf` las variables documentadas en `example-huly.conf`, incluida la lista exacta de correos
autorizados y los cuatro tokens. El usuario de MySQL debe seguir siendo de sólo lectura.

## Puesta en marcha

```bash
docker compose up -d perfex-migration nginx
curl -fsS http://127.0.0.1:${HTTP_PORT}/_perfex/health
```

Entrar a **Seguimiento → Centro de control → Migración Perfex**. Empezar con **Nueva simulación**,
ejecutar `Preflight` y revisar el registrador de vuelo antes de cualquier etapa real.

Los logs completos quedan en el volumen `perfex_migration_logs`, se descargan como JSONL desde la
interfaz y se eliminan automáticamente después de 90 días.

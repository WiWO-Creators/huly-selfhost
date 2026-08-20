#!/usr/bin/env bash
#
# Chequeo de salud del despliegue de WiWO Ops (ops.wiwo.me).
# Los parametros se leen de huly_v7.conf (el mismo archivo que usa docker compose).
#
# Es de SOLO LECTURA: mira el estado, no reinicia ni recrea nada. Cuando encuentra
# algo, sugiere el comando de arreglo en el mensaje pero no lo ejecuta. Se puede
# correr en cualquier momento, tambien desde cron.
#
# Que chequea:
#   1. Contenedores del stack arriba (ninguno caido, reiniciandose ni unhealthy)
#   2. El front responde por HTTPS
#   3. El contenedor `account` tiene salida a internet (destino externo + /_stats)
#   4. LiveKit responde y el contenedor `love` tiene salida
#   5. El contenedor `process` esta arriba y sin errores recientes
#   6. Hay un backup del dia y no esta vacio
#   7. Espacio en disco por debajo del umbral
#
# Salida: una linea por chequeo (OK / FALLO / ADVERTENCIA), un resumen al final y
# codigo de salida 1 si hubo algun FALLO (las ADVERTENCIA no hacen fallar).
#
# Usage:
#   ./chequeo-salud.sh
#   ./chequeo-salud.sh --help
#
# Configuracion opcional (en huly_v7.conf o como variable de entorno):
#   CHEQUEO_TIMEOUT          Segundos de timeout de cada llamada de red (default: 10)
#   CHEQUEO_DISCO_RUTA       Punto de montaje a medir (default: /)
#   CHEQUEO_DISCO_UMBRAL     % de uso a partir del cual falla (default: 85)
#   CHEQUEO_BACKUP_DIR       Directorio de backups (default: ./backups)
#   CHEQUEO_BACKUP_HORAS     Antiguedad maxima del backup en horas (default: 26)
#   CHEQUEO_ERRORES_HORAS    Ventana de logs de `process` a revisar (default: 24)
#   CHEQUEO_DESTINO_EXTERNO  URL externa para probar la salida (default: Google OAuth)
#   CHEQUEO_LIVEKIT_URL      URL de LiveKit (default: derivada de LIVEKIT_HOST)
#   CHEQUEO_LOG              Archivo de log (default: ./chequeo-salud.log)
#   CHEQUEO_LOG_MAX_BYTES    Tamano a partir del cual se rota el log (default: 1048576)
#   CHEQUEO_AVISO_CMD        Ejecutable a invocar con el resumen si hubo fallos.
#                            Vacio = solo log. Ver chequeo-salud.md.
#
set -euo pipefail

# Cron no hereda el directorio del repo y la configuracion se lee por ruta relativa,
# igual que en el resto de los scripts.
cd "$(dirname "$0")"

if [ "${1:-}" == "--help" ] || [ "${1:-}" == "-h" ]; then
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
fi
if [ $# -gt 0 ]; then
    echo -e "\033[1;31mOpcion desconocida: $1 (usar --help)\033[0m"
    exit 1
fi

CONFIG_FILE="huly_v7.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[1;31mConfig not found: $CONFIG_FILE. Run ./setup.sh first.\033[0m"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${DOCKER_NAME:?DOCKER_NAME missing in $CONFIG_FILE}"
: "${HOST_ADDRESS:?HOST_ADDRESS missing in $CONFIG_FILE}"

TIMEOUT="${CHEQUEO_TIMEOUT:-10}"
DISCO_RUTA="${CHEQUEO_DISCO_RUTA:-/}"
DISCO_UMBRAL="${CHEQUEO_DISCO_UMBRAL:-85}"
BACKUP_DIR="${CHEQUEO_BACKUP_DIR:-./backups}"
BACKUP_HORAS="${CHEQUEO_BACKUP_HORAS:-26}"
ERRORES_HORAS="${CHEQUEO_ERRORES_HORAS:-24}"
DESTINO_EXTERNO="${CHEQUEO_DESTINO_EXTERNO:-https://accounts.google.com/.well-known/openid-configuration}"
LOG_FILE="${CHEQUEO_LOG:-./chequeo-salud.log}"
LOG_MAX_BYTES="${CHEQUEO_LOG_MAX_BYTES:-1048576}"
AVISO_CMD="${CHEQUEO_AVISO_CMD:-}"

# Servicios sin los cuales el sitio no funciona: si alguno no aparece entre los
# contenedores del proyecto, es un fallo y no una advertencia.
SERVICIOS_CRITICOS=(nginx cockroach redpanda minio transactor account front stats)

ESQUEMA="http"
[ -n "${SECURE:-}" ] && ESQUEMA="https"
FRONT_URL="${ESQUEMA}://${HOST_ADDRESS}/"
STATS_URL="${ESQUEMA}://${HOST_ADDRESS}/_stats"
# LIVEKIT_HOST viene como wss://host (lo consumen `love` y `front`); para chequearlo
# por HTTP se cambia el esquema.
LIVEKIT_URL="${CHEQUEO_LIVEKIT_URL:-${LIVEKIT_HOST:+https://${LIVEKIT_HOST#*://}}}"
LIVEKIT_URL="${LIVEKIT_URL:-https://livekit.wiwo.me}"

# Comando de recuperacion del incidente de red que motivo este chequeo.
COMPOSE_FILES="-f compose.yml -f compose.testops.yml"
sugerencia_recrear() {
    echo "recrear solo ese contenedor: docker compose ${COMPOSE_FILES} up -d --force-recreate $1"
}

# Validacion de la configuracion numerica antes de usarla en aritmetica o en find.
for par in "CHEQUEO_TIMEOUT:$TIMEOUT" "CHEQUEO_DISCO_UMBRAL:$DISCO_UMBRAL" \
           "CHEQUEO_BACKUP_HORAS:$BACKUP_HORAS" "CHEQUEO_ERRORES_HORAS:$ERRORES_HORAS" \
           "CHEQUEO_LOG_MAX_BYTES:$LOG_MAX_BYTES"; do
    if ! [[ "${par#*:}" =~ ^[0-9]+$ ]] || [ "${par#*:}" -eq 0 ]; then
        echo -e "\033[1;31m${par%%:*} debe ser un entero mayor que cero (valor: ${par#*:})\033[0m"
        exit 1
    fi
done

for binario in docker curl; do
    if ! command -v "$binario" >/dev/null 2>&1; then
        echo -e "\033[1;31mFalta el comando '$binario', necesario para el chequeo.\033[0m"
        exit 1
    fi
done

# Rotacion simple: un solo archivo previo, para que el log no crezca sin limite.
if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
fi

OK_COUNT=0
FALLO_COUNT=0
ADVERTENCIA_COUNT=0
RESUMEN_FALLOS=""

# Imprime el resultado de un chequeo por pantalla (con color) y sin color al log.
# $1 estado (OK|FALLO|ADVERTENCIA), $2 nombre del chequeo, $3 motivo o detalle.
registrar() {
    local estado="$1" nombre="$2" detalle="${3:-}" color
    case "$estado" in
        OK)          color="\033[1;32m"; OK_COUNT=$((OK_COUNT + 1)) ;;
        FALLO)       color="\033[1;31m"; FALLO_COUNT=$((FALLO_COUNT + 1))
                     RESUMEN_FALLOS="${RESUMEN_FALLOS}- ${nombre}: ${detalle}"$'\n' ;;
        ADVERTENCIA) color="\033[1;33m"; ADVERTENCIA_COUNT=$((ADVERTENCIA_COUNT + 1)) ;;
        *)           color="" ;;
    esac
    printf '%b%-12s\033[0m %-28s %s\n' "$color" "$estado" "$nombre" "$detalle"
    printf '%s [%s] %s: %s\n' "$(date '+%F %T')" "$estado" "$nombre" "$detalle" >>"$LOG_FILE"
}

# Id del contenedor de un servicio del stack, vacio si no esta desplegado.
id_contenedor() {
    docker ps -a -q \
        --filter "label=com.docker.compose.project=${DOCKER_NAME}" \
        --filter "label=com.docker.compose.service=$1" | head -1
}

# Prueba desde dentro de un contenedor que se pueda alcanzar una URL: resuelve DNS,
# abre la conexion y lee la respuesta. Cualquier codigo HTTP sirve, lo que se mide
# es la salida a internet, no el resultado del endpoint.
# Imprime el detalle. Devuelve 0 si alcanza, 1 si no, 2 si el contenedor no existe.
JS_SALIDA=""
probar_salida() {
    local servicio="$1" url="$2" contenedor salida
    contenedor="$(id_contenedor "$servicio")"
    if [ -z "$contenedor" ]; then
        echo "el contenedor '$servicio' no existe en el proyecto ${DOCKER_NAME}"
        return 2
    fi
    # Los servicios de Huly corren sobre Node, que trae fetch: no hace falta que la
    # imagen tenga curl. Si aun asi no estuviera, se prueba con wget.
    if [ -z "$JS_SALIDA" ]; then
        JS_SALIDA=$(printf 'fetch(process.argv[1],{redirect:"manual",signal:AbortSignal.timeout(%d)}).then(r=>console.log("responde HTTP "+r.status)).catch(e=>{console.error(e.message||String(e));process.exit(1)})' \
            "$((TIMEOUT * 1000))")
    fi
    if salida=$(timeout "$((TIMEOUT + 5))" docker exec "$contenedor" node -e "$JS_SALIDA" "$url" 2>&1); then
        echo "$url ${salida}"
        return 0
    fi
    if echo "$salida" | grep -qiE 'executable file not found|no such file|not found'; then
        if timeout "$((TIMEOUT + 5))" docker exec "$contenedor" \
                wget -q -T "$TIMEOUT" -O /dev/null "$url" >/dev/null 2>&1; then
            echo "$url alcanzado (wget)"
            return 0
        fi
    fi
    echo "$url no responde desde '$servicio': $(echo "$salida" | tr '\n' ' ' | cut -c1-160)"
    return 1
}

# Codigo HTTP de una URL desde el host, o vacio si no hubo respuesta.
codigo_http() {
    curl -o /dev/null -s -k --max-time "$TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null || true
}

echo -e "\033[1;34mChequeo de salud de ${HOST_ADDRESS}:\033[0m  $(date '+%F %T')"
echo ""

# --- 1. Contenedores del stack ------------------------------------------------
chequeo_contenedores() {
    local filas fila servicio estado detalle problemas="" total=0 arriba=0 faltantes=""
    mapfile -t filas < <(docker ps -a \
        --filter "label=com.docker.compose.project=${DOCKER_NAME}" \
        --format '{{.Label "com.docker.compose.service"}}|{{.State}}|{{.Status}}' 2>/dev/null || true)

    if [ "${#filas[@]}" -eq 0 ] || [ -z "${filas[0]}" ]; then
        registrar FALLO "contenedores" \
            "no hay contenedores del proyecto ${DOCKER_NAME}; el stack esta caido: docker compose ${COMPOSE_FILES} up -d"
        return
    fi

    for fila in "${filas[@]}"; do
        servicio="${fila%%|*}"
        estado="$(echo "$fila" | cut -d'|' -f2)"
        detalle="$(echo "$fila" | cut -d'|' -f3)"
        total=$((total + 1))
        if [ "$estado" == "running" ] && [[ "$detalle" != *unhealthy* ]]; then
            arriba=$((arriba + 1))
        else
            problemas="${problemas}${servicio} (${estado}), "
        fi
    done

    for servicio in "${SERVICIOS_CRITICOS[@]}"; do
        if ! printf '%s\n' "${filas[@]}" | grep -q "^${servicio}|"; then
            faltantes="${faltantes}${servicio}, "
        fi
    done

    if [ -n "$faltantes" ]; then
        registrar FALLO "contenedores" \
            "faltan servicios criticos: ${faltantes%, } (levantar: docker compose ${COMPOSE_FILES} up -d)"
    elif [ -n "$problemas" ]; then
        registrar FALLO "contenedores" \
            "${arriba}/${total} arriba; con problema: ${problemas%, } ($(sugerencia_recrear "${problemas%% *}"))"
    else
        registrar OK "contenedores" "${arriba}/${total} arriba y sanos"
    fi
}

# --- 2. Front por HTTPS -------------------------------------------------------
chequeo_front() {
    local codigo
    codigo="$(codigo_http "$FRONT_URL")"
    if [ "$codigo" == "200" ]; then
        registrar OK "front (${ESQUEMA})" "$FRONT_URL responde HTTP 200"
    elif [ -z "$codigo" ] || [ "$codigo" == "000" ]; then
        registrar FALLO "front (${ESQUEMA})" \
            "$FRONT_URL no responde en ${TIMEOUT}s (revisar nginx del host y el contenedor front)"
    else
        registrar FALLO "front (${ESQUEMA})" "$FRONT_URL responde HTTP ${codigo}"
    fi
}

# --- 3. Salida a internet de `account` ----------------------------------------
# Es lo que fallo el 17/08/2026: el contenedor quedo sin ruta de salida y el login
# con Google devolvia "Internal OAuth Error". El puerto seguia abierto, asi que un
# chequeo de puerto habria dado verde.
chequeo_salida_account() {
    local detalle codigo objetivo
    for objetivo in "$DESTINO_EXTERNO" "$STATS_URL"; do
        codigo=0
        detalle="$(probar_salida account "$objetivo")" || codigo=$?
        case "$codigo" in
            0) registrar OK "salida account" "$detalle" ;;
            2) registrar FALLO "salida account" "$detalle" ;;
            *) registrar FALLO "salida account" \
                   "${detalle} | sin salida a internet: revisar iptables (cadena DOCKER-USER, ver chequeo-salud.md) y luego $(sugerencia_recrear account)" ;;
        esac
    done
}

# --- 4. LiveKit y salida de `love` --------------------------------------------
chequeo_livekit() {
    local codigo detalle salida=0
    codigo="$(codigo_http "$LIVEKIT_URL")"
    if [ -z "$codigo" ] || [ "$codigo" == "000" ]; then
        registrar FALLO "livekit" "$LIVEKIT_URL no responde en ${TIMEOUT}s"
    elif [ "$codigo" -ge 500 ]; then
        registrar FALLO "livekit" "$LIVEKIT_URL responde HTTP ${codigo}"
    else
        registrar OK "livekit" "$LIVEKIT_URL responde HTTP ${codigo}"
    fi

    detalle="$(probar_salida love "$DESTINO_EXTERNO")" || salida=$?
    case "$salida" in
        0) registrar OK "salida love" "$detalle" ;;
        2) registrar ADVERTENCIA "salida love" "${detalle}: el modulo Teletrabajo todavia no esta desplegado" ;;
        *) registrar FALLO "salida love" \
               "${detalle} | sin salida a internet: revisar iptables (cadena DOCKER-USER) y luego $(sugerencia_recrear love)" ;;
    esac
}

# --- 5. Automatizaciones (`process`) ------------------------------------------
chequeo_process() {
    local contenedor estado errores
    contenedor="$(id_contenedor process)"
    if [ -z "$contenedor" ]; then
        registrar ADVERTENCIA "automatizaciones" \
            "el contenedor 'process' no existe: las automatizaciones no se estan consumiendo (todavia no se desplego)"
        return
    fi

    estado="$(docker inspect -f '{{.State.Status}}' "$contenedor" 2>/dev/null || echo desconocido)"
    if [ "$estado" != "running" ]; then
        registrar FALLO "automatizaciones" \
            "'process' esta en estado ${estado} ($(sugerencia_recrear process))"
        return
    fi

    # Heuristica deliberada: cuenta lineas que mencionan error en la ventana. Puede
    # contar de mas; el numero es una senal para ir a mirar el log, no un diagnostico.
    errores="$(docker logs --since "${ERRORES_HORAS}h" --tail 500 "$contenedor" 2>&1 |
        grep -ciE 'error|exception|fatal' || true)"
    if [ "${errores:-0}" -gt 0 ]; then
        registrar FALLO "automatizaciones" \
            "'process' arriba pero con ${errores} lineas de error en las ultimas ${ERRORES_HORAS}h (ver: docker logs --since ${ERRORES_HORAS}h ${DOCKER_NAME}-process-1)"
    else
        registrar OK "automatizaciones" "'process' arriba y sin errores recientes"
    fi
}

# --- 6. Backup del dia --------------------------------------------------------
# backup-create.sh deja el backup dentro del <backup-dir> que recibe como argumento
# (por convencion ./backups/<workspace>), con los archivos que escribe la herramienta
# de Huly: backup.json.gz y los .tar.gz por dominio. Se comprueba que haya al menos
# un archivo no vacio escrito dentro de la ventana.
chequeo_backup() {
    local reciente peso
    if [ ! -d "$BACKUP_DIR" ]; then
        registrar FALLO "backup" \
            "no existe el directorio ${BACKUP_DIR} (correr: ./backup-create.sh ${BACKUP_DIR}/<workspace> <workspace>)"
        return
    fi

    reciente="$(find "$BACKUP_DIR" -type f -size +0c -mmin "-$((BACKUP_HORAS * 60))" -print -quit 2>/dev/null || true)"
    if [ -z "$reciente" ]; then
        registrar FALLO "backup" \
            "sin backups no vacios en ${BACKUP_DIR} en las ultimas ${BACKUP_HORAS}h (correr: ./backup-create.sh ${BACKUP_DIR}/<workspace> <workspace>)"
        return
    fi

    peso="$(du -h "$reciente" 2>/dev/null | cut -f1)"
    registrar OK "backup" "backup de las ultimas ${BACKUP_HORAS}h: ${reciente} (${peso:-?})"
}

# --- 7. Espacio en disco ------------------------------------------------------
chequeo_disco() {
    local uso libre
    uso="$(df -P "$DISCO_RUTA" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    libre="$(df -Ph "$DISCO_RUTA" 2>/dev/null | awk 'NR==2 {print $4}')"
    if ! [[ "$uso" =~ ^[0-9]+$ ]]; then
        registrar FALLO "disco" "no se pudo medir el uso de ${DISCO_RUTA}"
    elif [ "$uso" -ge "$DISCO_UMBRAL" ]; then
        registrar FALLO "disco" \
            "${DISCO_RUTA} al ${uso}% (umbral ${DISCO_UMBRAL}%, quedan ${libre}); liberar con: docker system prune -f"
    else
        registrar OK "disco" "${DISCO_RUTA} al ${uso}% (umbral ${DISCO_UMBRAL}%, quedan ${libre})"
    fi
}

chequeo_contenedores
chequeo_front
chequeo_salida_account
chequeo_livekit
chequeo_process
chequeo_backup
chequeo_disco

echo ""
RESUMEN="Resumen ${HOST_ADDRESS}: ${OK_COUNT} OK, ${ADVERTENCIA_COUNT} advertencias, ${FALLO_COUNT} fallos."
if [ "$FALLO_COUNT" -gt 0 ]; then
    echo -e "\033[1;31m${RESUMEN}\033[0m"
else
    echo -e "\033[1;32m${RESUMEN}\033[0m"
fi
printf '%s [RESUMEN] %s\n' "$(date '+%F %T')" "$RESUMEN" >>"$LOG_FILE"

# Aviso opcional: por defecto el chequeo solo escribe al log. Si CHEQUEO_AVISO_CMD
# apunta a un ejecutable, se lo invoca con el resumen como unico argumento cuando
# hubo fallos (agregar Telegram o correo es escribir ese ejecutable, nada mas).
if [ "$FALLO_COUNT" -gt 0 ] && [ -n "$AVISO_CMD" ]; then
    if [ -x "$AVISO_CMD" ]; then
        if ! "$AVISO_CMD" "${RESUMEN}"$'\n'"${RESUMEN_FALLOS}"; then
            registrar ADVERTENCIA "aviso" "CHEQUEO_AVISO_CMD (${AVISO_CMD}) termino con error"
        fi
    else
        registrar ADVERTENCIA "aviso" "CHEQUEO_AVISO_CMD (${AVISO_CMD}) no es un ejecutable"
    fi
fi

[ "$FALLO_COUNT" -eq 0 ] || exit 1
exit 0

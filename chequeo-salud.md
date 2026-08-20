# Chequeo de salud de ops.wiwo.me

`./chequeo-salud.sh` mira el estado del despliegue y no toca nada: es de sólo lectura. Cuando
encuentra un problema lo dice y **sugiere** el comando de arreglo, pero no lo ejecuta. Se puede
correr en cualquier momento y en paralelo con cualquier otra cosa.

Existe por la caída del 17/08/2026: al abrir los puertos UDP de WebRTC se pisaron las cadenas de
iptables que administra Docker y el contenedor `account` se quedó **sin salida a internet**. El
sitio seguía en pie, los puertos seguían abiertos y el contenedor figuraba `Up`; lo único roto era
el login con Google (`InternalOAuthError: Failed to obtain access token`, y un
`Connect Timeout Error (attempted address: ops.wiwo.me:443)` cada 30 segundos contra `/_stats`).
Nadie se enteró hasta que un humano quiso entrar. El chequeo prueba justamente eso: que el
contenedor pueda **salir**, no que el puerto esté abierto.

## Qué chequea

| # | Chequeo | Qué mira |
|---|---------|----------|
| 1 | `contenedores` | Todos los contenedores del proyecto arriba: ninguno `exited`, `restarting` ni `unhealthy`, y ninguno de los servicios críticos ausente |
| 2 | `front` | `https://ops.wiwo.me/` responde 200 desde afuera |
| 3 | `salida account` | Desde dentro del contenedor `account`: alcanza un destino externo real (el OIDC de Google) y el propio `/_stats` |
| 4 | `livekit` / `salida love` | `https://livekit.wiwo.me` responde, y el contenedor `love` también sale a internet |
| 5 | `automatizaciones` | Si existe el contenedor `process`: arriba y sin errores recientes en el log. Si no existe: advertencia (todavía no se desplegó) |
| 6 | `backup` | Hay al menos un archivo de backup **no vacío** escrito en las últimas 26 horas dentro de `./backups` |
| 7 | `disco` | Uso de `/` por debajo del umbral (85% por defecto) |

## Instalación en cron

El script vive en la raíz del repo y se ubica solo (`cd` a su propio directorio), así que en cron
basta con la ruta absoluta. Tiene que correr con un usuario que pertenezca al grupo `docker`:

```bash
crontab -e
```

```cron
# Chequeo de salud de ops.wiwo.me. Escribe a chequeo-salud.log; cron no manda correo.
*/10 * * * * /home/<usuario>/wiwo.ops/chequeo-salud.sh >/dev/null 2>&1
```

**Cada 10 minutos** es el intervalo recomendado: son siete chequeos con timeout de 10 segundos cada
uno (menos de un minuto en el peor caso) y acota a diez minutos la ventana en la que una caída como
la de hoy pasa desapercibida. Menos de 5 minutos no aporta nada; más de 30 minutos ya es demasiado
tiempo con el login roto.

Verificá que quedó bien corriéndolo a mano una vez:

```bash
cd ~/wiwo.ops && ./chequeo-salud.sh; echo "salida: $?"
```

## Cómo leer la salida

Una línea por chequeo, con el motivo concreto:

- `OK` — el chequeo pasó.
- `FALLO` — hay algo roto. El mensaje trae el comando de arreglo. **Hace que el script termine con
  código 1**, que es lo que un cron o un monitor futuro puede usar.
- `ADVERTENCIA` — algo que todavía no está desplegado (`love`, `process`). No hace fallar el script.

Al final hay un resumen (`N OK, N advertencias, N fallos`).

Todo se escribe además a `chequeo-salud.log`, en la raíz del repo, sin colores y con fecha y hora.
La rotación es simple: cuando el archivo pasa de 1 MB se renombra a `chequeo-salud.log.1` y se
empieza uno nuevo. Nunca hay más de dos archivos, así que no crece sin límite.

```bash
tail -30 ~/wiwo.ops/chequeo-salud.log          # últimos chequeos
grep FALLO ~/wiwo.ops/chequeo-salud.log        # sólo lo que falló
```

## Avisos

Por decisión del cliente, el chequeo **sólo escribe al log**: no manda Telegram ni correo.

Si en algún momento se quiere avisar por otro canal, no hay que tocar el script: se escribe un
ejecutable que reciba el mensaje como primer argumento y se lo apunta con una variable en
`huly_v7.conf`:

```bash
CHEQUEO_AVISO_CMD=/home/<usuario>/wiwo.ops/avisar-telegram.sh
```

Se lo invoca sólo cuando hubo fallos, con el resumen y la lista de fallos en `$1`. Un
`avisar-telegram.sh` es tan corto como un `curl` al bot; las credenciales van en `huly_v7.conf`,
nunca en el script.

## Configuración

Todo lo ajustable sale de `huly_v7.conf` (el mismo archivo que usa docker compose) o de una variable
de entorno. El script no lleva ninguna credencial adentro.

| Variable | Default | Para qué |
|----------|---------|----------|
| `CHEQUEO_TIMEOUT` | `10` | Segundos de timeout de cada llamada de red |
| `CHEQUEO_DISCO_RUTA` | `/` | Punto de montaje a medir |
| `CHEQUEO_DISCO_UMBRAL` | `85` | % de uso a partir del cual falla |
| `CHEQUEO_BACKUP_DIR` | `./backups` | Dónde busca los backups |
| `CHEQUEO_BACKUP_HORAS` | `26` | Antigüedad máxima aceptable del backup |
| `CHEQUEO_ERRORES_HORAS` | `24` | Ventana de logs de `process` que revisa |
| `CHEQUEO_DESTINO_EXTERNO` | OIDC de Google | URL externa con la que prueba la salida |
| `CHEQUEO_LIVEKIT_URL` | derivada de `LIVEKIT_HOST` | URL de LiveKit |
| `CHEQUEO_LOG` | `./chequeo-salud.log` | Archivo de log |
| `CHEQUEO_LOG_MAX_BYTES` | `1048576` | Tamaño al que rota el log |
| `CHEQUEO_AVISO_CMD` | vacío | Ejecutable de aviso (ver arriba) |

## Qué hacer ante cada fallo

Todos los comandos asumen `cd ~/wiwo.ops`. `COMPOSE` abrevia
`docker compose -f compose.yml -f compose.testops.yml`.

| Fallo | Qué hacer |
|-------|-----------|
| `contenedores: no hay contenedores del proyecto` | El stack está caído: `$COMPOSE up -d` |
| `contenedores: faltan servicios críticos: X` | Ese servicio no está desplegado: `$COMPOSE up -d` |
| `contenedores: X (restarting)` | Mirar por qué reinicia: `$COMPOSE logs --tail 100 X`, y después `$COMPOSE up -d --force-recreate X` |
| `contenedores: X (exited)` | `$COMPOSE up -d X` |
| `contenedores: X (unhealthy)` | El healthcheck del servicio falla: `docker inspect --format '{{json .State.Health}}' huly_v7-X-1 \| tail -c 800` |
| `front: no responde` | Nginx del host primero: `sudo nginx -t && sudo systemctl status nginx`. Si nginx está bien: `$COMPOSE up -d --force-recreate front` |
| `front: responde HTTP 502/504` | El contenedor `front` no atiende: `$COMPOSE logs --tail 100 front` y `$COMPOSE up -d --force-recreate front` |
| `front: responde HTTP 5xx` con certificado vencido | `sudo certbot renew && sudo nginx -s reload` |
| **`salida account: ... no responde desde 'account'`** | **Es la caída de hoy.** Verificar: `sudo iptables -S DOCKER-USER` y `sudo iptables -S FORWARD`. Arreglo inmediato: `$COMPOSE up -d --force-recreate account`. Arreglo de fondo: la sección siguiente |
| `salida love: ... no responde desde 'love'` | Mismo problema que el anterior, mismo arreglo: `$COMPOSE up -d --force-recreate love` |
| `livekit: no responde` | `docker compose -f compose.livekit.yml ps` y `ss -lntup \| grep -E ':(7880\|7881\|3478)'`. Si el proceso está arriba, es el nginx del host: `sudo nginx -t && sudo nginx -s reload` |
| `automatizaciones: 'process' está en estado exited` | `$COMPOSE logs --tail 100 process` y `$COMPOSE up -d --force-recreate process` |
| `automatizaciones: 'process' arriba pero con N líneas de error` | Es una heurística (cuenta líneas que dicen error): mirar el log real con `docker logs --since 24h huly_v7-process-1 \| grep -iE 'error\|exception\|fatal' \| tail -20` |
| `backup: no existe el directorio` / `sin backups no vacíos` | Correr el backup a mano: `./backup-create.sh ./backups/<workspace> <workspace>` y revisar por qué no corrió el cron del backup (`crontab -l`) |
| `disco: al N%` | `docker system prune -f` para imágenes y capas huérfanas; después revisar `du -sh ./backups/*` y el retention de snapshots (`--keep-snapshots` en `backup-create.sh`) |
| `ADVERTENCIA: 'love'/'process' no existe` | Esperado hasta que se desplieguen esos módulos. No hay nada que arreglar |

## Arreglo de fondo del incidente: reglas de WebRTC en `DOCKER-USER`

**Qué pasó.** Docker se genera sus propias cadenas de iptables (`DOCKER`, `DOCKER-ISOLATION-STAGE-1`
y `-2`, y las reglas que inserta en `FORWARD`) y las **reescribe** cuando arranca, cuando levanta un
contenedor y cuando cambia una red. Cualquier regla propia puesta ahí, o cualquier flush de esas
cadenas, deja el tráfico de los contenedores sin camino de vuelta: siguen levantados, siguen
escuchando en su puerto, pero no pueden salir. Eso fue exactamente lo que le pasó a `account`.

**Dónde van las reglas propias.** En `DOCKER-USER`. Es la única cadena que Docker crea y no vuelve
a tocar, y `FORWARD` salta a ella **antes** que a las cadenas de Docker. Todo filtrado propio de
tráfico de contenedores va ahí, y sólo ahí.

Las reglas para los puertos que hoy están abiertos (7881/tcp de ICE/TCP, 3478/udp del TURN/STUN y
el rango 50000-50100/udp de media):

```bash
# Primero: nunca cortar el tráfico de vuelta de conexiones ya establecidas.
# Esta regla va primera y es la que evita que un DROP posterior deje a los
# contenedores sin salida a internet (la caída del 17/08/2026).
sudo iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# WebRTC
sudo iptables -A DOCKER-USER -p tcp --dport 7881 -j ACCEPT
sudo iptables -A DOCKER-USER -p udp --dport 3478 -j ACCEPT
sudo iptables -A DOCKER-USER -p udp --dport 50000:50100 -j ACCEPT
```

Comprobación (tiene que listar las cuatro, y `FORWARD` tiene que saltar a `DOCKER-USER`):

```bash
sudo iptables -S DOCKER-USER
sudo iptables -S FORWARD | grep DOCKER-USER
```

**Persistirlas**, para que sobrevivan a un reinicio del servidor:

```bash
sudo apt-get install -y iptables-persistent   # pregunta si guardar las reglas actuales: sí
sudo netfilter-persistent save                # escribe /etc/iptables/rules.v4
```

Al reinstalar o mover el servidor hay que rehacer este paso: `netfilter-persistent` guarda una foto
de las tablas, incluidas las cadenas que Docker se regenera solo. Docker las reconcilia al arrancar,
así que no es un problema, pero conviene volver a correr `netfilter-persistent save` después de cada
cambio propio y no confiar en la foto vieja.

**Salvedad importante.** LiveKit corre con `network_mode: host` (ver
`propuesta-teletrabajo-selfhosted/compose.livekit.yml`). Su tráfico entra por la cadena `INPUT`, no
por `FORWARD`, así que `DOCKER-USER` **no lo filtra**: si en algún momento se cierra el host con
`ufw` o con una política `INPUT DROP`, esos tres puertos hay que abrirlos además en `INPUT`. Lo que
no cambia es la regla de oro:

- Nunca `iptables -F`, ni reglas propias en `FORWARD`, `DOCKER` o `DOCKER-ISOLATION-*`.
- Nunca un `DROP` en `DOCKER-USER` sin la regla de `RELATED,ESTABLISHED` delante.
- Después de tocar iptables: correr `./chequeo-salud.sh` y confirmar que `salida account` da OK.

## Complemento: healthcheck del servicio `account`

En `propuesta-chequeo/healthcheck.account.yml` está el bloque de healthcheck propuesto para
`account`, que prueba la misma salida real desde dentro del contenedor. No está aplicado: hay que
pegarlo en `compose.yml`. Con eso, Docker marca el contenedor `unhealthy` en menos de tres minutos
y el chequeo #1 de este script lo reporta sin esperar al chequeo #3.

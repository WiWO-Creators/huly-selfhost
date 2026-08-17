# LiveKit propio para el módulo Teletrabajo — propuesta, NO aplicada

Alternativa a [LiveKit Cloud](../propuesta-teletrabajo/). El módulo de Huly es el mismo en las dos
opciones: el servicio `love` y el bloque `location /_love` no cambian una línea. Lo único distinto es
**contra qué LiveKit apunta `LIVEKIT_HOST`** y que acá el SFU y el TURN los levantamos nosotros.

Todo está verificado contra la documentación y el código de **livekit/livekit v1.13.5** (release del
31/7/2026), no contra la memoria: `config-sample.yaml`, `pkg/config/config.go` y
`pkg/service/server.go` de ese tag, más las páginas *Ports and firewall*, *Deployment* y *VM* de
docs.livekit.io. Se dice de dónde sale cada opción en el comentario de al lado.

## Los archivos

| Archivo | Qué es | Dónde termina |
|---|---|---|
| [`compose.livekit.yml`](compose.livekit.yml) | El SFU, el servicio `love` y las variables de `front` | Se pegan en `compose.yml` |
| [`livekit.yaml`](livekit.yaml) | Configuración del SFU y del TURN embebido. Sin secretos | `backend/wiwo.ops/livekit.yaml` |
| [`livekit.conf.example`](livekit.conf.example) | Las tres variables `LIVEKIT_*` y cómo generar las claves | `huly_v7.conf` (fuera de git) |
| [`livekit.nginx.host.conf`](livekit.nginx.host.conf) | Bloque del nginx **del host** para `wss://livekit.wiwo.me` | `/etc/nginx/sites-available/` |
| `../propuesta-teletrabajo/huly.nginx.love.conf` | El `location /_love`, sin cambios | `.huly.nginx` |

Revisar el compose sin aplicar nada:

```bash
docker compose -f compose.yml -f propuesta-teletrabajo-selfhosted/compose.livekit.yml config
```

## Las tres decisiones que definen el resto

**1. Un solo subdominio: `livekit.wiwo.me`.** Sirve a la vez de nombre del WebSocket (443, por nginx)
y de dominio del TURN/TLS (5349, por el propio LiveKit). Un registro DNS, un certificado. Un
subdominio aparte para el TURN sólo haría falta si algún día el TURN/TLS se moviera a otra IP o
detrás de un balanceador L4.

**2. UDP mux (32 puertos) en lugar del rango 50000-60000.** LiveKit soporta las dos formas. El mux
gana por dos razones concretas: son 32 puertos a abrir en vez de 10.001, y **50000-60000 se solapa con
el rango efímero de Linux** (32768-60999), donde cualquier conexión saliente del servidor puede
haber tomado ya el puerto que el SFU quiere anunciar. La recomendación de LiveKit es usar un rango
de tamaño ≥ cantidad de vCPU: el servidor tiene 32, así que **7882-7913**.

**3. El contenedor de LiveKit corre con `network_mode: host`, no en `huly_net`.** Es una excepción
deliberada a la convención de `compose.yml` y está explicada abajo, en *Seguridad*. Es lo que hace el
propio docker-compose que genera LiveKit para instalaciones en VM, y el motivo es el media: con red
bridge todo el UDP pasa por el NAT de docker, el puerto de origen saliente puede no coincidir con el
publicado, y el resultado típico es **audio en un solo sentido**, intermitente y carísimo de
diagnosticar. El TURN embebido empeora el cuadro: entrega candidatos de relay con la IP pública del
host, así que desde un contenedor en bridge el SFU tendría que hacer hairpin contra la IP pública del
propio servidor para llegar a su propio relay.

Ningún otro servicio necesita alcanzar a `livekit` por nombre de red: `love` y el navegador lo
alcanzan por `wss://livekit.wiwo.me`.

## Puertos

Chequeados contra `compose.yml` y contra los puertos que ya publica el stack. **Ninguno choca.**

Lo que hoy está publicado en el host, según el repo: `${HTTP_BIND}:${HTTP_PORT}:80` del contenedor
nginx (`compose.yml:6`), `8094:8094` de `kvs` (`compose.yml:292`), y 80/443 del nginx del host.
`hulypulse` está comentado y usaría 8099 (`compose.yml:109`). Todo el resto —3000, 3333, 3078, 4004,
4700, 4900, 8080, 8096, 9000, 9001, 9200, 9092, 26257, 33145— vive dentro de `huly_net` y no ocupa
puertos del host.

| Puerto | Proto | Para qué sirve | Qué se rompe si falta |
|---|---|---|---|
| **443** | TCP | Ya abierto. Ahora además sirve `livekit.wiwo.me` y proxea la señalización al 7880 | Nada nuevo que abrir |
| **7880** | TCP | Señalización WebSocket + API de RoomService. **Atado a 127.0.0.1**, no se abre al exterior | Si se abre, se expone la API en texto plano. Si se cierra mal (nginx caído), nadie entra a ninguna sala |
| **7881** | TCP | ICE/TCP. El camino de fallback cuando la red del cliente bloquea UDP | Quien esté en una red que filtra UDP depende sólo del TURN; si tampoco lo tiene, la sala se queda "conectando" para siempre |
| **7882-7913** | UDP | ICE/UDP mux. **Es el camino normal del audio y el video** | Sin esto no hay media directo: todo cae al TURN, con más latencia y más CPU. Si tampoco hay TURN, no hay audio ni video para nadie |
| **3478** | UDP | TURN/UDP embebido. Además hace de servidor STUN | Se pierde el relay por UDP: los clientes detrás de NAT simétrico caen a TURN/TLS, más lento |
| **5349** | TCP | TURN/TLS con el certificado de `livekit.wiwo.me` | Las redes corporativas que sólo dejan salir TLS quedan afuera del todo. Es el puerto que salva las oficinas de clientes |
| 30000-30100 | UDP | Relay del TURN. Es tráfico **del host contra sí mismo** | **No hay que abrirlo en ningún firewall externo.** Sólo importa no bloquearlo localmente |

Dos observaciones que conviene decir fuerte:

- **El TURN/TLS ideal sería 443/tcp, y ese puerto ya es del nginx del host.** Es el único choque real
  de toda la propuesta. Un firewall corporativo que sólo deja salir 443 va a bloquear igual el 5349.
  La v1 va con 5349 (el puerto estándar de TURN/TLS) porque mover el TURN a 443 exige poner un
  `stream` con `ssl_preread` delante del ingress de producción y desviar por SNI, o pedir una segunda
  IP. Si aparece un cliente real cuya red bloquea 5349, ese es el escalamiento: nginx `stream` en
  443, `turn.external_tls: true` y `tls_port` sin certificado en LiveKit. No antes.
- **`ufw` está inactivo y todavía no sabemos si hay firewall externo en el panel del proveedor.**
  Mientras `ufw` esté abajo, apenas el contenedor levante, esos puertos quedan expuestos sin que
  nadie los abra. Si el proveedor **sí** tiene firewall en el panel, hay que cargar ahí las cinco
  reglas o el media va a fallar de forma parcial y confusa (la señalización entra por 443 y funciona,
  la sala abre, y no se escucha a nadie). **Este dato sigue pendiente y hay que confirmarlo antes de
  empezar.**

El propio binario imprime la lista definitiva a partir del archivo de configuración, y ese es el
chequeo que manda:

```bash
docker compose logs livekit | head -30        # la línea "starting LiveKit server" lista los puertos
ss -lntup | grep -E ':(7880|7881|3478|5349|788[2-9]|791[0-3]|30000)'
```

## DNS y certificados

Un registro y un certificado. **No se inventa un mecanismo nuevo:** este despliegue termina el TLS en
el **nginx del host** (`apt install nginx`, `nginx.conf` enlazado en `/etc/nginx/sites-enabled/`,
`README.md:104-128`), y el certificado se emite ahí, no en un contenedor.

1. **DNS.** Registro `A` `livekit.wiwo.me` → `216.194.172.8`, TTL 300 mientras se prueba. Sin `AAAA`
   salvo que se confirme que el servidor tiene IPv6 funcional y se quiera anunciarla también.
   Verificar con `dig +short livekit.wiwo.me` **antes** de pedir el certificado.
2. **Averiguar cómo se emitió el certificado que ya está en uso**, y repetirlo. El archivo
   `nginx.conf` está en `.gitignore`, así que el repo no lo dice:

   ```bash
   sudo certbot certificates
   sudo grep -E 'authenticator|webroot_path|installer' /etc/letsencrypt/renewal/*.conf
   ```

   Si el autenticador es `webroot`, se usa el mismo webroot. Si es `nginx`, se usa `--nginx`. Si no
   hay certbot, entonces el certificado vino de otro lado y hay que replicar **ese** camino: la regla
   es no agregar un segundo mecanismo de emisión en el mismo servidor.
3. **Emitir**, con el hook de renovación puesto desde el principio:

   ```bash
   sudo certbot certonly --webroot -w /var/www/html -d livekit.wiwo.me \
        --deploy-hook 'cd /ruta/a/wiwo.ops && docker compose restart livekit'
   ```

   **El `--deploy-hook` no es opcional.** LiveKit lee `cert_file` y `key_file` al arrancar y no los
   recarga solo. Sin el hook, el TURN/TLS sigue sirviendo el certificado viejo y **a los 90 días deja
   de funcionar sin que nadie toque nada**; el síntoma es que el módulo funciona en la oficina y no
   funciona en la red de un cliente, tres meses después del despliegue.
4. **Un solo certificado para dos consumidores**: el nginx del host lo usa para el 443 y LiveKit lo
   lee desde `/etc/letsencrypt` (montado de sólo lectura) para el TURN/TLS en 5349. Por eso
   `turn.domain` tiene que ser exactamente `livekit.wiwo.me`: si no coincide con el SAN, el cliente
   descarta el TURN y se queda sin relay, en silencio.

## Seguridad

Lo que hay que mirar de frente: esto abre **cinco puertos nuevos hacia Internet en un servidor que
además corre el ERP de la empresa**, y el proceso que los atiende no está aislado por red.

**Qué superficie se agrega, exactamente**

- 7881/tcp y 7882-7913/udp: media WebRTC. Sólo aceptan tráfico que corresponda a una negociación ICE
  con credenciales derivadas de la señalización; no hay endpoint ni API detrás.
- 3478/udp y 5349/tcp: el TURN.
- 7880/tcp: **no** se agrega, porque queda atado a `127.0.0.1` (`bind_addresses` en `livekit.yaml`).
  La API del RoomService sólo es alcanzable por el nginx del host, sobre TLS, y autenticada por JWT
  firmado con el secreto.

**El TURN no queda como relay abierto.** Tres controles, y los tres están puestos en `livekit.yaml`:

1. **Autenticación integrada.** El TURN embebido de LiveKit no acepta usuario/contraseña estáticos:
   emite credenciales atadas a una conexión de señalización ya establecida, con `ttl_seconds: 300`.
   Sin haber pasado antes por `/getToken` de `love` —que a su vez exige un token de plataforma de
   Huly— no hay credencial de TURN.
2. **Destinos restringidos, por defecto.** Con `allow_restricted_peer_cidrs` vacío, el TURN
   **rechaza** como destino cualquier CIDR restringido: loopback, redes privadas, link-local y
   multicast. Eso es lo que impide que alguien con una cuenta válida use nuestro TURN como trampolín
   hacia `minio`, `cockroach`, `elastic` o cualquier cosa de `huly_net`. La instrucción operativa es
   simple: **no agregar nunca `allow_restricted_peer_cidrs`** sin escribir por qué.
3. **Rango de relay acotado** (30000-30100) en vez del default de producción 30000-40000: 101 puertos
   son un tope natural de asignaciones simultáneas y no hace falta reservar diez mil.

**Lo que se acota además, y cómo**

- `room.max_participants: 25` y `limit.bytes_per_sec: 100000000` (~800 Mbps). El default de LiveKit
  es 1 GB/s, o sea el enlace entero: un token filtrado o una sala fuera de control podría llevarse
  los 10 Gbps y el tráfico mensual por delante. El servidor ya mueve del orden de 1,3 TB por semana.
- `deploy.resources.limits: cpus 8, memory 4G`. Como el contenedor corre en la red del host, no tiene
  el aislamiento habitual; el límite de recursos es lo que evita que una reunión le saque CPU a
  cockroach y al transactor. Con 32 núcleos y 89 GB libres, 8 núcleos es holgadísimo para quince
  personas.
- `development: false` y sin `prometheus_port` ni `debug_handler_port`. Los endpoints de debug
  (`/debug/pprof`, `/debug/rooms`) no se habilitan.
- El secreto de API vive en `huly_v7.conf` (`chmod 600`, en `.gitignore`), igual que el resto de los
  secretos del despliegue. `livekit.yaml` no contiene ninguno y por eso se versiona.

**Lo que no se puede afirmar hoy**

- **Si el proveedor tiene firewall externo, no sabemos qué deja pasar.** Dato pendiente.
- **`ufw` está inactivo.** No se propone activarlo como parte de este cambio: encenderlo en un host
  con docker es un cambio de riesgo propio (los puertos publicados por contenedores esquivan `ufw`
  vía la cadena `DOCKER-USER`, así que la política queda a medias y da una falsa sensación de
  cierre). Si se decide activarlo aparte, lo único que hace falta agregar son las cinco reglas de la
  tabla; y conviene saber que un servicio con `network_mode: host` **sí** obedece a `ufw`, a
  diferencia de los contenedores publicados.
- **STUN sobre 3478/udp es reflejable.** El factor de amplificación es bajo, pero si aparece abuso
  saliente la mitigación es directa: quitar `turn.udp_port` y quedarse sólo con TURN/TLS, o limitar
  la tasa en el firewall del proveedor.

## Puesta en marcha

Ventana con la gente avisada. `love`, `front` y el nginx del contenedor se reinician; el resto del
stack no se toca.

1. **Confirmar los tres datos pendientes**: si hay firewall externo en el panel del proveedor y qué
   deja pasar; que ningún puerto de la tabla esté tomado (`ss -lntup`, ver arriba); y con qué
   mecanismo se emitió el certificado actual (`certbot certificates`).
2. **Backup.** `./backup-create.sh ./backups/<workspace> <workspace>` para cada workspace en uso. No
   hay migración de datos en este cambio, pero es la regla de la casa y es barato.
3. **DNS.** Crear el `A` de `livekit.wiwo.me` → `216.194.172.8` y esperar a que `dig +short` lo
   devuelva.
4. **nginx del host, primera mitad.** Copiar `livekit.nginx.host.conf` a
   `/etc/nginx/sites-available/livekit.wiwo.me.conf` **con el segundo `server` (el de 443) comentado**
   —todavía no hay certificado—, enlazarlo en `sites-enabled`, `sudo nginx -t`, `sudo nginx -s reload`.
5. **Certificado.** `certbot certonly` con el autenticador del paso 1 y el `--deploy-hook` del
   apartado *DNS y certificados*. Verificar que aparezcan
   `/etc/letsencrypt/live/livekit.wiwo.me/fullchain.pem` y `privkey.pem`.
6. **Configuración del SFU.** Copiar `livekit.yaml` a `backend/wiwo.ops/livekit.yaml`. Generar las
   claves en el servidor (`docker run --rm livekit/livekit-server:v1.13.5 generate-keys`) y pegar las
   tres variables de `livekit.conf.example` al final de `huly_v7.conf`. `chmod 600 huly_v7.conf`.
7. **Levantar el SFU.** Pegar el bloque `livekit` de `compose.livekit.yml` en `compose.yml`
   (corrigiendo la ruta del volumen a `./livekit.yaml`), `docker compose config` para que valide, y
   `docker compose up -d livekit`.
8. **nginx del host, segunda mitad.** Descomentar el `server` de 443, `sudo nginx -t`,
   `sudo nginx -s reload`.
9. **Huly.** Pegar los bloques `love` y `front` en `compose.yml`, descomentar/reemplazar el
   `location /_love` de `.huly.nginx` con `../propuesta-teletrabajo/huly.nginx.love.conf`, y
   `docker compose up -d love front && docker compose restart nginx`.
10. **Verificar** con la lista de abajo, en orden. Si algo falla, el paso 11.

### Vuelta atrás

Cada paso se deshace solo, y ninguno toca datos:

1. `docker compose stop livekit love` — el módulo vuelve a estar "colgado", que es exactamente como
   está hoy. El resto de Huly no se entera.
2. Volver a comentar el `location /_love` en `.huly.nginx` y `docker compose restart nginx`.
3. Sacar `LIVEKIT_WS` de `front` y `docker compose up -d front`.
4. `sudo rm /etc/nginx/sites-enabled/livekit.wiwo.me.conf && sudo nginx -t && sudo nginx -s reload`.
5. Opcional y sin apuro: borrar el registro DNS y `sudo certbot delete --cert-name livekit.wiwo.me`.

`backup-restore.sh` **no** hace falta: este cambio no escribe en la base ni en el storage. Si igual
hiciera falta, el backup del paso 2 está.

### Cómo saber que funciona

En este orden. Cada paso descarta una capa; saltearlos hace perder más tiempo del que ahorra.

1. **El SFU arrancó.** `docker compose logs livekit | head -30`. La línea `starting LiveKit server`
   lista `portHttp`, `rtc.portTCP` y `rtc.portUDP`: tienen que ser 7880, 7881 y 7882-7913. Si el
   contenedor sale y vuelve a salir, el mensaje que importa es
   `one of key-file or keys must be provided` → falta `LIVEKIT_KEYS`, o sea falta alguna de las dos
   variables en `huly_v7.conf`.
2. **La señalización llega desde afuera.** `curl -i https://livekit.wiwo.me/` → **200** con el cuerpo
   `OK`. Un 502 es que el contenedor no está arriba; un `Not Ready` es que arrancó recién.
3. **El TURN/TLS sirve el certificado correcto.**
   `openssl s_client -connect livekit.wiwo.me:5349 -servername livekit.wiwo.me </dev/null 2>&1 | head -20`
   → cadena de Let's Encrypt con `CN=livekit.wiwo.me`. Si esto falla, el TURN no existe para los
   clientes aunque el puerto conteste.
4. **El ICE/TCP contesta.** `nc -vz livekit.wiwo.me 7881`.
5. **Huly ve el servicio.** `curl -i https://ops.wiwo.me/_love/checkRecordAvailable` → 200 con
   `false`. Un 404 es el bloque de nginx sin activar; un 502, nginx sin ver el contenedor; un 400, el
   bug del `Connection "upgrade"` sin arreglar.
6. **El front recibe la URL.** `https://ops.wiwo.me/config.json` tiene que traer `LIVEKIT_WS` con
   `wss://livekit.wiwo.me`, no vacío. Vacío = la sala se abre y se queda cargando para siempre.
7. **Dos usuarios, dos máquinas, dos redes distintas** (una con datos móviles). Audio y video en los
   dos sentidos, y pantalla compartida. Mientras tanto, `docker compose logs -f livekit`: tiene que
   aparecer `participant joined` por cada uno.
8. **Qué camino tomó el media.** En Chrome, `chrome://webrtc-internals` → el par de candidatos
   seleccionado. `host`/`srflx` = UDP directo, que es lo esperado. `relay` = está pasando por el
   TURN, lo cual funciona pero significa que esa red bloquea UDP: sirve saberlo, porque es el
   escenario que justifica todo el TURN.
9. **Desde la red de un cliente**, si se puede. Es el único test que valida la decisión de
   self-hosted contra Cloud.
10. El botón de grabar tiene que aparecer **deshabilitado**. Ver abajo.

## Qué queda fuera

**La grabación de reuniones no entra en esta propuesta**, igual que en la de Cloud, pero acá el
diagnóstico cambia y conviene decirlo porque es la única ventaja funcional real del self-hosted.

Hoy no funciona por dos motivos: hace falta el **egress** de LiveKit (un contenedor aparte, que corre
Chrome headless y ffmpeg), y `services/love/src/storage.ts:38-78` sólo sabe subir a un storage de
tipo `s3` o `datalake` y rechaza el `minio` que usa este despliegue.

Con LiveKit Cloud eso es un callejón sin salida: el egress corre en la infraestructura de LiveKit y
necesita un S3 **alcanzable desde Internet**, y MinIO no está publicado. **Con LiveKit propio sí se
puede**, porque el egress correría en este mismo servidor y llegaría a `minio:9000` por la red
interna. Lo que costaría:

- Un contenedor `livekit/egress` con `--cap-add=SYS_ADMIN` (obligatorio desde v1.7.6, para el sandbox
  de Chrome). LiveKit recomienda **4 núcleos y 4 GB por instancia**, y una grabación de sala completa
  (*RoomComposite*) consume entre 2 y 6 núcleos mientras dura. Con 32 núcleos y 89 GB libres, el
  servidor lo aguanta; no es gratis en CPU.
- **Redis, obligatorio**, y el mismo para el SFU y el egress. Hoy está comentado en `compose.yml:99`.
  Eso implica volver a tocar la configuración del SFU (que en esta propuesta corre sin Redis).
- Configurar el `webhook` de LiveKit apuntando a `https://ops.wiwo.me/_love/webhook`
  (`services/love/src/main.ts:105`), que es por donde `love` se entera de que la grabación terminó.
- Y lo que no se resuelve con infraestructura: **declarar MinIO como storage de tipo `s3`** para que
  `love` lo acepte, con credenciales y endpoint propios. Es un cambio de configuración de Huly con
  su propio riesgo, porque `STORAGE_CONFIG` lo comparten seis servicios.

Estimación honesta: es una tarea aparte, de medio día a un día, y sólo tiene sentido si alguien pide
grabar reuniones. Mientras tanto `/checkRecordAvailable` devuelve `false` y el botón queda
deshabilitado, que es el comportamiento correcto.

**También quedan fuera**, sin cambios respecto de la propuesta de Cloud: golpear la puerta e invitar
dentro de la llamada, que necesitan HulyPulse (`compose.yml:107-127`); y el escalamiento del TURN/TLS
a 443, descrito arriba.

# Sincronización con Google Calendar

El módulo de calendario ya viene en el producto y está habilitado. Lo que hace falta es
levantar el servicio `calendar`, que es el que habla con la API de Google: hace el sync
inicial de cada cuenta conectada y después se mantiene al día por notificaciones push.

Mientras el servicio no exista, el botón *Conectar* de la interfaz apunta a una ruta que
no existe y devuelve 404.

## Qué sincroniza y en qué sentido

- **De Google a ops**: los calendarios de la cuenta conectada aparecen en el módulo
  Calendario con sus eventos, y los cambios llegan en segundos por push.
- **De ops a Google**: solo los eventos que vivan dentro de un calendario de Google ya
  vinculado. Los eventos creados en el calendario propio de ops no se envían a Google.
  No hay un modo "solo lectura" que se pueda activar: es el comportamiento de base.

Los recordatorios de evento son otra cosa y hoy no funcionan: se encolan en el tópico
`timeMachine`, cuyo consumidor (el servicio `worker`) no está desplegado. No afecta a la
visualización de los eventos.

## 1. Averiguar si el dominio está en Google Workspace

Esto decide el tipo de pantalla de consentimiento y conviene resolverlo antes de tocar
nada, porque cambia el resultado final. Sirve cualquiera de estas comprobaciones:

- `dig +short MX wiwo.me` — si responde `aspmx.l.google.com` y similares, el correo lo
  sirve Google.
- Entrar a [admin.google.com](https://admin.google.com) con una cuenta `@wiwo.me`: si
  carga la consola de administración, es Workspace.
- En Google Cloud Console → *OAuth consent screen*: si la opción **Internal** se puede
  seleccionar (no aparece en gris), el dominio es Workspace.

`ALLOWED_EMAIL_DOMAINS` no dice nada al respecto: es un filtro de la aplicación.

**Con Workspace**, la pantalla de consentimiento va como **Internal** y los permisos de
Calendar no necesitan verificación de Google.

**Sin Workspace**, va como **External** en modo *Testing*: funciona con hasta 100 usuarios
añadidos a mano, pero el refresh token caduca a los siete días y cada usuario tiene que
volver a conectar cada semana. Publicar la app exige pasar la verificación de Google, que
lleva semanas.

`mgcglobalgroup.com` es un dominio aparte: si no pertenece al mismo tenant de Workspace,
sus usuarios no van a poder conectar con una app *Internal*.

## 2. Crear el cliente OAuth

Es un cliente **distinto** del que usa el login (`GOOGLE_CLIENT_ID`): otros permisos y
otra URI de redirección. Reutilizar aquel no funciona.

1. En Google Cloud Console, dentro del proyecto que corresponda, habilitar **Google
   Calendar API** (*APIs & Services → Library*).
2. Configurar la pantalla de consentimiento según el punto anterior y añadir exactamente
   estos cuatro permisos:

   ```
   https://www.googleapis.com/auth/calendar.calendars.readonly
   https://www.googleapis.com/auth/calendar.calendarlist.readonly
   https://www.googleapis.com/auth/calendar.events
   https://www.googleapis.com/auth/userinfo.email
   ```

3. **Credentials → Create credentials → OAuth client ID → Web application**.
4. En *Authorised redirect URIs*, esta y solo esta, en HTTPS:

   ```
   https://<HOST_ADDRESS>/_calendar/signin/code
   ```

   El servicio toma el primer elemento de `redirect_uris` del JSON, así que tiene que
   coincidir carácter por carácter. Si no, Google responde `redirect_uri_mismatch`.
5. Descargar el JSON de credenciales.

## 3. Verificar el dominio para las notificaciones push

Google exige que el dominio al que va a enviar los avisos esté verificado. Sin este paso
el login funciona y el sync inicial también, pero no llega ningún push: los cambios hechos
en Google no aparecen en ops hasta el siguiente arranque del servicio.

1. Dar de alta `<HOST_ADDRESS>` en [Google Search Console](https://search.google.com/search-console)
   con la misma cuenta que administra el proyecto de Google Cloud.
2. Añadirlo en *APIs & Services → Domain verification* del proyecto.

## 4. Poner las credenciales en el servidor

En `huly.conf` (el fichero al que apunta el symlink `.env`), pegar el JSON descargado en
**una sola línea** y sin comillas externas:

```
CALENDAR_CREDENTIALS={"web":{"client_id":"...","project_id":"...","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"...","redirect_uris":["https://ops.wiwo.me/_calendar/signin/code"]}}
```

Si la variable falta o queda vacía, el servicio `calendar` aborta al arrancar con
`Missing env variables: Credentials` y entra en bucle de reinicio.

## 5. Desplegar

El servicio `calendar` y la ruta `/_calendar` de nginx ya están en `compose.yml` y
`.huly.nginx`. Basta con levantar:

```bash
cd /root/huly-selfhost
docker compose -f compose.yml -f compose.testops.yml up -d calendar
docker compose -f compose.yml -f compose.testops.yml up -d --force-recreate transactor
docker compose -f compose.yml -f compose.testops.yml restart nginx
```

El `transactor` se recrea porque recibe `CALENDAR_URL`, que es lo que le permite enviar a
Google los cambios hechos desde ops. El `restart nginx` es obligatorio siempre que se
recrea un contenedor: nginx cachea las IPs de los upstream al arrancar.

## 6. Comprobar

```bash
# El servicio arrancó: tiene que aparecer "Calendar controller started"
docker compose -f compose.yml -f compose.testops.yml logs --tail=50 calendar

# nginx enruta: 401 es la respuesta correcta (falta el token de sesión).
# Un 404 significa que nginx no recargó; un 502, que el contenedor no está.
curl -i https://<HOST_ADDRESS>/_calendar/signin
```

Después, en la interfaz: *Configuración → Integraciones → Google Calendar → Conectar*.
Al terminar el consentimiento vuelve a `/calendar` y los calendarios de la cuenta deberían
aparecer con sus eventos.

Para confirmar el push, crear un evento en Google Calendar y mirar los logs:

```bash
docker compose -f compose.yml -f compose.testops.yml logs -f calendar | grep -i push
```

Si el sync inicial trae los eventos pero nunca aparece un push, falta el paso 3.

Para el sentido inverso, editar desde ops un evento que pertenezca a un calendario de
Google: en los logs tiene que salir `Push outcoming event`. Si no sale, al `transactor`
le falta `CALENDAR_URL`.

## Desconectar

Quitar el servicio del compose y el bloque `location /_calendar` de `.huly.nginx`. Los
tokens de las cuentas ya conectadas quedan guardados en las tablas `integrations` e
`integration_secrets` de la base de cuentas; para limpiarlos del todo hay que borrarlos a
mano. Un usuario suelto puede desconectarse desde la misma pantalla de integraciones.

## Notas

- El servicio no publica el puerto 8095: todo el acceso entra por nginx.
- `POST /_calendar/push` lo llama Google sin token de sesión y se identifica por las
  cabeceras `x-goog-*`. No hay que poner filtros de IP ni autenticación delante de esa
  ruta.
- La receta de Google Calendar del `README.md` upstream es de la época de MongoDB y pide
  `MONGO_URI`/`MONGO_DB`: no aplica a esta versión.

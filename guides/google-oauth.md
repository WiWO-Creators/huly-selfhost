# Login con Google

El servicio `account` trae el proveedor de Google incorporado (passport-google-oauth20,
rutas `/auth/google` y `/auth/google/callback`). No hay que compilar nada: el proveedor
se registra solo si el contenedor recibe `GOOGLE_CLIENT_ID` y `GOOGLE_CLIENT_SECRET`.

Mientras esas variables no existan, `GET /_accounts/providers` devuelve `[]` y la
pantalla de login muestra únicamente el acceso por correo. Es el estado por defecto de
este despliegue.

## 1. Crear el OAuth Client ID en Google Cloud

1. Entrá a [Google Cloud Console](https://console.cloud.google.com/) y elegí (o creá)
   el proyecto donde va a vivir la credencial.
2. **APIs & Services → OAuth consent screen**. Si nunca se configuró:
   - Tipo **Internal** si todos los usuarios están en el mismo Workspace de Google;
     **External** en cualquier otro caso.
   - Completá nombre de la app, correo de soporte y correo del desarrollador.
   - Alcances: bastan los tres por defecto (`openid`, `email`, `profile`); el proveedor
     no pide nada más.
   - Con tipo **External** y la app en modo *Testing*, solo entran las cuentas listadas
     en *Test users*. Publicala cuando quieras abrirla al resto.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
4. **Application type: Web application**. Poné un nombre reconocible, por ejemplo
   `WiWO Ops (producción)`.

### Authorized JavaScript origins

Solo el origen, sin ruta ni barra final:

```
https://<HOST_ADDRESS>
```

Si `SECURE` está vacío en `huly.conf` (despliegue sin SSL), usá `http://` y agregá el
puerto tal como aparece en `HOST_ADDRESS`:

```
http://<HOST_ADDRESS>
```

### Authorized redirect URIs

Tiene que coincidir carácter por carácter con lo que arma el servicio; el prefijo
`/_accounts` lo agrega el reverse proxy:

```
https://<HOST_ADDRESS>/_accounts/auth/google/callback
```

Y la variante sin SSL, si corresponde:

```
http://<HOST_ADDRESS>/_accounts/auth/google/callback
```

Si accedés por más de un dominio (por ejemplo el definitivo y uno de pruebas), agregá
una entrada de cada tipo por dominio. Google rechaza el login con
`redirect_uri_mismatch` ante cualquier diferencia, incluida una barra final de más.

5. Guardá y copiá el **Client ID** y el **Client secret**.

## 2. Pegar las credenciales

En `huly.conf` (el archivo al que apunta `.env`), descomentá las dos líneas y pegá los
valores:

```
GOOGLE_CLIENT_ID=1234567890-abcdefg.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxxxxxxxxx
GOOGLE_DISPLAY_NAME=Google
```

`GOOGLE_DISPLAY_NAME` es el texto que aparece en el botón ("Continuar con Google") y
es opcional.

**No dejes `GOOGLE_CLIENT_ID=` o `GOOGLE_CLIENT_SECRET=` definidas y vacías.** Una
cadena vacía llega igual al contenedor, passport intenta registrar la estrategia sin
`clientID` y el servicio `account` no arranca. Para desactivar el proveedor, comentá
las líneas o borralas. `setup.sh` hace ese comentado automáticamente cuando regenera
la configuración.

## 3. Aplicar

Solo hay que recrear el servicio de cuentas:

```bash
docker compose up -d account
```

## Verificación

```bash
curl -s https://<HOST_ADDRESS>/_accounts/providers
```

Debe devolver `[{"name":"google","displayName":"Google"}]`. Si devuelve `[]`, el
contenedor no está viendo las variables: revisá `docker compose config` y que
`huly.conf` no tenga las líneas comentadas.

Después, en `/login` tiene que aparecer el botón de Google arriba del formulario de
correo. El callback crea o enlaza un `SocialId` de tipo `GOOGLE` sobre la misma
`Person`, así que un usuario que ya entraba con correo y contraseña mantiene su cuenta.

## Rotar el secreto

Generá un nuevo Client secret en la misma credencial de Google Cloud, reemplazá
`GOOGLE_CLIENT_SECRET` en `huly.conf` y volvé a correr `docker compose up -d account`.
El Client ID no cambia, así que no hay que tocar los redirect URIs.

## Restringir el acceso a dominios autorizados

Una vez que el acceso con Google funciona, se puede cerrar todo lo demás. Son tres
variables en `huly.conf`:

```
ALLOWED_EMAIL_DOMAINS=wiwo.me,mgcglobalgroup.com
HIDE_LOCAL_LOGIN=true
DISABLE_SIGNUP=true
```

`ALLOWED_EMAIL_DOMAINS` es la lista de dominios de correo que pueden entrar por un
proveedor externo, separados por comas. Vacía o ausente significa **sin restricción**,
que es lo que conviene en desarrollo local. La comprobación vive en el backend
(`pods/authProviders`) y cubre Google, GitHub y OpenID.

`HIDE_LOCAL_LOGIN` merece una aclaración porque en Huly upstream significa otra cosa:
allí solo oculta el formulario en la interfaz y los endpoints siguen abiertos. **En este
fork también los retira del backend**: con la variable en `true`, el servicio de cuentas
no registra `login`, `loginOtp`, `validateOtp`, `loginAsGuest`, `join`, `signUpJoin`,
`changePassword`, `requestPasswordReset`, `requestPasswordSetup` ni `restorePassword`.
Dejan de existir para el cliente, no quedan escondidos.

Aplicar:

```bash
docker compose up -d account front
```

### Orden importante

Activar estas variables **antes** de comprobar que Google funciona deja a todo el mundo
afuera, y no hay forma de volver desde la interfaz. El orden seguro es:

1. Cargar las credenciales de Google y aplicarlas.
2. Entrar con una cuenta de un dominio autorizado. Que funcione de verdad.
3. Recién entonces poner las tres variables y volver a aplicar.

Para volver atrás, comentá las tres líneas en `huly.conf` y repetí el `docker compose up -d`.

### Comprobar que quedó cerrado

```bash
curl -s -X POST https://<HOST_ADDRESS>/_accounts \
  -H 'Content-Type: application/json' \
  -d '{"method":"login","params":{"email":"x@y.z","password":"x"}}'
```

Tiene que responder que el método no existe, no procesar la petición. Lo mismo con
`loginOtp` y `signUpJoin`. Y en `/login` no debe haber formulario de correo: solo el
botón de Google.

Un intento desde un dominio no autorizado vuelve a `/login?authError=domain` con un
mensaje explicándolo, y deja una línea en los logs:

```bash
docker compose logs account | grep -i 'domain not allowed'
```

## Borrar las contraseñas existentes

Cerrar los endpoints alcanza para que nadie entre con contraseña, pero los hashes
siguen guardados. Para eliminarlos —y que la vuelta atrás no reabra el acceso viejo—
hay una tabla dedicada:

```bash
# Backup primero
docker compose exec cockroach cockroach sql --insecure \
  -e 'SELECT * FROM global_account.account_passwords;' > passwords-backup.txt

# Confirmar el nombre real del esquema (depende de DB_NS)
docker compose exec cockroach cockroach sql --insecure -e 'SHOW TABLES;'

# Borrar
docker compose exec cockroach cockroach sql --insecure \
  -e 'DELETE FROM global_account.account_passwords;'
```

Esto no borra cuentas ni usuarios: solo la credencial. Al entrar por Google, el
usuario cae en la misma `Person` de siempre, porque el enlace se hace por el correo.

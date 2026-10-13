# Ejemplo de forma — no copiar el texto

**Este archivo es un ejemplo ficticio.** El proyecto, los clips y el copy no
existen; están aquí sólo para fijar la *estructura* de `publish.md`. Nunca
reutilices estas frases en un proyecto real — el copy se escribe desde el texto
de los subtítulos que devuelve `bin/publish-facts.py`.

---

# Taller de APIs — sesión 3 — copy para publicar

`source/Taller3.mp4` · 48:12 · 2 clips · 3:04 de video corto · es

## Resumen de la clase

Sesión sobre cómo sobrevive una API cuando el cliente se porta mal. Empieza por
idempotencia: qué significa que una petición repetida no haga daño y por qué el
reintento es la regla y no la excepción. Termina en rate limiting, con la
diferencia entre proteger el servicio y castigar al usuario.

## Temas

- Idempotencia y reintentos — 04:20
- Claves de idempotencia en la práctica — 11:05
- Rate limiting: ventana fija vs token bucket — 26:40
- Qué devolver en un 429 — 33:15

---

## 01 — Tu API va a recibir la misma petición dos veces

**Resumen** — Explica que en una red real el reintento es inevitable: el cliente
no sabe si el timeout ocurrió antes o después de que el servidor procesara la
petición. De ahí la idempotencia como requisito de diseño, no como optimización.

| | |
|---|---|
| Archivos | `clips/01-la-misma-peticion-dos-veces/vertical.mp4` (1080x1920) · `master.mp4` (1920x1080) |
| Duración | 1:38 |
| En la fuente | 04:20–05:58 |
| Plataformas | Instagram, LinkedIn |

### Instagram — `vertical.mp4`

**Texto en pantalla:** El reintento no es un caso raro

**Caption:**

```
Tu API va a recibir la misma petición dos veces. No es un caso raro: es martes.

Cuando un cliente ve un timeout no sabe si el servidor alcanzó a procesar o no.
Así que reintenta. Y si ese cobro no es idempotente, acabas de cobrar dos veces.

La idempotencia no es una optimización. Es la condición para que reintentar sea
seguro.
```

**Hashtags (primer comentario):**

```
#APIs #BackEnd #Idempotencia #Arquitectura #DesarrolloDeSoftware #Programación
```

### LinkedIn — `master.mp4`

**Gancho:** Tu API va a recibir la misma petición dos veces. La pregunta es si eso te cuesta dinero.

**Post:**

```
Tu API va a recibir la misma petición dos veces. La pregunta es si eso te cuesta
dinero.

Cuando un cliente ve un timeout, no tiene forma de saber si el servidor alcanzó a
procesar la petición. Su única opción razonable es reintentar. El reintento no es
un cliente mal escrito: es el comportamiento correcto.

Lo que falla es el otro lado. Si el endpoint que cobra no es idempotente, ese
reintento es un cargo duplicado, una fila duplicada y una llamada a soporte.

Diseñar para que la segunda petición idéntica no haga nada nuevo es más barato
que reconciliar después.

¿Cuál fue el último bug de producción que resultó ser un reintento?

#APIs #BackEnd #Arquitectura
```

---

## 02 — Un 429 sin Retry-After es un 429 inútil

**Resumen** — Compara ventana fija y token bucket, y argumenta que lo que
convierte un límite en algo usable no es el algoritmo sino la respuesta: un 429
tiene que decir cuándo volver a intentar.

| | |
|---|---|
| Archivos | `clips/02-un-429-sin-retry-after/vertical.mp4` (1080x1920) · `master.mp4` (1920x1080) |
| Duración | 1:26 |
| En la fuente | 33:15–34:41 |
| Plataformas | Instagram, LinkedIn, TikTok |
| Revisar | La pantalla compartida mostraba la consola con un token en el header; 1 región tapada — confirmar antes de publicar |

### Instagram — `vertical.mp4`

**Texto en pantalla:** El 429 que nadie sabe leer

**Caption:**

```
Un 429 sin Retry-After es un 429 inútil.

Le dices al cliente "no", pero no le dices cuándo sí. Entonces hace lo único que
puede hacer: reintentar de una, y volver a chocar contra el límite.

Tu rate limiter no está protegiendo el servicio. Está generando tráfico.
```

**Hashtags (primer comentario):**

```
#APIs #RateLimiting #BackEnd #Arquitectura #DesarrolloDeSoftware
```

### LinkedIn — `master.mp4`

**Gancho:** Un rate limiter mal comunicado no protege tu servicio: le agrega carga.

**Post:**

```
Un rate limiter mal comunicado no protege tu servicio: le agrega carga.

Ventana fija o token bucket, el algoritmo importa menos de lo que parece. Lo que
decide si el límite funciona es qué devuelves cuando lo aplicas.

Un 429 sin Retry-After deja al cliente sin información. Su mejor estrategia pasa
a ser reintentar de inmediato, y cada rechazo genera otra petición. El límite que
debía bajar el tráfico lo multiplica.

Con Retry-After, el cliente espera. Con backoff, espera bien. Sin eso, estás
rechazando peticiones y pagando por el privilegio.

#RateLimiting #APIs #BackEnd
```

### TikTok — `vertical.mp4`

```
tu rate limiter no está protegiendo nada si no dices cuándo volver 💀
#APIs #BackEnd #Programación #Tech
```

---

## Calendario de publicación

| # | Clip | Plataformas | Cuándo |
|---|---|---|---|
| 1 | 01 — Idempotencia | Instagram + LinkedIn | día 1 |
| 2 | 02 — 429 y Retry-After | Instagram + TikTok, LinkedIn al día siguiente | día 3 |

Arranca con **01**: no necesita contexto previo y su primera frase funciona como
gancho en frío. Deja **02** para cuando ya haya audiencia, porque premia guardar
el post. Separa las publicaciones al menos 48 horas.

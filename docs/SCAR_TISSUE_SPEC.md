# SCAR TISSUE — especificación de desarrollo

Versión 1.0 · 3 de octubre de 2026 · Encargo para Claude Fable 5.1

## 1. Encargo ejecutable

Construye SCAR TISSUE: un servicio donde un agente convierte un fallo observado en una cicatriz verificable, y otros agentes consultan esa cicatriz antes de repetir la misma clase de error. Añade una compra real en Stripe sandbox que desbloquee la receta y sus pruebas.

Entrega código funcional, migraciones Supabase, fixtures, pruebas, interfaz, API/MCP, integración Stripe y documentación. Sigue los hitos de este documento. Resuelve decisiones menores y documenta supuestos. Si faltan credenciales, continúa con las partes independientes y declara qué integración no pudiste verificar.

Claude Fable 5.1 es el agente de desarrollo solicitado. El núcleo funciona con políticas de referencia y verificadores deterministas; un modelo puede proponer o explicar cicatrices, pero no certificarlas. Si implementas el modo LLM opcional, configura su identificador mediante `ANTHROPIC_MODEL` y verifica su disponibilidad.

**Supabase y Stripe son requisitos del usuario.** Este documento especifica el trabajo; no representa software ya implementado ni una certificación de cumplimiento de todas las bases de la hackatón.

## 2. Producto y encaje con la hackatón

**Pitch:** “One agent fails. The next one learns.”

**Promesa concreta:** compartir reglas del tipo «en este contrato y bajo estas condiciones, esta acción falló; esta alternativa pasó estas pruebas; revisar su vigencia después de esta fecha».

**Comprador inicial:** una agencia o equipo que opera varios agentes sobre las mismas integraciones. Compra una receta verificada y reutilizable, con evidencia y condiciones de aplicación.

**Cliente técnico:** un agente que consulta la API o MCP antes de llamar a una herramienta.

La [guía proporcionada](https://shipbysundown.dev/#tools), consultada en el navegador, presenta Checkout, Billing, Machine Payments Protocol, Link Agent Wallet y Stripe Projects. Es una guía de herramientas, no un requisito de integrar todas. Selección para este producto:

| Herramienta | Uso decidido | Prioridad |
|---|---|---|
| Supabase | Auth, conocimiento, evidencias, permisos, compras, eventos | Obligatoria |
| Stripe Checkout | Comprar una revisión de cicatriz desde una página hospedada | P0 obligatorio |
| Machine Payments Protocol (MPP) | Un agente paga y desbloquea la misma revisión por HTTP | Extensión agentic de 48 h, condicionada a disponibilidad |
| Link Agent Wallet | Cliente externo de pago para la demo MPP | Solo junto a MPP |
| Stripe Projects | Aprovisionar Supabase/hosting si conviene al equipo | Opcional, no parte del valor vendido |
| Stripe Billing | Plan recurrente de equipo | P1, fuera de P0 |

La integración principal debe funcionar con Checkout aunque MPP no esté habilitado en la cuenta. El pago habilita acceso en el backend; no basta con poner un botón de Stripe en una landing.

## 3. Qué se vende

### Oferta implementada en P0

**Verified Fix — US$1, pago único por workspace y revisión de cicatriz.** Precio experimental para validar la compra; no es un precio de mercado comprobado ni una afirmación sobre margen.

La compra incluye:

- Receta estructurada para corregir una clase de fallo.
- Reproducción y evidencia de que la alternativa pasó en el entorno indicado.
- Condiciones de aplicación, versión y fecha de verificación.
- Acceso repetido de los agentes del mismo workspace a esa revisión sin volver a pagar.

El preview gratuito muestra síntoma, ámbito, vigencia, tipo de evidencia y precio. El contenido privado creado por un workspace pertenece a ese workspace y se puede compartir entre sus propios agentes sin comprarlo al catálogo.

El vendedor inicial es SCAR TISSUE. El catálogo vendible contiene material sintético publicado por el equipo del producto. No hay reparto a autores, Stripe Connect ni venta automática de datos aportados por clientes.

### Oferta comercial futura, no implementada

**Team Pilot — US$19 como hipótesis de piloto:** onboarding de un workspace y un paquete de recetas curadas para una integración concreta. Validar alcance y demanda antes de convertirlo en suscripción. No mostrar esta opción como comprable hasta implementar su entitlement y fulfillment.

## 4. Casos de venta

| Caso | Quién compra | Problema | Prueba de valor | Estado |
|---|---|---|---|---|
| Agentes de soporte | Agencia que conecta asistentes a un CRM | Cada nueva instancia repite el mismo error de contrato | A falla asignando un ticket; B resuelve otro ticket sin repetir ese intento | Demo P0 |
| Sincronización comercial | Equipo que opera importadores y agentes de ventas | Distintos procesos redescubren restricciones de lotes | Repro de duplicados tras normalizar emails y receta de deduplicación | Caso comercial; fixture P1 |
| Plataforma de agentes por cliente | Equipo de infraestructura | Una solución de una cuenta o versión se aplica indebidamente a otra | Workspace ajeno no ve datos privados; una versión incompatible no recibe la cicatriz | Pruebas P0 de aislamiento y matching |

Documento comercial complementario: `SCAR_TISSUE_CASOS_DE_VENTA.md`. Contiene argumentos, objeciones, pitch y guion. Mantener las afirmaciones de la web alineadas con lo realmente implementado.

## 5. Alcance y prioridades

### P0 — producto demostrable en una jornada extendida

- Un proveedor ficticio: `DemoCRM`; una operación principal: asignar tickets.
- Dos políticas de agente de referencia, identificadas como tales.
- Registro de fallo, creación de candidato y verificación con fixtures aislados.
- Matching estructurado antes de actuar, con versión y vigencia.
- Biblioteca privada y catálogo curado separados.
- Supabase Auth, workspace, API keys con scopes y aislamiento entre dos workspaces.
- Stripe Checkout sandbox: compra, webhook, acceso comprado y descarga repetida.
- Dashboard con biblioteca, evidencia, agentes, compras y demo.
- API HTTP y un adaptador MCP local.
- Caducidad comprobada al consultar y revalidación manual mediante worker.
- Métricas observadas de ejecución, sin ahorro inventado.

### Extensión de 48 horas

- Adaptador MPP en sandbox, cliente agente y recibo comprobable.
- Coordinación de los dos canales de pago y recuperación tras resultados inciertos.
- Reembolsos idempotentes cuando una revisión se revoca antes de entregar.
- Revalidación programada y reporte de resultados posteriores al uso.

### P1 posterior

- Claude como agente evaluado o generador de candidatos, manteniendo verificación independiente.
- Búsqueda semántica para sugerir candidatos; nunca para saltarse precondiciones.
- Importadores, más proveedores, invitaciones humanas y gestión de equipos.
- Billing recurrente, créditos, cuotas de uso, catálogo de terceros y reparto de ingresos.

No construir un chatbot genérico, un editor de workflows, un sistema de ejecución de código subido por clientes ni un gateway hacia cualquier URL de Internet.

## 6. La demo de extremo a extremo

1. Agente A, dentro del workspace editorial de demo, intenta asignar `ticket_101` a un email en DemoCRM v2.
2. La herramienta responde 422 porque esa versión necesita un `owner_id`.
3. A consulta el usuario por email, obtiene su ID y asigna correctamente.
4. SCAR crea un candidato a partir de ambas trazas. El verificador reproduce fallo y corrección en clones limpios y ejecuta un caso reservado.
5. Un administrador de demo publica expresamente la versión sintética en el catálogo.
6. Agente B, en un workspace comprador distinto, prepara la asignación de `ticket_202` y consulta SCAR antes de escribir.
7. Recibe un preview compatible. Para obtener la receta necesita una licencia de US$1.
8. Checkout sandbox completa el pago; el webhook activa la licencia. La página no puede activarla por sí sola.
9. B obtiene la receta, resuelve el ID y asigna el segundo ticket sin el intento 422.
10. Un segundo agente del mismo workspace reutiliza la revisión sin otro cobro.
11. Cambiar el contrato a v3 o adelantar el reloj de prueba muestra que una cicatriz fuera de ámbito o caducada no dirige silenciosamente la acción.

Con MPP habilitado, sustituir el paso de Checkout por el cliente de pago agente. No ejecutar ambos canales para la misma compra.

La demo debe poder repetirse con nuevos workspaces de prueba o nuevas referencias de demo. No borrar compras ni falsificar un «primer pago» si el workspace ya tiene licencia.

## 7. Arquitectura

| Componente | Tecnología | Función |
|---|---|---|
| Web y API | Next.js App Router + TypeScript | UI, autenticación y endpoints |
| Componentes | Tailwind + shadcn/ui + Lucide | Biblioteca, trazas, tienda y estado de compra |
| Persistencia | Supabase Postgres | Cicatrices, evidencia, compras y permisos |
| Identidad | Supabase Auth | Usuario dueño del workspace |
| Actualizaciones | Supabase Realtime | Notificar verificación, pago y ejecución |
| Trabajos | Supabase Queues + worker Node | Verificar, reconciliar y procesar eventos |
| Cobro | SDK oficial Stripe + Checkout hospedado | Venta de la revisión |
| Cobro de agentes | `mppx` + Stripe | Extensión MPP |
| Herramientas de agentes | SDK oficial MCP, stdio | Cliente local sobre la API |
| Contratos y pruebas | Zod, Vitest, Playwright | Validación, motor y recorrido web |

Un repositorio, pnpm y versiones estables compatibles fijadas en lockfile. El worker corre como proceso separado, incluido en el arranque local. No mantener loops extensos dentro de una petición del navegador.

Flujo de conocimiento: fallo → candidato → prueba emparejada → verificación → publicación/ámbito privado → preflight → receta → observación.

Flujo comercial: preview → compra con precio fijado → Stripe → confirmación backend → licencia → entrega.

## 8. Modelo de una cicatriz

Separar el objeto conceptual, la revisión inmutable y las verificaciones posteriores. Renovar una verificación no reescribe el contenido comprado.

```ts
type ScarRevision = {
  schema_version: "1";
  scar_id: string;
  revision_id: string;
  content_hash: string;
  owner_workspace_id: string;
  visibility: "private" | "curated_catalog";
  title: string;
  symptom: string;
  scope: {
    provider: "demo_crm";
    operation: "tickets.assign";
    api_version: string;
    contract_hash: string;
  };
  preconditions: Array<{
    path: "features.has_owner_email" | "features.has_owner_id";
    equals: boolean;
  }>;
  failure: { code: string; effect: "none" | "unknown" };
  remedy: {
    recipe_id: "resolve_owner_then_assign";
    recipe_version: "1";
  };
  verification_policy: {
    verifier_id: "demo_crm_assign_v1";
    ttl_seconds: number;
  };
};
```

Esta forma completa es de backend. El preview excluye `remedy` y las trazas detalladas. El servidor genera ID, propietario, hash y estado de publicación; un agente no puede elegirlos en su reporte.

En P0, las precondiciones solo admiten caminos y operadores de una lista cerrada. Nunca ejecutar `eval`, JavaScript, SQL o un comando encontrado dentro de una cicatriz.

Las recetas seleccionan primitivas locales autorizadas. Una receta no puede ampliar los permisos de quien la usa ni cambiar sus objetivos. Si requiere un permiso que el agente no tiene, devolver `REMEDY_NOT_EXECUTABLE`.

## 9. Fixture ejecutable y contratos del simulador

Fixtures sintéticos versionados; dominios `example.test`; sin credenciales ni clientes reales.

```json
{
  "fixture_version": "demo-crm-1",
  "provider": "demo_crm",
  "api_version": "2.0.0",
  "contract_hash": "demo-crm-assign-v2-owner-id",
  "users": [
    { "id": "user_maria", "email": "maria@example.test" },
    { "id": "user_lee", "email": "lee@example.test" }
  ],
  "tickets": [
    { "id": "ticket_101", "owner_id": null },
    { "id": "ticket_202", "owner_id": null },
    { "id": "ticket_holdout", "owner_id": null }
  ]
}
```

Herramientas:

| Herramienta | Input | Output |
|---|---|---|
| `crm.get_capabilities` | `{}` | Proveedor, versión, contrato y herramientas permitidas |
| `crm.find_user` | `{email}` | Lista de usuarios coincidentes |
| `crm.assign_ticket` | `{ticket_id, owner_email?, owner_id?}` | Ticket actualizado o error estructurado |
| `crm.get_ticket` | `{ticket_id}` | Estado del ticket |

Reglas:

- En v2, `owner_email` sin ID devuelve `OWNER_ID_REQUIRED`, HTTP simulado 422 y cero efectos. Con un ID válido, asigna el ticket.
- En v1 y v3 de demo, email es aceptado; cada versión tiene su propio `contract_hash`.
- `find_user` no puede devolver usuarios de otro intento/workspace.
- La receta exige una coincidencia única, usa ese ID, asigna el ticket y confirma por lectura.
- Cero o varias coincidencias producen `needs_clarification`; no escoger arbitrariamente la primera.
- El dueño esperado se define por el email de la tarea, que el agente conoce. No introducir un objetivo oculto imposible de inferir.

Cada ejecución y verificación opera en una copia aislada del fixture. Los identificadores de tickets pueden repetirse entre copias; la consulta siempre incluye el contexto de ejecución inyectado por el servidor.

El agente A de referencia usa un manejador de error conocido para descubrir la ruta alternativa y producir el candidato. Se etiqueta «política de referencia». No afirmar que un modelo generó una solución si no se llamó a uno.

## 10. Verificación, vigencia y publicación

Estados de revisión: `candidate`, `verified`, `rejected`, `retired`, `revoked`. Estado de trabajo independiente: `queued`, `running`, `completed`, `errored`.

Una verificación válida guarda:

- Configuración exacta de proveedor/contrato/fixture/verificador.
- Traza de la acción original en una copia limpia: debe reproducir `OWNER_ID_REQUIRED` sin efectos.
- Traza de la receta en otra copia del mismo estado: asignación al usuario correcto y sin cambios ajenos.
- Caso reservado con otro ticket y otro usuario: debe confirmar que no se memorizaron IDs de la primera ejecución.
- `verified_at`, `valid_until`, resultados y hashes de las evidencias.

Solo el worker verificador puede otorgar `verified`. Un reporte de un agente, una explicación LLM o un voto de otro usuario no son prueba suficiente.

Caducidad: `effective_status = stale` cuando no existe una verificación vigente para ese ámbito. Se calcula al consultar, incluso si ningún cron ha corrido. TTL inicial de demo: 24 horas. El reloj inyectable solo existe en tests/simulación, no modifica horas de pagos.

Si la revalidación no puede ejecutarse, la revisión queda sin vigencia; no se renueva por optimismo. Si la acción original ya no falla, registrar `no_longer_reproduces` para el ámbito probado. Si la receta produce un efecto incorrecto, revocar y excluirla de recomendaciones.

Una comprobación en v3 no invalida automáticamente la evidencia de v2. Mantener verificaciones por ámbito exacto. Una nueva versión queda fuera de coincidencia hasta tener su propia evidencia.

`retired` significa retirada del catálogo o reemplazada: no admite nuevas compras y mantiene acceso histórico de compradores. `revoked` significa que no debe entregarse ni ejecutarse la receta: conservar recibo, motivo y evidencias de auditoría.

Publicar requiere una acción expresa de administrador del catálogo y una revisión verificada con evidencias sintéticas. El contenido privado nunca pasa al catálogo automáticamente. En P0 no hay publicación pública por parte de clientes.

## 11. Preflight y matching

```ts
type PreflightInput = {
  provider: string;
  operation: string;
  api_version: string;
  contract_hash: string;
  features: { has_owner_email: boolean; has_owner_id: boolean };
  observed_error_code?: string;
};

type PreflightMatch = {
  revision_id: string;
  applicability: "applicable" | "needs_context" | "stale";
  symptom: string;
  reasons: string[];
  verified_at: string | null;
  valid_until: string | null;
  evidence_scope: "simulated";
  access: "owned" | "licensed" | "payment_required";
  price_cents: number | null;
  currency: "usd" | null;
};
```

Algoritmo:

1. Autenticar workspace y scopes de la key.
2. Seleccionar solo contenido privado propio o catálogo publicado autorizado.
3. Exigir coincidencia exacta de proveedor, operación, versión y hash de contrato.
4. Evaluar precondiciones estructuradas. Un campo ausente es desconocido, nunca falso asumido.
5. Consultar vigencia/revocación actual.
6. Ordenar coincidencias aplicables por verificación más reciente y un desempate estable por ID.
7. Devolver preview y acceso. Entregar receta solo por el endpoint que valida propiedad/licencia.

No exigir `observed_error_code`: el objetivo de preflight es ayudar antes de que el agente haya fallado. Ese campo solo sirve para búsquedas posteriores a un error.

Una búsqueda con contrato incompatible devuelve `no_match`; no proponer una receta por parecido textual. Si faltan datos para decidir, devolver `needs_context` con los campos requeridos. Si solo hay evidencia vencida, indicar `stale` y permitir solicitar revalidación, sin venderla como vigente.

No bloquear toda tarea por ausencia de cicatrices. El agente continúa su estrategia habitual o pide contexto según corresponda.

## 12. Licencia y compra: reglas comunes

Se vende acceso a `(workspace_id, revision_id)`, no cada GET. `UNIQUE(workspace_id, revision_id)` impide duplicar licencias. El acceso propio no necesita compra.

Crear un registro de compra autenticado con revisión inmutable, precio del catálogo fijado en centavos, moneda, workspace, canal y vencimiento. Precio P0: 100 centavos USD. El frontend nunca decide el importe o el Stripe Price ID.

Estados: `quoted → payment_pending → paid → fulfilled`; ramas `expired`, `failed`, `reconciliation_required`, `refund_pending`, `refunded`.

- Un timeout de Stripe no significa pago rechazado. Dejar la compra pendiente de reconciliación.
- Una compra elige `checkout` o `mpp`; no habilitar los dos simultáneamente.
- Antes de crear un intento, bloquear una fila estable de derecho `(workspace, revision)` y comprobar licencia e intentos no terminales. Esto evita dos compras concurrentes del mismo derecho, incluso con request keys distintas.
- No mantener la transacción abierta durante llamadas externas. Reservar intento con lease, llamar a Stripe y persistir resultado con token de fencing. Un recuperador reutiliza los mismos identificadores/idempotency keys.
- La vuelta al navegador o el cierre de una pestaña no cancelan una Checkout Session.
- Para cambiar de canal, expirar/cancelar el anterior cuando el proveedor lo permita y reconciliar su estado. Si el resultado es incierto, devolver `payment_pending` y no iniciar otro cobro.
- Acceso comprado no equivale a vigencia perpetua de la recomendación. Cada preflight reevalúa el estado actual.

Usar claves de idempotencia estables por intento en las operaciones Stripe que las admitan. Persistir idempotencia también en la aplicación: no depender de cuánto tiempo Stripe conserve su caché. [Referencia oficial](https://docs.stripe.com/api/idempotent_requests).

## 13. Stripe Checkout obligatorio

P0 usa Checkout hospedado, `mode=payment`, un producto y precio de prueba. Admite solo pago inmediato por tarjeta para reducir estados. Desactivar promociones, impuestos automáticos y cantidades variables en la demo; cualquier expansión requiere definir cómo se valida el total.

Flujo:

1. Usuario autenticado pulsa “Desbloquear por US$1”.
2. Backend valida catálogo, vigencia y ausencia de licencia; fija la compra y el intento.
3. Crear o reutilizar el Customer del workspace y crear Checkout Session con precio del servidor, cantidad 1, referencias de compra en metadata y URL de retorno de origen fijo.
4. Usar `Idempotency-Key` estable por intento de creación. Persistir Session ID antes de responder cuando sea posible; reconciliar si la respuesta se pierde.
5. Checkout vuelve a `/purchases/:id`; mostrar “Esperando confirmación” hasta que el backend confirme.
6. Un webhook válido activa el entitlement y registra la venta sandbox.
7. La descarga posterior verifica workspace, licencia y revisión; no vuelve a llamar a Checkout.

Validar antes de fulfillment: cuenta y modo esperados, compra vinculada, Customer esperado, revisión, precio autorizado, cantidad, moneda y total; pago `paid`. Un `session_id` en la URL no prueba propiedad ni pago. [Checkout Sessions](https://docs.stripe.com/api/checkout/sessions).

### Webhooks

Verificar firma usando body sin modificar y SDK oficial. Guardar el evento y encolar su procesamiento atómicamente antes de responder 2xx; si falla la persistencia, responder error para que se reintente. Eventos duplicados no repiten entrega. El worker consulta el objeto actual cuando el orden sea ambiguo. [Guía oficial](https://docs.stripe.com/webhooks).

P0 procesa `checkout.session.completed` y `checkout.session.expired`. Para recuperación, puede reconciliar una Session conocida directamente con Stripe usando la misma función de fulfillment. No activar métodos de pago diferidos hasta implementar sus eventos. La extensión MPP añade sus objetos de pago y eventos según el adaptador oficial.

La función común `fulfillPurchase` comprueba el pago, registra su referencia única y otorga licencia dentro de una transacción. Nunca hace un segundo cobro. Un evento antiguo de expiración no puede degradar una compra ya pagada.

### Revocación durante una compra

Comprobar estado antes de crear el pago y antes de entregar. Si entre ambos momentos la receta fue revocada, bloquear su contenido y registrar `refund_pending`. En P0, mostrarlo claramente en una cola administrativa y permitir resolverlo desde Stripe sandbox; no afirmar que fue reembolsado hasta reconciliar el estado. La extensión de 48 h automatiza el reembolso idempotente.

Si solo caducó la verificación, no devolver receta como aplicable. Permitir ver el recibo y la evidencia histórica marcada como vencida, ofrecer revalidación y suspender su uso automático. La caducidad y la revocación son estados distintos.

Si faltan credenciales Stripe, responder `STRIPE_NOT_CONFIGURED` y desactivar compra. No simular un pago exitoso fuera de tests. Mostrar siempre el indicador «Stripe sandbox / sin cobro real» en la demo.

## 14. Extensión MPP y Link Agent Wallet

MPP permite solicitar un recurso, recibir HTTP 402, presentar credenciales de pago y recibir el recurso con recibo. La guía oficial utiliza `mppx` y un Stripe Profile. Tarjetas mediante SPT tienen mínimo documentado de US$0.50; el precio propuesto de US$1 lo supera. Disponibilidad depende de la cuenta y el país. [Integración](https://docs.stripe.com/payments/machine/mpp.md), [disponibilidad](https://docs.stripe.com/payments/machine).

Hacer un spike de 60–90 minutos temprano para comprobar SDK, perfil sandbox y transacción de prueba. Fijar las versiones que funcionen. Si la cuenta no dispone de esta capacidad, conservar Checkout y reportar la limitación exacta.

Endpoint previsto: `POST /api/machine/purchases/:id/pay`. El agente se autentica mediante `X-Scar-Key` para no ocupar los headers de pago que gestione MPP. No inventar el protocolo ni tratar un JSON casero con HTTP 402 como una integración MPP.

El adaptador debe demostrar que puede vincular challenge, compra, revisión, importe e identidad, además de identificar/reconciliar el pago si el proceso cae después del cobro. Usar la API real de la versión instalada; no suponer nombres de callbacks o metadata que el SDK no exponga.

Secuencia de aplicación:

1. El agente obtiene un preview y decide pedir una quote.
2. Un presupuesto del cliente autoriza como máximo US$1 para esa compra; excederlo requiere intervención del usuario.
3. El servidor reserva canal MPP y genera el desafío con el SDK.
4. El cliente externo presenta una credencial válida de prueba y reintenta.
5. El servidor verifica el pago, ejecuta `fulfillPurchase` y devuelve receta + recibo, o estado pendiente reconciliable.
6. Repetir la solicitud de una revisión licenciada devuelve contenido sin otro desafío de pago.

La autorización de gasto pertenece al cliente/wallet; SCAR no fabrica aprobaciones del usuario. El servicio no guarda tarjetas ni secretos del wallet. No incluir stablecoins ni custodia en P0.

Validar la extensión con la herramienta indicada en la documentación oficial, apuntando exclusivamente al endpoint sandbox. Incluir también pruebas propias de reintento, concurrencia y caída después del cobro. Si no se puede demostrar reconciliación, mantener MPP deshabilitado para uso normal y documentar su estado experimental.

## 15. Supabase: tablas y permisos

| Tabla | Contenido |
|---|---|
| `workspaces` | id, owner_user_id, name, stripe_customer_id, created_at |
| `agent_keys` | id, workspace_id, prefix, token_hash, scopes, revoked_at, last_used_at |
| `scars` | id, owner_workspace_id, created_at |
| `scar_revisions` | id, scar_id, revision, content_hash, metadata pública/privada, estado, visibility |
| `scar_payloads` | revision_id, receta y referencias detalladas de evidencia; solo backend |
| `verifications` | id, revision_id, scope_hash, fixture_version, verifier_version, status, verified_at, valid_until |
| `executions` | id, workspace_id, fixture_snapshot, task, agent_policy, status, result, metrics |
| `execution_events` | execution_id, seq, tool, input_sanitized, output_sanitized, effects |
| `evidence_runs` | verification_id, kind original/remedy/holdout, execution_id, assertions |
| `catalog_items` | revision_id, price_cents, currency, stripe_price_id, publication_status |
| `purchase_rights` | workspace_id, revision_id; fila estable para serializar compra/licencia |
| `purchases` | id, workspace_id, revision_id, catalog_snapshot, amount_cents, currency, rail, status, expires_at, request_key, request_hash |
| `payment_attempts` | id, purchase_id, rail, status, stripe_session_id, stripe_payment_intent_id, idempotency_key, lease_token, lease_until |
| `entitlements` | workspace_id, revision_id, source_purchase_id, granted_at, revoked_at |
| `stripe_events` | event_id, type, object_id, processing_status, attempts, payload mínimo necesario |
| `jobs` | id, kind, status, lease_token, lease_until, input, result; respaldados por Supabase Queues |

Constraints importantes: revisión inmutable; `(scar_id, revision)` único; evento `(execution_id, seq)` único; `event_id` Stripe único; derecho y entitlement únicos por workspace/revisión; referencia de pago único en el ledger de aplicación; request key única por workspace y hash de JSON canonicalizado.

Todos los datos de demo se separan por workspace y execution_id. El servidor inyecta esos IDs; el agente no puede elegir un workspace ajeno en un body.

RLS permite leer datos privados propios y metadatos de catálogo publicados. Recetas, evidencia detallada y tablas de pago no se exponen mediante una policy pública. `scar_payloads` no puede descargarse saltándose la API: el backend verifica propiedad o entitlement en cada entrega.

API keys: al menos 32 bytes aleatorios, prefijo visible y hash persistido; mostrar el secreto una vez. Scopes P0: `scars:read`, `scars:report`, `purchases:create`. Administrar claves y publicar al catálogo requiere sesión humana autorizada. Revocar una key debe impedir la siguiente solicitud.

El worker y el webhook usan credenciales privilegiadas de servidor. `service_role` puede omitir RLS: encapsularlo y validar relaciones de propietario en repositorios/RPCs; nunca entregarlo a agentes o navegador. [Seguridad Supabase](https://supabase.com/docs/guides/database/secure-data).

Los jobs utilizan lease y fencing: bloquear primero el job y luego sus filas de dominio; validar token y vigencia antes del commit. Reentregar un trabajo completado no vuelve a cobrar ni duplica verificaciones. Reejecutar una prueba interrumpida usa una copia limpia del fixture. Las llamadas externas ocurren fuera de las transacciones.

## 16. API HTTP y MCP

Autenticación web mediante sesión Supabase validada; agentes mediante `X-Scar-Key`. El webhook usa firma Stripe. El servidor deriva la identidad y el ámbito de los credenciales, no de campos del body.

| Ruta | Función |
|---|---|
| `POST /api/preflight` | Buscar coincidencias y devolver previews |
| `POST /api/scars/reports` | Crear candidato privado a partir de una ejecución propia |
| `POST /api/scars/:revision/verify` | Encolar verificación autorizada |
| `POST /api/scars/:revision/publish` | Publicar material sintético; admin de catálogo |
| `GET /api/scars/:revision` | Metadata permitida y estado actual |
| `GET /api/scars/:revision/content` | Receta/evidencia con propiedad o licencia |
| `POST /api/purchases` | Fijar revisión, importe y canal; deduplicar derecho |
| `POST /api/purchases/:id/checkout` | Crear/reutilizar Checkout Session |
| `GET /api/purchases/:id` | Estado de compra y entrega de su workspace |
| `POST /api/purchases/:id/reconcile` | Reconciliar un objeto existente; rate limit; nunca cobrar de nuevo |
| `POST /api/stripe/webhook` | Ingesta autenticada por firma |
| `POST /api/machine/purchases/:id/pay` | MPP, solo si extensión habilitada |
| `POST /api/demo/executions` | Ejecutar una política sobre una fixture propia |
| `GET /api/demo/executions/:id` | Resultado y métricas observadas |
| `GET /api/events?execution_id=...&after_seq=...` | Eventos de una ejecución autorizada |

`POST /api/purchases` acepta `{revision_id, rail, request_key}`. No acepta precio, moneda, workspace, URLs de retorno ni estado pagado del cliente.

La respuesta de compra existente incluye `already_licensed` o `payment_pending`; no genera una venta adicional. Acceso a recurso ajeno devuelve 404. Validación 400, no autenticado 401, permiso insuficiente 403, conflicto 409, límite 429 y configuración ausente 503. Solo el endpoint MPP produce el challenge 402 protocolario; REST normal devuelve `payment_required` como estado de acceso y un enlace/ID de compra.

MCP local expone:

```ts
scar_preflight(PreflightInput)
scar_get_recipe({ revision_id: string })
scar_report_failure({ execution_id: string, failure_event_seq: number })
scar_create_purchase({ revision_id: string, rail: "checkout" | "mpp", request_key: string })
scar_purchase_status({ purchase_id: string })
```

`scar_create_purchase` prepara un flujo; no ejecuta por sí mismo un pago con una tarjeta guardada. Para Checkout devuelve URL; para MPP el endpoint del SDK. El cliente wallet actúa aparte bajo su autorización.

MCP reutiliza la API, usa `SCAR_API_URL` y `SCAR_API_KEY`, y escribe logs a stderr. Proporcionar `llms.txt` y un ejemplo de integración que no contenga secretos. No publicar el servicio en directorios externos como parte del encargo.

## 17. Métricas y significado de «evitar»

Guardar llamadas CRM exitosas/fallidas, consultas SCAR, llamadas de verificación, finalización de tarea, duración observada y compras confirmadas. Mostrar cada categoría; consultar SCAR también tiene coste y latencia.

La demo controlada compara el mismo agente con memoria desactivada y activada sobre fixtures equivalentes. Mantener un holdout distinto para demostrar generalización de la regla entre tareas.

- Sin cicatriz: intento por email → 422 → resolver ID → asignar → confirmar.
- Con cicatriz: preflight → receta licenciada → resolver ID → asignar → confirmar.
- Resultado defendible: «1 llamada CRM fallida menos en este par de ejecuciones» si las trazas lo prueban.

Un simple match no es un fallo evitado. Fuera del experimento controlado, informar «receta consultada/aplicada» y la observación posterior, sin atribuir un contrafactual que no se midió.

No mostrar porcentajes de ahorro económico sin medición. Un cálculo de ROI comercial debe etiquetarse como escenario hipotético y exponer costes supuestos. Las ventas sandbox aparecen como pagos de prueba, no ingresos reales.

## 18. Interfaz y casos de producto

Diseño de consola técnica legible: tonos grafito, acento ámbar para cicatrices, verde para pruebas aprobadas y rojo para errores. Estados con texto e iconos además de color. UI en español y pitch en inglés.

Pantallas mínimas:

1. **Inicio / catálogo:** propuesta, caso de soporte, previews, precio experimental y CTA “Probar demo”. No claims de clientes, logos o ahorro inventados.
2. **Laboratorio:** agentes A/B, tickets diferentes, timeline, diferencia de resultados y progreso de verificación.
3. **Detalle de cicatriz:** precondiciones, contrato, evidencia simulada, fecha de vigencia, estado, receta si autorizada o CTA de compra.
4. **Compra:** precio/alcance antes de Checkout; pendiente, confirmada, vencida, fallo o reembolso pendiente después del retorno.
5. **Workspace:** cicatrices privadas, revisiones compradas, API keys, últimas consultas y observaciones.

Cada preview debe responder: «¿se aplica aquí?», «¿qué se probó?», «¿sigue vigente?» y «¿qué obtengo al pagar?».

Estados obligatorios: sin coincidencias, contexto insuficiente, obsoleta, revocada, verificación caída, proveedor de pago sin configurar, pago pendiente, usuario ya licenciado, webhook retrasado, MPP no disponible, API key revocada y desconexión Realtime.

Realtime avisa, pero la base es fuente de verdad. Al reconectar, recuperar eventos posteriores al último `seq`. La pantalla de compra consulta su estado con backoff mientras espera; no desbloquea contenido por parámetros de URL.

## 19. Estructura y configuración

```text
app/                         # UI y API
components/                  # Biblioteca, traces, compra, métricas
src/contracts/               # Zod, tipos y JSON Schema
src/scars/                   # Matching, lifecycle, recetas y verificadores
src/simulator/               # DemoCRM, fixtures, clonación y políticas
src/payments/                # Compras, fulfillment, checkout, mpp, reconciliación
src/server/                  # Auth, repositorios, permisos, cola
worker/                      # Verificación y eventos durables
mcp/                         # Adaptador stdio
supabase/migrations/
tests/unit/
tests/integration/
tests/e2e/
scripts/seed-demo.ts
scripts/setup-stripe-test.ts
.env.example
README.md
DEMO.md
SALES.md
```

Variables mínimas:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SERVICE_ROLE_KEY=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
STRIPE_PRICE_VERIFIED_FIX=
STRIPE_PROFILE_ID=
ENABLE_MPP=false
APP_BASE_URL=http://localhost:3000
SCAR_API_URL=http://localhost:3000
SCAR_API_KEY=
DEMO_EMAIL=
DEMO_PASSWORD=
ANTHROPIC_API_KEY=
ANTHROPIC_MODEL=
```

La configuración P0 rechaza claves Stripe live para evitar confundir ensayo con cobro real. Customer, Price, Profile y webhook deben pertenecer al entorno de prueba configurado. En Checkout hospedado no se necesita exponer una secret key al navegador.

Ofrecer comandos `pnpm dev`, `pnpm worker`, `pnpm mcp`, `pnpm db:setup`, `pnpm seed:demo`, `pnpm stripe:setup:test`, `pnpm test`, `pnpm test:integration`, `pnpm test:e2e`, `pnpm typecheck` y `pnpm build`.

El seed crea workspaces editorial/comprador/ajeno, usuarios sintéticos, políticas y fixtures. No preactiva licencias del comprador ni marca pagos de Stripe como exitosos. El script Stripe crea/reutiliza Product y Price de prueba con metadata propia; no modifica recursos ajenos ni cobra.

Documentar `stripe listen --forward-to localhost:3000/api/stripe/webhook` y el uso del secret emitido por ese listener. Una prueba real del flujo necesita completar una Checkout Session de sandbox de la aplicación; un evento genérico generado sin su compra asociada no demuestra fulfillment.

Stripe Projects es opcional. Si el equipo lo usa, consultar la documentación vigente: actualmente muestra `stripe projects add supabase/project`, que es más específico que el resumen corto del primer. Reutilizar recursos existentes cuando sea posible y registrar los recursos creados. [Referencia](https://docs.stripe.com/projects).

## 20. Orden de construcción

| Hito | Entrega | Prioridad |
|---|---|---|
| 1 | Contratos, DemoCRM, A/B y pruebas de fallo/corrección/holdout | P0 |
| 2 | Supabase, candidato/verificación, matching, TTL y aislamiento | P0 |
| 3 | Catálogo, compras, Checkout sandbox, webhook y licencia | P0 |
| 4 | UI, replay, métricas, keys y MCP | P0 |
| 5 | Pruebas de extremo a extremo y guion de venta | P0 |
| 6 | MPP, wallet externo, reconciliación y compensaciones | Extensión |

Realizar el spike de disponibilidad MPP al principio, sin convertirlo en dependencia del motor ni de Checkout. No empezar tres verticales comerciales antes de cerrar el caso de soporte.

## 21. Criterios de aceptación

### Conocimiento

1. A produce un 422 real en el simulador, corrige y genera un candidato con traza.
2. Una cicatriz solo se verifica si original falla, receta pasa y holdout pasa.
3. B resuelve un ticket diferente aplicando una receta recuperada del servicio; el éxito no está codificado por el nombre de la demo.
4. Versión/contrato incompatible no recibe recomendación aplicable; campo faltante produce `needs_context`.
5. Evidencia caducada no se sirve como vigente; revalidación fallida no renueva TTL.
6. Una comprobación en v3 no invalida de forma global la evidencia de v2.
7. No se ejecuta código ni se amplían permisos por instrucciones dentro de una cicatriz.

### Venta y pago

8. Sin licencia se puede leer preview, pero no receta por API, RLS ni enlaces de evidencia.
9. Checkout sandbox confirma un pago vinculado a una compra y otorga exactamente una licencia.
10. Visitar success_url sin pagar no otorga acceso; un webhook con firma inválida tampoco.
11. Reenviar el webhook y repetir el fulfillment no duplica licencia ni cobro.
12. Dos compras simultáneas del mismo derecho comparten el intento activo o responden conflicto, sin crear dos sesiones cobrables.
13. Una compra incierta se reconcilia; no se cobra de nuevo para «ver si funciona».
14. Repetir descarga con licencia no abre Checkout ni MPP.
15. Revocar antes de entregar bloquea receta y muestra el estado real de compensación.

### Aislamiento y operación

16. Workspace ajeno no obtiene contenido privado, compra, key o evidencia de otro usuario.
17. Publicar requiere rol editorial; un agente no puede marcar su propia propuesta como verificada.
18. Reiniciar worker conserva trabajos; redelivery no repite efectos comerciales.
19. Las métricas salen de trazas; compras sandbox no se presentan como ingresos reales.
20. El flujo login → demo → preview → compra → licencia → B resuelve → reutilización está cubierto por prueba de navegador.

### Extensión MPP

21. El endpoint pasa el validador oficial en sandbox, produce pago/recibo identificable y respeta la compra reservada.
22. Caída después del pago y repetición del request recuperan la misma licencia sin otro cobro.
23. No puede haber Checkout y MPP activos a la vez para el mismo derecho.
24. Un agente respeta el presupuesto de su cliente; no se inventan credenciales de pago ni consentimientos.

## 22. Definición de terminado y entrega

- Código, migraciones y documentación arrancan siguiendo comandos verificados.
- Motor, matching y Stripe están conectados: el resultado de un pago cambia el acceso del agente.
- La demo muestra material sintético y evidencia real del simulador, con políticas de referencia etiquetadas.
- Hay README, DEMO.md de 2–3 minutos y SALES.md con casos de venta honestos.
- Pasan pruebas pertinentes, typecheck y build. Reportar comprobaciones omitidas por falta de credenciales.
- Diferenciar Checkout probado, MPP probado y MPP pendiente; ninguno se declara terminado por mostrar una pantalla.
- El mensaje final de Claude debe explicar cómo ejecutar, cómo comprar en sandbox, cómo demostrar aprendizaje entre agentes y qué quedó fuera del alcance.

La demo termina cuando un agente distinto usa lo que otro aprendió y el derecho de acceso está respaldado por un pago verificable de prueba.

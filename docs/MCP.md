# PREMORTEM · MCP para Claude Code y otros clientes

Versión 0.1 · 03/10/2026 · Clasificación: Información Organizacional — Ocular Solution

El servidor MCP expone PREMORTEM como herramientas para un agente de código. Corre en tu equipo por stdio y habla con la API usando **tu sesión de usuario**; nunca usa credenciales de servidor.

## Conectar Claude Code

```bash
claude mcp add premortem \
  -e PREMORTEM_API_URL=http://localhost:3000 \
  -e PREMORTEM_EMAIL=tu-usuario@empresa.com \
  -e PREMORTEM_PASSWORD="$(security find-generic-password -s premortem -w)" \
  -- pnpm --dir /ruta/a/hack-sup -s mcp
```

La contraseña se lee del llavero en el momento de registrar el servidor: no la escribas en texto plano ni la pegues en el chat. Para la base local usa `mcp:local` en lugar de `mcp`.

## Herramientas

| Herramienta | Qué hace |
|---|---|
| `premortem_catalog` | Paquetes, escenarios, casos, versiones de agente y saldo |
| `premortem_create_agent` | Registra una versión inmutable de un agente a partir de su prompt; el prompt se guarda cifrado |
| `premortem_evaluate` | Cotiza y lanza una evaluación. Exige `maxUnits`: si cuesta más, no se lanza. Nunca compra unidades |
| `premortem_report` | Veredicto por mundo y reglas violadas con esperado y observado. `wait=true` espera hasta 3 minutos |
| `premortem_suggest_fix` | Propone un prompt corregido con reglas generales, su diff y avisos de sobreajuste. No crea la versión |
| `premortem_compare` | Compara dos runs mundo a mundo e indica si la comparación es válida |

## Flujo típico pidiéndoselo a Claude Code

> "Prueba el prompt de `agents/support.md` en PREMORTEM con el caso de reembolsos, máximo 4 unidades. Si falla algo, propón la corrección, aplícala al archivo, vuelve a probar y compara."

Claude Code encadena `premortem_create_agent` → `premortem_evaluate` → `premortem_report` → `premortem_suggest_fix` → edita el archivo → `premortem_create_agent` → `premortem_evaluate` → `premortem_compare`.

---
name: nini-agents-adapter-runtime
description: Mantiene adapters y mecanismos de aislamiento de Nini Agents CLI. Usar al agregar una herramienta, cambiar schema v2, `accountOverlay`, `fileOverlay`, `processSecret`, `osUserCredentialStore`, `inseparable`, rutas de estado o lanzamiento; no usar para comandos de perfil que consumen un adapter sin cambiar su contrato.
---

# Nini Agents CLI Adapter Runtime

## Proposito

Representar capacidades reales de cada herramienta y construir su runtime sin mezclar credenciales con estado normal.

## Alcance del proyecto

- `schema/adapter.schema.json`, `ai-tools/*/adapter.json`, validadores Bash y PowerShell, runtime overlay, credential store y aislamiento por usuario del sistema.
- Declaraciones de soporte para Windows, macOS y Linux y su documentacion asociada.

## Fuentes

- Leer `docs/adapter-schema.md`, `docs/support-matrix.md`, el adapter afectado y uno equivalente por mecanismo.
- Leer `lib/adapter-validation.sh`, `lib/MultiCli.AdapterValidation.psm1` y solo el modulo de runtime correspondiente al mecanismo.

## Patrones del proyecto

- `ai-tools/codex/adapter.json`: schema v2 separa `account.credentialFiles`, `normalState.sharedPaths`, `sessionPaths`, `filePaths` y soporte por plataforma.
- `lib/adapter-validation.sh` - `validate_adapter_v2` y `lib/MultiCli.AdapterValidation.psm1` - `Test-AdapterV2`: ambos validadores rechazan campos, rutas, placeholders y solapamientos inseguros.
- `lib/multicli-runtime.sh` - `runtime_build_overlay` y `lib/MultiCli.Runtime.psm1` - `New-RuntimeOverlay`: staging, lock y reutilizacion protegen lanzamientos concurrentes sin fallback a copia.

## Flujo

1. Investigar donde guarda credenciales, estado normal y sesiones la herramienta en cada plataforma autorizada.
2. Elegir el mecanismo mas estrecho que mantenga cuentas separadas y declarar como no soportado lo que no pueda probarse.
3. Actualizar schema o validadores antes de consumir un campo nuevo y mantener paridad Bash y PowerShell.
4. Actualizar adapter, guia de la herramienta y matriz de soporte como un solo contrato.
5. Validar manifest, creacion, lanzamiento, concurrencia y diagnostico con homes sinteticos antes de una prueba real protegida.

## Reglas

- No inferir rutas, logoutScope, concurrencia o soporte por analogia con otra herramienta.
- No solapar credenciales con sharedPaths o sessionPaths y no usar rutas absolutas ni traversal en declaraciones relativas.
- No copiar como fallback cuando falla un enlace del overlay; abortar para evitar divergencia silenciosa.
- No convertir evidencia de fixtures en una afirmacion de soporte real de plataforma.
- Conservar adapters schema v1 solo como compatibilidad legacy, sin agregarles campos schema v2.

## Validacion

- Ejecutar `bash scripts/validate-adapters.sh` y `bash tests/run-bats.sh adapter_schema.bats overlay_state.bats runtime_paths.bats` segun el alcance.
- Ejecutar `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Validate-Adapters.ps1` y las pruebas Pester equivalentes cuando Windows este disponible.
- Ejecutar `python3 scripts/validate-docs.py` si cambian guia, matriz o referencias al adapter.
- Registrar como no ejecutada cualquier verificacion de plataforma que el entorno actual no permita.

## Autoevaluacion

- Cada ruta pertenece a credencial, sesion o estado normal sin solapamiento?
- El mecanismo corresponde a capacidades comprobadas de la herramienta?
- Los dos validadores y la documentacion expresan el mismo contrato?

---
name: nini-agents-change-integral
description: Coordina cambios de Nini Agents CLI que alteran dos o mas fronteras entre launchers Bash y PowerShell, modulos, adapters, pruebas o documentacion. Usar al crear o modificar un flujo completo; no usar para un ajuste aislado de texto o una prueba sin cambio funcional.
---

# Nini Agents CLI Change Integral

## Proposito

Mantener una sola semantica observable entre plataformas mientras cada responsabilidad permanece en su modulo propietario.

## Alcance del proyecto

- Entradas canonicas `nini-agents` y `nini-agents.ps1`, shims `multi-cli` y `multi-cli.ps1`, modulos de `lib/`, definiciones de `ai-tools/`, pruebas de `tests/` y documentacion contractual de `docs/`.
- Cambios funcionales que atraviesan dos o mas de esas fronteras; las decisiones especializadas de credenciales, adapters o sincronizacion del fork se delegan a su skill correspondiente.

## Fuentes

- Leer `AGENTS.md`, `README.md`, `docs/CONTRIBUTING.md` y `docs/testing.md`.
- Leer ambos entrypoints y solo los modulos, adapters, pruebas y documentos alcanzados por el recorrido.

## Patrones del proyecto

- `nini-agents` - `cmd_new` y `nini-agents.ps1` - `New-Profile`: comandos equivalentes conservan validacion, metadata y comportamiento por plataforma; los shims legacy solo delegan.
- `lib/multicli-runtime.sh` - `runtime_initialize_profile` y `lib/MultiCli.Runtime.psm1` - `Initialize-RuntimeProfile`: la logica compleja vive en modulos paralelos, no duplicada dentro del dispatcher.
- `tests/overlay_state.bats` y `tests/OverlayState.Tests.ps1`: un contrato multiplataforma se caracteriza en sus dos implementaciones cuando ambas lo soportan.

## Flujo

1. Trazar el comando desde el dispatcher hasta modulos, filesystem, procesos, adapters y consumidores.
2. Delimitar comportamiento visible, invariantes, plataformas, archivos, compatibilidad, exclusiones y pruebas antes de editar.
3. Asignar cada decision al modulo existente y mantener paridad Bash y PowerShell cuando el contrato sea comun.
4. Actualizar adapters, soporte y documentacion solo cuando cambie el contrato que describen.
5. Agregar una prueba que falle sin el cambio y ejecutar primero las validaciones focalizadas.

## Reglas

- Conservar Bash 3.2 y Windows PowerShell 5.1; no introducir sintaxis incompatible.
- No convertir los entrypoints en nuevos modulos monoliticos ni crear abstracciones sin una frontera repetida.
- No modificar instalaciones activas bajo `~/.local/share/nini-agents` o `~/.local/share/multi-cli` durante el desarrollo.
- No afirmar soporte de una plataforma sin una ejecucion real en ella.

## Validacion

- Ejecutar `bash tests/run-bats.sh <pruebas.bats>` para los recorridos Bash tocados.
- Ejecutar `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -CI` cuando PowerShell este disponible y el contrato Windows cambie.
- Ejecutar `bash scripts/validate-adapters.sh` y `python3 scripts/validate-docs.py` solo si se tocaron adapters o documentacion.
- Ejecutar el gate de cobertura focalizado aplicable descrito en `docs/CONTRIBUTING.md` para lineas productivas modificadas.

## Autoevaluacion

- El recorrido y su owner quedaron identificados antes de implementar?
- Las dos plataformas conservan la misma semantica donde corresponde?
- La validacion cubre el comportamiento y el fallo esperado?

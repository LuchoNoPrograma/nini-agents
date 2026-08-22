---
name: nini-agents-upstream-integration
description: Integra cambios de Multi-CLI upstream y evoluciona el fork Nini Agents CLI sin perder personalizaciones ni compatibilidad. Usar al sincronizar remotes, portar parches locales, renombrar producto, preparar una migracion desde MultiCLI AI o Codexporter, o construir una release; no usar para una feature ordinaria sin relacion con el fork.
---

# Nini Agents CLI Upstream Integration

## Proposito

Mantener trazabilidad entre la base upstream, los cambios propios y las migraciones consumidoras sin tocar instalaciones o datos reales.

## Alcance del proyecto

- Remotes `origin`, `multi-cli-upstream` y `legacy`, branch base `multi-cli-base`, branch de desarrollo `main`, branch `legacy-gui`, instaladores, release y compatibilidad de CLI.
- Migracion futura de consumidores desde `/home/nini/StudioProjects/multi_cli_ai` o `../codexporter` solo cuando exista un alcance separado y aprobado.

## Fuentes

- Leer `AGENTS.md`, `docs/CONTRIBUTING.md`, `release/README.md`, los instaladores y la historia Git relevante.
- Comparar el commit upstream base, los commits entrantes y los cambios propios antes de resolver cualquier divergencia.

## Patrones del proyecto

- `install/install.sh` y `install/install.ps1`: `NINI_AGENTS_REPO` y `NINI_AGENTS_INSTALL_DIR` prefieren el fork mientras las variables `MULTICLI_*` permanecen como compatibilidad temporal.
- `release/build.sh` y `release/build.ps1`: la version canonica de `release/VERSION` debe coincidir con `nini-agents` y `nini-agents.ps1`; los paquetes incluyen los shims legacy.
- `tests/release_build.bats` y `tests/RepositoryLayout.Tests.ps1`: release y layout se verifican sin depender de la instalacion activa.

## Flujo

1. Verificar worktree, remotes, branches, base comun y commits entrantes sin modificar archivos.
2. Clasificar cada diferencia como upstream, personalizacion vigente, compatibilidad temporal o cambio obsoleto.
3. Delimitar por separado sincronizacion, renombre, port de comportamiento y migracion de consumidores.
4. Integrar en una branch dedicada, conservar commits trazables y resolver conflictos segun contratos y pruebas, no por preferencia de lado.
5. Validar desde el checkout con homes temporales antes de cambiar instaladores, consumidores o la copia activa.

## Reglas

- No hacer push, force-push, rebase destructivo, reset, tag o publicacion sin autorizacion expresa.
- No mezclar una sincronizacion upstream con el renombre total y la migracion de consumidores en un solo delta.
- No asumir que una version escrita en archivos ya tiene tag o release publicada.
- Preservar licencias y atribucion MIT del upstream al renombrar el fork.
- No editar ni reinstalar `~/.local/share/multi-cli` para probar el checkout.

## Validacion

- Ejecutar `git diff --check` y revisar `git diff --stat` y `git status --short`.
- Ejecutar `bash release/build.sh --check` cuando cambien version, entrypoints o release.
- Ejecutar pruebas focalizadas de instalacion y layout cuando cambien rutas, remotes por defecto o packaging.
- Comparar los comandos y flags publicos antes y despues cuando una migracion de consumidor dependa de ellos.

## Autoevaluacion

- Cada cambio propio puede distinguirse de la base upstream?
- La sincronizacion conserva licencias, compatibilidad y personalizaciones aprobadas?
- La validacion ocurre sin tocar la instalacion o los perfiles reales?

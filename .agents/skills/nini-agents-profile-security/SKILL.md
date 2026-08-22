---
name: nini-agents-profile-security
description: Protege perfiles, credenciales y transferencias de Nini Agents CLI. Usar al cambiar `new`, `delete`, `clone`, `auth`, `continue`, templates, exportacion, importacion, migracion o movimiento entre equipos; no usar para estado ordinario que no cruza una frontera de cuenta.
---

# Nini Agents CLI Profile Security

## Proposito

Impedir perdida, copia accidental, exposicion, sobreescritura o revocacion de credenciales durante operaciones de perfil.

## Alcance del proyecto

- Limites `auth/`, `.profile.json`, `.runtime/`, credential stores del sistema, perfiles legacy y schema v2.
- Transferencias actuales sin credenciales y la direccion aprobada de portar el movimiento seguro de Codexporter sin revocar tokens.

## Fuentes

- Leer `lib/transfer.sh`, `lib/MultiCli.Transfer.psm1`, `lib/migration.sh`, `lib/MultiCli.Migration.psm1` y los comandos de perfil en ambos entrypoints.
- Para portar movimiento entre equipos, leer `../codexporter/lib/transfer.sh`, `../codexporter/lib/guards.sh` y `../codexporter/lib/core.sh`; tratarlos como contrato legacy que debe verificarse, no como codigo ya integrado.

## Patrones del proyecto

- `lib/transfer.sh` - `transfer_is_credential_path` y `transfer_collect_path`: export, import y templates usan allowlists, no siguen enlaces y excluyen credenciales, sesiones y archivos no clasificables.
- `lib/migration.sh` - `migration_plan_credential` y `migration_exec_ops`: las credenciales nunca se sobreescriben y cada operacion queda registrada para continuar o recuperar.
- `../codexporter/lib/transfer.sh` - `move_profile`, `../codexporter/lib/guards.sh` - `local_busy_report` y `../codexporter/lib/core.sh` - `locate_owner`: el movimiento seguro comprueba un propietario activo, procesos cerrados, staging verificado, activacion atomica, rollback y copia inactiva.

## Flujo

1. Identificar origen, destino, propietario activo, formato legacy o schema v2, mecanismo del adapter y archivos que pueden cruzar el limite.
2. Inspeccionar metadata, rutas, tipos, permisos y presencia de procesos sin imprimir contenido secreto.
3. Separar planificacion de escritura y ofrecer dry-run para migraciones o movimientos destructivos.
4. Preparar en staging, validar estructura e integridad, comparar con el origen y activar solo despues de completar los preflights.
5. Mantener una ruta de rollback y una copia inactiva antes de desactivar o mover el origen.
6. Probar exito, rechazo y fallo intermedio usando perfiles sinteticos en directorios temporales.

## Reglas

- No leer, mostrar, registrar ni versionar valores de `auth.json`, tokens o secretos.
- No ejecutar logout, revocacion o reautenticacion como parte de una copia o movimiento.
- `export`, `import`, templates y `continue` permanecen libres de credenciales; un futuro `move` debe ser un contrato separado y explicito.
- No operar sobre `~/.codex`, `MULTICLI_HOME` real ni la instalacion activa durante pruebas automatizadas.
- Fallar cerrado ante enlaces, hardlinks, traversal, contenido desconocido, credencial destino diferente o procesos activos.
- No borrar el origen hasta validar el staging y no eliminar la copia inactiva automaticamente.

## Validacion

- Ejecutar `bash tests/run-bats.sh profile_safety.bats transfer_safety.bats migration.bats auth_command.bats` segun el alcance.
- Ejecutar las suites Pester equivalentes cuando PowerShell este disponible.
- Verificar que las pruebas usen `MULTICLI_HOME` temporal y fixtures sin secretos reales.
- Comprobar permisos y JSON por estructura sin volcar valores de credenciales en la salida.

## Autoevaluacion

- La operacion conserva exactamente un propietario activo o rechaza la ambiguedad?
- Existe recuperacion verificable antes de cualquier desactivacion?
- Ninguna credencial puede viajar por un flujo que promete ser credential-free?

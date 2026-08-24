# Nini Agents: checkpoint operativo

- Actualizado: 2026-08-24
- Branch: `main`
- HEAD y `origin/main` observados: `293c48d31731`
- Objetivo inmediato: la migracion de los quince perfiles Codex y la
  optimizacion del launcher ya estan cerradas en Linux. El siguiente gate
  separado es evaluar los cinco conflictos omitidos de Luis.

Este archivo es el punto corto de reanudacion. Leerlo despues de
[AGENTS.md](../../AGENTS.md) y antes de abrir la
[bitacora completa](nini-agents-end-to-end.md). La bitacora conserva el plan,
las decisiones y la evidencia historica canonica; consultarla completa solo
para reconstruir historia, resolver contradicciones o delimitar una etapa.

Este checkpoint no concede autorizacion. Todo cambio o acceso real conserva
los gates de la bitacora y el alcance previo exigido por `AGENTS.md`.

## Direccion estable

- Schema v2 es el formato objetivo: metadata en `.profile.json`, credenciales
  bajo `auth/`, runtime reconstruible bajo `.runtime/` y estado normal segun el
  adapter.
- Los perfiles nuevos no deben crearse en schema v1.
- El lanzamiento de perfiles legacy debe seguir funcionando durante la
  migracion gradual; no se deben retirar todavia los shims, variables, rutas,
  IDs ni ownership interno legacy.
- La migracion interna legacy a schema v2 es determinista, voluntaria y
  fail-closed. La migracion futura de MultiCLI AI y Codexporter es otro alcance:
  ninguno de esos consumidores se modifica para probar `codex/luis`.
- Ningun flujo debe ejecutar logout, revoke, refresh o reautenticacion como
  parte de una copia o migracion. Un lanzamiento real de Codex posterior al
  apply requiere autorizacion separada porque la herramienta si podria escribir
  o refrescar su estado.

## Estado del motor y del worktree

- `main` contiene el motor renombrado `nini-agents`; `multi-cli` y
  `multi-cli.ps1` siguen siendo shims temporales.
- Las etapas A-D estan cerradas. La etapa E contiene el nucleo transaccional
  interno de movimiento seguro, pero no transporte remoto ni comando publico
  completo. La etapa F ofrece JSON v1 para consultas read-only; las mutaciones
  machine-safe y las migraciones consumidoras siguen pendientes.
- El worktree contiene cambios locales sin commit ni push correspondientes a
  varios tramos ya aprobados: compatibilidad whole-root de lanzamiento legacy,
  endurecimiento del migrador, SQLite directo, MCP compartido y clasificacion
  sintetica de residuos Codex. Preservarlos; no stagear,
  des-stagear, revertir, commitear ni mezclar con trabajo ajeno sin permiso.
- Los archivos modificados observados son los launchers Bash/PowerShell,
  modulos de migracion, adapter y documentacion Codex, validacion del adapter,
  matriz de soporte, pruebas Bash/Pester y la bitacora. Antes de editar alguno,
  revisar el diff porque contiene trabajo concurrente acumulado.

## Lo que ya implemento y valida el migrador

- El comando `nini-agents migrate <tool>/<name> --dry-run` clasifica primero el
  perfil completo y rechaza entradas desconocidas o solapadas antes de escribir.
- El apply usa plan, journal, staging/rollback y operaciones verificables. Las
  credenciales se mueven dentro del mismo volumen; no se copian como fallback,
  no se sobreescribe un destino distinto y se rechazan symlinks o hardlinks.
- Un dry-run no crea el shared root, metadata, journal, locks, rollback ni
  `auth/`. `--prefer-profile` no evita la clasificacion ni las protecciones de
  credenciales.
- El adapter sigue siendo la fuente declarativa de `credentialFiles`,
  `sharedPaths`, `sessionPaths`, `runtimePaths`,
  `migrationPreservePaths` y credenciales compartidas; no hay allowlist privada
  por perfil.
- Para Codex ya se demostraron y declararon como estado normal compartido
  `AGENTS.md`, `installation_id` y `log/`. Las familias SQLite observadas en
  Codex 0.147.0 son estado de sesion directo bajo `sqlite_home`, pero sus
  instancias legacy se preservan inactivas para no mezclar una base con
  sidecars de otra familia. No se enlazan dentro de `.runtime`.
- Schema v2 incorpora `sharedCredentialState` para credenciales que el upstream
  exige compartir entre perfiles sin mezclarlas con la cuenta principal. Codex
  declara `.credentials.json` (`jsonObjectFile`) y `mcp-oauth-locks/`
  (`directory`) bajo `MULTICLI_HOME/.shared/codex/mcp`; `auth.json` permanece
  exclusivamente bajo `profile/auth/`.
- Dos perfiles Codex apuntan al mismo store y locks MCP, pero a `auth.json`
  distintos. El adapter fuerza los modos file para ambos credential stores y
  mantiene SQLite directo en el shared root. La inicializacion compartida es
  serializada y fail-closed ante links o tipos inesperados; no lee el contenido
  de un store existente ni usa copia fallback.
- La migracion clasifica los objetos MCP legacy como `shared-credential` y los
  preserva por rename del mismo volumen bajo
  `.inactive/migrations/<adapter>/<profile>/shared-credentials/`. No sigue ni
  muestra targets, no los importa al store activo y los restaura durante
  rollback. El store activo nace solo en el primer launch schema v2, por lo que
  migrate no autentica, refresca, revoca ni regenera MCP.
- Shared credentials y su recuperacion inactiva quedan fuera de templates,
  export, import, clone y move; imports que intenten introducir sus rutas o
  descendientes se rechazan como credenciales.
- El validador Bash fue corregido para no producir un falso campo desconocido
  por `SIGPIPE` bajo `pipefail` al validar allowlists grandes.
- `normalState.runtimePaths` declara estado reconstruible que la herramienta
  crea dentro de `.runtime`: el motor no crea placeholders ni links, `doctor`
  admite sus descendientes y migracion preserva objetos legacy por rename bajo
  `runtime-state/` con journal y rollback.
- `normalState.migrationPreservePaths` es un subconjunto exacto de estado
  normal que solo cambia migracion. El objeto legacy se preserva por rename
  bajo `profile-state/`; no se compara, fusiona ni activa, y rollback lo
  devuelve. Runtime schema v2 conserva la clase normal original.
- Codex clasifica `.sandbox_migration`, `cache/`, `models_cache.json` y
  `version.json` como runtime reconstruible; `shell_snapshots/` y
  `thread-writer-locks/` como sesion. Las familias SQLite exactas y
  `thread-writer-locks/` usan preservacion legacy `profile-state`.
  `legacyBackupPattern: dotSuffix`
  clasifica los dos backups MCP observados como credenciales y los preserva
  inactivos sin leerlos ni copiarlos.

## Semantica de rutas que no debe simplificarse

El rechazo actual no significa que falte una ruta fisica. Significa que hay
estado presente para el cual el adapter no declara una frontera segura:

| Caso | Comportamiento vigente |
|---|---|
| Ruta inexistente y no declarada | No participa y no falla |
| Ruta normal declarada pero inexistente | No genera operacion de migracion |
| Ruta presente pero no declarada | Se reporta `unknown` y todo se rechaza antes de escribir |
| Ruta presente declarada `unsafePaths` | Se reporta `unsafe` y todo se rechaza antes de escribir |
| Ruta MCP presente declarada `sharedCredentialState` | El dry-run planea preservar el objeto inactivo; apply usa rename journalizado y rollback lo devuelve |
| Backup MCP que coincide con `legacyBackupPattern: dotSuffix` | Se trata como credencial compartida legacy y se preserva bajo `shared-credentials/`; nunca se transporta |
| Ruta presente declarada `runtimePaths` | Se preserva inactiva bajo `runtime-state/`; no se comparte, enlaza ni inicializa vacia |
| Ruta presente declarada `migrationPreservePaths` | Conserva su clase normal en runtime, pero su objeto legacy se preserva inactivo bajo `profile-state/`; nunca se mezcla con el root vivo |
| Credencial declarada pero ausente | El plan actual crea un placeholder vacio bajo `auth/` |
| Credencial declarada como symlink o hardlink | Se rechaza antes del apply |
| Ruta que coincide con credencial y estado normal | Se reporta `overlap` y se rechaza |

Consecuencia: agregar todos los nombres observados al adapter no basta. La
frontera MCP requirio un contrato separado de credenciales compartidas, un root
propiedad del motor, locks comunes, exclusion de transporte y preservacion
legacy inactiva. Nunca debe simplificarse a `sharedPaths` ni a una copia de
`.credentials.json` por perfil.

## Evidencia real protegida de `codex/luis`

- El launcher legacy es `codex-luis`; el spec correcto del store es
  `codex/luis`. No usar `codex/codex-luis`.
- El G5 read-only ya ejecutado comprobo estructuralmente que el perfil legacy y
  su `auth.json` eran regulares, que la credencial tenia link count uno, que no
  existian `auth/auth.json`, metadata v2 ni artefactos de migracion, que origen
  y shared root estaban en el mismo volumen y que el perfil estaba inactivo.
  No se abrio ni parseo el contenido de autenticacion.
- El dry-run real fue rechazado antes de escribir por 37 entradas top-level no
  declaradas y cero overlaps. Por nombre y tipo, 29 parecen bases SQLite y
  sidecars, caches, logs, locks, snapshots o marcadores modernos; cuatro parecen
  configuracion/backups locales y cuatro pertenecen a OAuth MCP/credenciales y
  sus respaldos. Estas categorias son inferencias, no clasificaciones aprobadas.
- `.credentials.json` y `mcp-oauth-locks` son symlinks cuyos targets existentes
  quedan fuera tanto del perfil como del shared root Codex. Solo se comprobo el
  alcance estructural: no se registro el target ni se leyo su contenido.
- Despues del rechazo, la identidad estructural de `auth.json` permanecio igual
  y siguieron ausentes `auth/auth.json`, `.profile.json`, journal, lock y
  rollback. No hubo logout, refresh, revoke, regeneracion, copia, move ni borrado.
- El segundo G5 real, ejecutado despues del contrato MCP compartido, volvio a
  comprobar perfil inactivo, credencial regular con link count uno, mismo
  volumen y ausencia de destinos o artefactos. El dry-run se rechazo antes de
  imprimir el plan por 14 entradas `unknown`: dos backups OAuth legacy y doce
  caches, configuraciones/backups, snapshots, locks, temporales o marcadores
  pendientes de clasificacion contractual.
- Los objetos MCP activos `.credentials.json` y `mcp-oauth-locks` ya no
  aparecen como `unknown`, lo que confirma su clasificacion
  `shared-credential`. Como el rechazo global precede a la construccion del
  plan, el G5 no llego a mostrar `preserve-shared-credential`; esa operacion
  sigue demostrada solo con fixtures hasta resolver los 14 residuos.
- El postflight del segundo G5 conservo identicas las huellas de metadata de
  `auth.json` y del top-level; siguieron ausentes metadata, journal, lock,
  rollback, store MCP compartido y recuperacion inactiva. No se leyo contenido
  ni se resolvieron o mostraron targets.
- El G2 sintetico posterior clasifico ocho de esas 14 entradas mediante
  evidencia del binario Codex 0.147.0 y fixtures temporales. No repitio el G5
  real. Por tanto, se espera que el proximo dry-run mantenga exactamente seis
  `unknown`: `.personality_migration`, `.tmp`, `tmp`, los dos backups locales
  `config.toml.bak-*` y `gpt-5.5-no-intermediary-updates.md`; esto aun no es
  evidencia de una ejecucion sobre `codex/luis`.
- El G5 protegido mas reciente uso `--dry-run --preserve-unknown` despues de
  agregar preservacion transaccional. Luis termino con codigo cero: las 18
  rutas SQLite/sidecars y `thread-writer-locks/` se planearon como 19
  operaciones `preserve-profile-state`; los seis residuos se planearon como
  `preserve-unknown`. No se mezclo ninguna familia SQLite con el root default.
- El mismo dry-run se ejecuto sobre los otros catorce perfiles Codex excepto
  `codex/tienda`. Los quince planes terminaron con codigo cero. En cada perfil,
  el arbol estructural y la metadata de filesystem de `auth.json` fueron
  identicos antes/despues. No se imprimieron nombres privados de sesiones ni se
  crearon artefactos. `codex/tienda` permanecio abierto, excluido e intacto.
- El G9 real posterior confirmo fuera del sandbox que la sesion activa era
  `codex/tienda`, legacy y sin referencias a los destinos de Luis. El apply de
  `codex/luis --preserve-unknown`, sin `--prefer-profile`, termino con journal
  `completed`: 334 operaciones `done`, cinco conflictos `skipped`, cero fallos
  y las cuatro clases de recuperacion inactiva presentes.
- La migracion movio el mismo objeto `auth.json` a `auth/auth.json`; antes del
  launch conservo toda su metadata de filesystem. Los smokes de version y
  `login status` pasaron, el runtime y store MCP se construyeron y la interfaz
  real permanecio activa ocho segundos sin prompts antes de cerrar con codigo
  cero. Durante esa interfaz Codex escribio el mismo archivo de credencial:
  dispositivo, inode, link count y modo no cambiaron; tamano y mtime si. No se
  leyo contenido ni se infirio la causa.
- `codex/tienda` siguio legacy y su credencial conservo la metadata observada.
  No quedo ningun proceso Luis activo. No volver a aplicar la migracion de Luis;
  a partir de ahora debe tratarse como perfil schema v2.

## Cierre de la migracion de perfiles Codex

- `codex/abejita` completo apply, postflight, wrapper Nini y smokes antes del
  incidente.
- `codex/amigo` quedo parcial cuando su plan grande expuso que
  `migration_journal_write` reconstruia el JSON con multiples procesos `jq`
  despues de cada operacion: el costo cuadratico alcanzo `ARG_MAX` y la ruta de
  error reemplazo el journal anterior por un archivo vacio.
- El proceso real sobrevivio a la interrupcion del comando supervisor y siguio
  activo fuera del sandbox hasta ser localizado y detenido.
- El fix local serializa cada snapshot completo mediante un unico `jq`
  streaming. Solo publica el temporal tras exito; ante error conserva el journal
  anterior. El journal por operacion y el rollback siguen siendo obligatorios.
- La recuperacion real de Amigo restauro contra la evidencia congelada 16 slots,
  285 `merge-move`, 32 preservaciones y la credencial. Volvio a layout legacy
  con identidad de credencial preservada y sin leer contenido de autenticacion.
  Su unico dry-run posterior paso con 500 operaciones y no cambio el arbol ni
  la metadata de `auth.json`.
- El apply posterior y separado de `codex/amigo` repitio el preflight fuera del
  sandbox y un dry-run fresco despues de las otras migraciones. El plan mantuvo
  500 operaciones: 213 `merge-move`, 246 duplicados, seis conflictos, una
  credencial, 32 preservaciones, un link omitido y metadata v2. El apply con
  `--preserve-unknown`, sin `--prefer-profile`, termino `completed`: 493
  operaciones `done`, siete `skipped` y cero `failed`. La identidad de
  filesystem de la credencial se preservo y no quedaron lock, rollback ni
  procesos residuales.
- `codex/amigo` recibio wrapper Nini conservando
  `BROWSER=/usr/bin/microsoft-edge`; `login status`, el enlace de runtime y el
  smoke TUI pasaron sin cambiar la metadata de la credencial.
- `codex/ari`, `codex/diego`, `codex/kitsune`, `codex/magic`, `codex/mari`,
  `codex/nexo`, `codex/nico`, `codex/omega`, `codex/pro`, `codex/sam` y
  `codex/willy` completaron schema v2, wrapper Nini, `login status` autenticado
  y smoke TUI. Sus journals quedaron `completed`, con 4016 operaciones totales
  y cero `failed`.
- `codex/tienda` completo al final un G5 read-only y un G9 separado desde otro
  perfil schema v2. El dry-run fresco mantuvo 1144 operaciones: una credencial,
  tres preservaciones de credencial compartida, cuatro de runtime, 15 de estado
  de perfil, ocho unknown, 887 `merge-move`, 218 duplicados, seis conflictos
  omitidos, un link omitido y metadata v2.
- El journal de Tienda termino `completed`: 1137 operaciones `done`, siete
  `skipped`, cero `failed` y cero pendientes. La credencial quedo regular con un
  solo enlace bajo `auth/`; las cuatro clases de recuperacion inactiva estan
  presentes y no quedaron lock ni rollback. El motor reconoce el perfil como
  schema v2, por lo que no se debe repetir el apply.
- `codex-tienda` ejecuta el launcher Nini y conserva
  `BROWSER=/usr/bin/brave-browser`. `--version`, `login status`, el enlace de
  runtime y dos smokes TUI controlados pasaron; el segundo cerro con codigo cero
  tras ocho segundos, no envio prompts, conservo la metadata de la credencial y
  no dejo procesos residuales.
- Durante Tienda, el proceso supervisor devolvio no cero despues de que el
  journal ya estaba `completed`. El postflight inmediato e independiente
  demostro el estado schema v2 completo y una invocacion posterior de `migrate`
  fue no-op; no se repitio el apply. La causa del retorno supervisor no se
  atribuye sin evidencia al motor.
- La latencia previa de `launch` quedo resuelta sin retirar controles de
  seguridad. El hot path parsea una vez el contrato necesario, reutiliza sus
  campos y comprueba traversal al consumir cada ruta. La validacion semantica
  exhaustiva permanece en mutaciones, `permissions`, `doctor` y validacion de
  repositorio.
- En el fixture Codex caliente, el launcher paso de 388 a dos procesos `jq`
  (reduccion de 99.5 %) y midio 0.08 s frente a 0.03--0.04 s del binario no-op
  directo. No se relanzaron perfiles reales para obtener esta medicion.
- `nini-agents permissions show|set` gestiona los defaults de los perfiles
  Codex account-overlay compartidos para sesiones nuevas. `set` ofrece `read-only`, `workspace` y
  `full-access`, elimina overrides sandbox legacy, valida un staging con Codex
  y reemplaza `config.toml` atomicamente. No lee ni modifica credenciales; una
  sesion ya activa conserva su seleccion hasta reiniciarse.

## Validacion ya completada

- Pruebas focalizadas schema/migracion vigentes: 78/78.
- Suite Bash completa: 297/297 en una ejecucion limpia.
- Adapters: 17/17 validos. Sintaxis Bash, parseo JSON, documentacion y
  `git diff --check` pasaron al cierre del G2 compartido.
- Tras el segundo G5, la validacion documental y `git diff --check` volvieron a
  pasar; no se repitieron suites funcionales porque solo cambio evidencia
  documental.
- El G9 real valido preflight de procesos fuera del sandbox, rename con
  identidad fisica, journal completado, metadata v2, recuperaciones inactivas,
  runtime reconstruido, estado de login y launch controlado en Linux.
- El G9 final de Tienda valido un plan de 1144 operaciones, journal
  `completed` con cero fallos, schema v2, recuperacion inactiva, wrapper con
  Brave, autenticacion, runtime y TUI con salida controlada en Linux.
- Tras documentar Tienda, `python3 scripts/validate-docs.py` y
  `git diff --check` pasaron. Las advertencias CRLF observadas pertenecen a
  archivos PowerShell locales ya modificados y no fueron alteradas por este
  cierre documental.
- Las pruebas automatizadas mutables siguieron usando roots temporales. El G9
  real autorizado si modifico `codex/luis`, el root compartido y el store MCP
  conforme al journal y al postflight descritos arriba.
- Tras cerrar el lote, `python3 scripts/validate-docs.py` y
  `git diff --check` pasaron. Esta validacion documental no sustituye los
  postflights, journals y smokes reales enumerados arriba.
- El gate de cobertura se intento, pero termino antes de instrumentar porque
  `bashcov` no esta instalado.
  PowerShell/Pester, Windows, macOS y ShellCheck no estan disponibles en este
  host y no deben declararse verificados.
- La optimizacion y permisos pasaron sus 74 pruebas Bash focalizadas y la suite
  Bash completa quedo 310/310. El config sintetico tambien paso
  `codex --strict-config --version` con Codex CLI 0.147.0. La paridad PowerShell
  esta implementada pero no ejecutada en este host; el gate Bash de cobertura
  sigue bloqueado porque `bashcov` no esta instalado.

## Trabajo restante

El lote real de perfiles Codex esta cerrado: los quince perfiles son schema v2,
usan wrappers Nini y tienen smokes observados en Linux. No repetir migraciones
ni limpiar recuperaciones inactivas sin un alcance nuevo.

El end-to-end global todavia no esta cerrado. Falta, con gates separados:

1. **Evaluar los cinco conflictos omitidos de Luis:** el launch uso las
   versiones existentes del root compartido porque no se autorizo
   `--prefer-profile`. No modificar esos residuos sin investigacion read-only,
   alcance de recuperacion y aprobacion explicita.
2. **Continuar el plan del motor y consumidores:** las mutaciones JSON, el
   comando publico de movimiento, MultiCLI AI y Codexporter permanecen fuera de
   estos gates y no deben presentarse como implementados.

PowerShell, Windows y macOS no fueron verificados por los G9 reales de perfiles.

## Regla de cierre y continuidad

Cuando un tramo aprobado cambie codigo, evidencia, bloqueos o gates:

1. anexar el detalle completo a la bitacora canonica;
2. actualizar aqui solo el estado operativo, invariantes y siguiente accion;
3. registrar validaciones no ejecutadas y cualquier efecto real sobre datos;
4. mantener este archivo compacto y libre de secretos, rutas privadas, hashes,
   IDs de cuenta y contenido de credenciales.

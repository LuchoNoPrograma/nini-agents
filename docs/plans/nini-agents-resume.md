# Nini Agents: checkpoint operativo

- Actualizado: 2026-08-24
- Branch: `main`
- HEAD observado: `ad9630c99648`
- `origin/main` observado: `293c48d31731`; el commit local todavia no fue
  publicado.
- Validacion aislada: PR borrador `#1`, base remota temporal
  `validation/eng-02a-base-ad9630c`, delta `a155613`, harness `b7790c9` y tip
  `879d461` con la prueba in-process de cobertura. Ninguna de esas refs modifica
  `origin/main`.
- ENG-02B/C aisladas: branch temporal `validation/eng-02b`, commits `c36a229`
  y `fc3361f`. El tip agrega `delete --json` y `exec` stdout-clean sin modificar
  `origin/main` ni publicar un release.
- Integracion local: ENG-02B/C fue portado manualmente al worktree concurrente
  de `main`, sin cambiar su HEAD, stagear ni borrar cambios previos. El wrapper
  instalado en `~/.local/bin/nini-agents` ya delegaba a este checkout,
  por lo que `nini-agents help` expone `exec` sin reescribir el instalador.
- Objetivo inmediato: continuar el cierre de Nini Hub con `QA-01`; el producto
  lleva `12/14`. La publicacion del motor, el cutover y los incidentes base de
  Pester/Bash 3.2 permanecen como gates separados.

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
  interno de movimiento seguro. La etapa F ofrece JSON v1 para consultas
  read-only. ENG-02A/B agrega JSON v1 para `new`, `rename` y `delete` con
  paridad Bash/PowerShell; ENG-02C agrega `exec` stdout-clean para procesos
  foreground. Los tres contratos estan en el worktree activo y versionados en
  la rama aislada de validacion.
- El commit local `ad9630c` agrupa la migracion y recuperacion transaccional,
  el estado MCP compartido, el launcher rapido, permisos Codex compartidos,
  endurecimiento de runtime y adapters, pruebas, documentacion y la integracion
  externa de titulos de Hyper. `main` estaba limpio y un commit delante de
  `origin/main` antes de este handoff documental; no asumir que esta publicado,
  instalado o convertido en release.
- El worktree contiene cambios concurrentes de movimiento remoto y ENG-02A/B/C
  en entrypoints, modulos, pruebas y documentacion. Preservarlos y revisar el
  diff por archivo; no stagear, commitear, publicar ni resolver un lado completo
  sin autorizacion nueva.
- El aislamiento de CI no stageo ese worktree: reconstruyo ENG-02A sobre
  `ad9630c` y extendio `validation/eng-02b` con ENG-02B/C. El PR no se debe
  mezclar, cerrar o borrar como si fuera una entrega de `main`; `fc3361f` es el
  commit versionado de C y la integracion activa sigue sin commit en `main`.

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
  `migrationPreservePaths`, `migrationActivatePaths` y credenciales
  compartidas; no hay una politica privada por perfil.
- Para Codex ya se demostraron y declararon como estado normal compartido
  `AGENTS.md`, `AGENTS.override.md`, `installation_id` y `log/`. Las familias SQLite observadas en
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
- `normalState.migrationActivatePaths` es una allowlist opcional y exacta de
  estado shared/session que se activa durante migracion. Si existe, el resto
  del estado normal declarado se preserva completo bajo `profile-state/`, sin
  merge por archivo. Si falta, los adapters conservan el comportamiento
  anterior.
- Codex clasifica `.sandbox_migration`, `cache/`, `models_cache.json` y
  `version.json` como runtime reconstruible. Su migracion activa solo
  configuracion/MCP, instrucciones, skills, agents, prompts, plugins, rules y
  hooks; sesiones, history, snapshots, logs, identidad de instalacion, locks y
  SQLite quedan inactivos completos bajo `profile-state/`.
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
| Ruta shared/session fuera de `migrationActivatePaths` cuando el campo existe | Se preserva completa bajo `profile-state/`; no se recorre ni activa durante migracion |
| Credencial declarada pero ausente | El plan actual crea un placeholder vacio bajo `auth/` |
| Credencial declarada como symlink o hardlink | Se rechaza antes del apply |
| Ruta que coincide con credencial y estado normal | Se reporta `overlap` y se rechaza |

Consecuencia: agregar todos los nombres observados al adapter no basta. La
frontera MCP requirio un contrato separado de credenciales compartidas, un root
propiedad del motor, locks comunes, exclusion de transporte y preservacion
legacy inactiva. Nunca debe simplificarse a `sharedPaths` ni a una copia de
`.credentials.json` por perfil.

## Evidencia real protegida de `codex/luis`

- El launcher legacy es `codex-example`; el spec correcto del store es
  `codex/example`. No usar `codex/codex-example`.
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
- ENG-02A paso localmente 8/8 mutaciones JSON, 11/11 contrato JSON previo y
  12/12 seguridad de perfiles. La copia exacta paso 31/31 pruebas dirigidas,
  sintaxis Bash, parseo del schema, documentacion y `git diff --check`.
- CI `32741318583` ejecuto el tip aislado en Linux, macOS y Windows. Las siete
  pruebas `JsonMutations.Tests.ps1` pasaron con Windows PowerShell 5.1/Pester
  3.4.0; PSScriptAnalyzer, install smoke Windows, shellcheck, install smoke
  Ubuntu y la suite Bats Ubuntu tambien pasaron.
- La suite Pester total termino 419 passed / 18 failed / 0 unexecuted. La
  primera divergencia fue posterior a las siete pruebas ENG-02A y pertenece a
  `Migration.Tests.ps1`; por ello el workflow omitio la cobertura PowerShell.
- La cobertura Bash con baseline ampliado `origin/main` obtuvo 313/332
  (94,28 %). Sus 19 misses pertenecen al commit base `ad9630c`; ninguno cae en
  los rangos productivos exactos de ENG-02A, pero no sustituye una ejecucion del
  gate con baseline `ad9630c`.
- La harness temporal `b7790c9` fijo ambos gates a `ad9630c` y ejecuto cobertura
  PowerShell aun despues de fallar la suite base. CI `32743230689` cerro Bash en
  100 % (4/4), pero revelo solo 33,33 % (1/3) en PowerShell porque el helper de
  error no tenia una llamada in-process.
- El test-only `879d461` agrego esa llamada a `ModuleFunctions.Tests.ps1`, sin
  cambiar producto. CI `32744574564` aprobo la prueba, Bash changed-line 100 %
  (4/4), PowerShell changed-line 100 % (3/3) y `MultiCli.Json.psm1` 100 %
  (36/36). El paso PowerShell permanece rojo por 17 tests base fallidos y 502
  comandos inesperadamente no cubiertos fuera del modulo JSON.
- La suite Pester completa del tip termino 420 passed / 18 failed / 0 skipped,
  pending o inconclusive. El incremento de un passed es la prueba de cobertura;
  los 18 fallos preexistentes no fueron corregidos.
- macOS fallo fuera del delta en `lib/migration.sh:195`, introducida por
  `ad9630c`, con un error de parseo Bash 3.2. Se registra como incidente
  separado. Ese run dejo ENG-02A `validating`; la decision posterior permitio
  continuar ENG-02B manteniendo el incidente fuera del delta.
- ENG-02B paso localmente las 35 pruebas focales de mutaciones, contrato y
  containment; las aserciones finales agregadas pasaron 2/2. El CI
  `32748238240` aprobo las cuatro pruebas Windows de delete, PSScriptAnalyzer,
  shellcheck, install smoke Windows/Ubuntu, Bats Ubuntu y cobertura Bash
  changed-line 100 % (9/9). El gate de modulos PowerShell permanecio 100 %
  (3/3) para el modulo JSON tocado por ENG-02A; ENG-02B cambia el entrypoint y
  se verifico mediante procesos hijos, no por ese gate de modulos.
- La suite Pester del mismo tip termino 424 passed / 18 failed; ninguno de los
  cuatro tests ENG-02B fallo. macOS repitio el parseo Bash 3.2 de
  `lib/migration.sh:195`. Ambos resultados preexistentes siguen como
  `separate_fix` y no se mezclaron con esta fraccion.
- ENG-02C quedo versionado como `fc3361f` en `validation/eng-02b` y ENG-02B/C
  fue portado por hunks al `main` concurrente. El delta conserva el owner de
  launch, exige foreground `accountOverlay/fileOverlay`, reemplaza el wrapper
  por el hijo en Bash y hereda stdio/exit code en PowerShell.
- La validacion local de integracion paso las 92 pruebas Bats focalizadas con
  `NINI_AGENTS_HYPER_TITLE_LOCK` retirado del ambiente, ademas de sintaxis Bash,
  JSON Schema, 17 adapters, documentacion, metadata de release y
  `git diff --check`. El comando instalado reporto version `1.0.0` y mostro el
  contrato `exec` porque su wrapper ya apunta al checkout integrado.
- PowerShell/Pester, Windows, macOS, perfiles y credenciales reales no se
  ejecutaron en este cierre. No hubo merge, push, tag, release, build de
  paquetes ni reescritura del instalador.

## Trabajo restante

El lote real de perfiles Codex esta cerrado: los quince perfiles son schema v2,
usan wrappers Nini y tienen smokes observados en Linux. No repetir migraciones
ni limpiar recuperaciones inactivas sin un alcance nuevo.

El end-to-end global todavia no esta cerrado. Falta, con gates separados:

1. **Evaluar los cinco conflictos omitidos de Luis:** el launch uso las
   versiones existentes del root compartido porque no se autorizo
   `--prefer-profile`. No modificar esos residuos sin investigacion read-only,
   alcance de recuperacion y aprobacion explicita.
2. **Cerrar el consumidor Nini Hub:** discovery, lifecycle, launch, Codex
   app-server, Usage, Heartbeat y Device Auth ya consumen los contratos Nini.
   Falta `QA-01` para equivalencia desktop y `CUT-01` para publicacion/cutover.
   El merge o publicacion de ENG-02 en `origin/main` sigue dentro del corte, no
   de esta integracion local.

## Siguiente handoff: cierre de Nini Hub

La direccion aprobada es cerrar Nini Hub como consumidor unico de Nini Agents
sin ocultar los gates de plataforma y publicacion.

Estado de partida:

- Nini Hub existe como repositorio independiente y lleva `12/14` puntos
  cerrados. Discovery y lifecycle consumen JSON v1; launch y app-server usan el
  contrato Nini correcto para perfiles administrados.
- JSON v1 cubre consultas y `new`/`rename`/`delete`. Las mutaciones reportan
  `applied`, `not_applied` o `partially_applied`; delete exige
  `--confirm <tool>/<profile>` exacto. `exec` conserva stdin/stdout/stderr sin
  preambulos humanos.
- La deteccion y apertura de terminales, incluido Hyper, los titulos
  `perfil · proyecto` y el enfoque best effort de ventanas pertenecen a la GUI
  y deben preservarse; solamente cambia la invocacion y ownership del motor.
- `main` local del motor sigue en `ad9630c` con ENG-02 integrado solo como
  cambios de worktree. El linaje versionado llega a `fc3361f` en la rama
  temporal. El wrapper instalado apunta al checkout local, pero `origin/main`
  y cualquier release publicado aun no contienen el delta.

Secuencia obligatoria para el siguiente modelo:

1. Leer `AGENTS.md`, este checkpoint y la bitacora Nini Hub; no reconstruir la
   migracion desde Git.
2. Caracterizar y aprobar `QA-01`: pruebas focalizadas, guarda arquitectonica,
   smoke Linux sintetico y matriz explicita de lo no verificado en Windows.
3. Caracterizar `CUT-01` por separado: integracion/publicacion del motor,
   instalacion final, rollback y deprecacion del consumidor legacy.

Criterio de cierre de MultiCLI AI:

- usa directamente el ejecutable canonico y un contrato soportado;
- no lee secretos ni manipula credenciales o ownership por su cuenta;
- no parsea salida humana para decisiones de producto;
- crea, lista, lanza y administra perfiles mediante el motor segun la matriz
  aprobada;
- conserva Hyper, titulos, navegador y enfoque de ventanas;
- tiene pruebas sinteticas, smoke controlado y rollback comprobado;
- documenta plataformas no ejecutadas y no declara cerrada la Etapa H global
  mientras Codexporter siga pendiente.

El handoff documental inicial fue ampliado para ENG-02A/B/C y la integracion
local requerida por Nini Hub. No hubo perfiles reales, merge, release,
publicacion de `main`, reescritura del instalador ni retiro del shim.

PowerShell, Windows y macOS no fueron verificados por los G9 reales de perfiles.

## Regla de cierre y continuidad

Cuando un tramo aprobado cambie codigo, evidencia, bloqueos o gates:

1. anexar el detalle completo a la bitacora canonica;
2. actualizar aqui solo el estado operativo, invariantes y siguiente accion;
3. registrar validaciones no ejecutadas y cualquier efecto real sobre datos;
4. mantener este archivo compacto y libre de secretos, rutas privadas, hashes,
   IDs de cuenta y contenido de credenciales.

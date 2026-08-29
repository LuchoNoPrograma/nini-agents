# Nini Agents: plan maestro y bitacora end-to-end

- Estado del documento: activo
- Fecha de inicio: 2026-08-22
- Base upstream fijada: Multi-CLI
  `6efb0d204d4e690c2e0f5e9c2ee900a3cead6afa`
- Branch de trabajo del registro historico inicial: `nini-agents-cli`

## Proposito

Este documento coordina el recorrido completo desde el fork de Multi-CLI hasta el
motor definitivo de Nini Agents y la migracion posterior y simultanea de
MultiCLI AI y Codexporter. Sirve como mapa, registro de decisiones y punto de
continuidad para otros agentes.

No sustituye [AGENTS.md](../../AGENTS.md), no concede autorizacion para ejecutar
una etapa y no convierte una direccion aprobada en funcionalidad implementada.
Cada cambio mantiene su propio alcance, aprobacion, pruebas y cierre.

## Como continuar el trabajo

Antes de actuar, todo agente debe:

1. Leer [AGENTS.md](../../AGENTS.md), el
   [checkpoint operativo](nini-agents-resume.md) y la skill canonica aplicable
   bajo `.agents/skills/`. Consultar este documento completo solo cuando haga
   falta reconstruir historia o evidencia, resolver una contradiccion o
   delimitar una etapa nueva.
2. Revisar `git status`, branch, remotes, base comun y cambios concurrentes sin
   modificar referencias ni archivos.
3. Separar siempre estado existente, direccion aprobada y trabajo pendiente.
4. Registrar aqui el alcance aprobado, decisiones estables, validaciones y
   resultado de cada tramo terminado; actualizar tambien el checkpoint cuando
   cambien el estado, los bloqueos o el siguiente gate.
5. Detenerse y pedir una aprobacion nueva si cambia una frontera, aparecen datos
   reales o la accion requiere instalar, publicar, migrar, borrar o conectarse a
   otro equipo.

No registrar secretos, contenido de `auth.json`, identificadores privados,
rutas privadas completas ni evidencia sin sanitizar.

## Estado inicial historico comprobado

Este bloque conserva el punto de partida observado al crear el plan; no describe
el checkout vigente. Al inicio del 2026-08-22:

- `multi-cli-base` y `nini-agents-cli` apuntan al upstream puro `6efb0d2`.
- `multi-cli-upstream/main` tambien apunta a `6efb0d2`.
- `main` y `legacy/main` apuntan a `7426e98`, correspondiente a la aplicacion
  Flutter existente.
- `legacy-gui` aun no existe.
- El checkout activo es `nini-agents-cli`.
- El motor heredado ya contiene launchers Bash y PowerShell, schema v2,
  adapters, runtime, migracion, transferencias sin credenciales y sus pruebas.
- El renombre Nini Agents, el movimiento seguro heredado de Codexporter, la CLI
  JSON estable y las migraciones consumidoras aun no estan implementados.
- Las cinco skills canonicas ya existen bajo `.agents/skills/` y se consumen
  desde el repositorio; no deben duplicarse como skills globales.

## Estado actual comprobado

Al corte documental del 2026-08-22:

- El checkout activo es `main`; el tip anterior al tramo local vigente es
  `293c48d`, alineado con `origin/main`. El worktree contiene el G2 aprobado de
  compatibilidad de lanzamiento whole-root para perfiles legacy y el
  endurecimiento transaccional del migrador legacy a schema v2, todavia sin
  commit ni push.
- `main` contiene el motor Nini Agents renombrado y conserva los shims de
  compatibilidad. Las Etapas A, B, C y D estan cerradas con evidencia local y
  CI remoto efimero. El tramo aprobado de la Etapa E contiene el protocolo
  transaccional interno y sus pruebas, pero no expone todavia comando publico
  ni transporte SSH. La Etapa F ya entrega JSON v1 para consultas read-only;
  movimiento publico, ejecucion machine-safe y migraciones consumidoras siguen
  pendientes.
- `multi-cli-base` y `origin/multi-cli-base` conservan el upstream puro
  `6efb0d2`.
- `legacy-gui` y `origin/legacy-gui` conservan el snapshot Flutter `7426e98`.
- `origin` apunta al fork publico `LuchoNoPrograma/nini-agents` y
  `multi-cli-upstream` apunta a `Spielewoy/multi-cli`.
- El nucleo interno del movimiento seguro inspirado por el contrato de
  Codexporter esta implementado en Bash y PowerShell. La integracion remota, la
  CLI JSON de mutaciones y las migraciones consumidoras siguen pendientes; no
  deben presentarse como funcionalidades implementadas.
- La direccion aprobada para perfiles es crear en schema v2, conservar el
  lanzamiento legacy y migrar los perfiles existentes de forma voluntaria y
  gradual. Un inventario read-only y sanitizado encontro 15 perfiles Codex,
  todos legacy, con `auth.json` raiz estructuralmente valido; no se registraron
  nombres, valores, hashes, IDs ni rutas privadas. Ninguno fue migrado.
- Las referencias locales y el trabajo registrado por este plan no contienen
  un tag ni una release de Nini Agents; el estado remoto debe verificarse otra
  vez antes de cualquier publicacion.

Este bloque es una fotografia de referencias, no una autorizacion. Debe
actualizarse cuando una etapa aprobada cambie el estado observable.

## Arquitectura objetivo

```text
Multi-CLI upstream 6efb0d2
           |
           v
      Nini Agents
           |
           v
    motor definitivo
      |-- perfiles y cuentas
      |-- aislamiento
      |-- sesiones
      |-- transferencia entre equipos
      |-- CLI JSON estable
      `-- compatibilidad temporal
           |
           v
 migracion coordinada posterior
      |-- MultiCLI AI
      `-- Codexporter
```

Topologia Git vigente y responsabilidades que debe conservar:

| Referencia | Responsabilidad vigente |
|---|---|
| `main` | Desarrollo y entrega del motor Nini Agents |
| `legacy-gui` | Snapshot estable de la aplicacion Flutter MultiCLI AI |
| `multi-cli-base` | Upstream puro fijado en `6efb0d2` |
| `multi-cli-upstream/main` | Seguimiento del upstream, sin mezclar cambios propios |
| `legacy/main` | Fuente local de la historia Flutter mientras dure la migracion |

La topologia ya fue establecida durante la Etapa A. Crear o mover branches,
reescribir referencias o publicar cambios adicionales requiere un alcance Git
separado y aprobado.

## Invariantes no negociables

### Credenciales y recuperabilidad

- Nunca ejecutar logout, revocacion ni regeneracion de credenciales para copiar
  o mover un perfil.
- Nunca consultar ni modificar OpenAI como parte de la transferencia.
- Nunca leer, imprimir o registrar valores secretos.
- No sobreescribir una credencial destino diferente.
- Verificar igualdad byte a byte o mediante hashes criptograficos antes y
  despues del movimiento, sin exponer el contenido.
- Mantener una copia inactiva recuperable y un rollback verificable.
- Rechazar procesos activos, traversal, enlaces simbolicos, hardlinks, rutas
  fuera del root, archivos desconocidos y ownership ambiguo.
- Mantener `export`, `import`, templates y `continue` libres de credenciales.
- Tratar el movimiento con credenciales como un contrato separado y explicito.

### Compatibilidad

- Conservar Bash 3.2 o superior y Windows PowerShell 5.1 o superior.
- Mantener paridad observable entre ambas implementaciones cuando la capacidad
  sea multiplataforma.
- Mantener temporalmente el comando `multi-cli` como shim.
- Mantener `MULTICLI_HOME` y `~/MultiCliProfiles` durante esta evolucion para no
  mover cuentas existentes.
- No crear perfiles schema v1 nuevos; detectar legacy solo donde el contrato lo
  permita expresamente.
- Preservar `LICENSE` y la atribucion MIT del upstream.

### Desarrollo y pruebas

- Probar cambios mutables solo con homes y perfiles sinteticos bajo directorios
  temporales.
- No tocar `~/.codex`, el `MULTICLI_HOME` real, `~/MultiCliProfiles` ni
  instalaciones activas bajo `~/.local/share/nini-agents` o
  `~/.local/share/multi-cli`.
- No instalar el motor desde el checkout para probarlo.
- No conectarse a otros equipos durante las pruebas de construccion.
- No afirmar soporte real de Windows, macOS o una herramienta sin evidencia de
  esa ejecucion protegida.

## Definicion end-to-end de terminado

El programa completo termina unicamente cuando:

- `main` contiene un motor Nini Agents trazable a `6efb0d2` y `legacy-gui`
  conserva el snapshot Flutter acordado.
- `nini-agents` es el ejecutable principal y `multi-cli` funciona como shim
  temporal con compatibilidad documentada.
- Perfiles, aislamiento, sesiones, runtime y credenciales conservan sus
  contratos en Bash y PowerShell.
- El movimiento entre equipos soporta formatos legacy y schema v2, demuestra
  staging, integridad, bloqueo de procesos, activacion controlada, backup y
  rollback sin logout ni revocacion.
- La CLI JSON tiene contrato versionado, salidas deterministas y proteccion
  contra filtrado de secretos.
- Las personalizaciones locales aprobadas estan portadas y caracterizadas por
  pruebas, no copiadas por similitud de archivos.
- El motor pasa su auditoria y sus gates antes de que cambie cualquier
  consumidor.
- MultiCLI AI y Codexporter migran de manera coordinada sobre el contrato
  congelado del motor, con rollback y sin ownership doble de credenciales.
- La compatibilidad legacy solo se retira mediante un plan posterior aprobado,
  medido y reversible.
- Release, instalacion y publicacion se ejecutan solo bajo autorizaciones
  separadas y quedan verificadas en las plataformas realmente probadas.

## Recorrido de implementacion

Las etapas son dependencias, no autorizaciones automaticas. Una etapa puede
dividirse en varios cambios pequenos y revisables.

### Etapa A: preservar historia y establecer la topologia Git

Objetivo: separar de forma recuperable el motor y la aplicacion Flutter antes de
renombrar o portar comportamiento.

Trabajo previsto:

- Verificar commits, remotes, bases comunes y working trees.
- Crear `legacy-gui` desde el commit Flutter acordado.
- Convertir `main` en la branch de desarrollo del motor basada en
  `multi-cli-base`.
- Conservar `multi-cli-base` como upstream puro en `6efb0d2`.
- Mantener trazabilidad de cualquier port posterior mediante historia y pruebas.

Criterios de salida:

- Cada branch resuelve al commit esperado.
- La historia Flutter sigue accesible sin copiar archivos dentro del motor.
- No se ha hecho push, rebase, reset, tag ni publicacion no autorizada.
- El worktree no contiene cambios ajenos incorporados accidentalmente.

Skill principal: `nini-agents-upstream-integration`.

### Etapa B: identidad Nini Agents y compatibilidad temporal

Objetivo: establecer la identidad del fork sin mover perfiles ni romper
consumidores existentes.

Trabajo previsto:

- Renombrar producto, mensajes y ejecutable principal a `nini-agents`.
- Mantener `multi-cli` y su equivalente PowerShell como shim temporal.
- Conservar `MULTICLI_HOME`, `~/MultiCliProfiles`, flags y comandos legacy
  documentados.
- Actualizar instaladores, packaging y documentacion solo dentro del alcance
  aprobado para este renombre.
- Preservar licencia y atribucion upstream.

Criterios de salida:

- Ambos nombres resuelven al mismo contrato durante la ventana de compatibilidad.
- No se migra ni renombra almacenamiento local.
- Version, ayuda, completion, instaladores y release no se contradicen.
- Las pruebas de layout y compatibilidad cubren Bash y PowerShell.

Skills principales: `nini-agents-upstream-integration` y
`nini-agents-change-integral`.

### Etapa C: auditar y portar personalizaciones propias del motor

Objetivo: recuperar comportamientos propios necesarios que pertenezcan al motor,
sin mezclar la aplicacion Flutter ni portar commits a ciegas.

Personalizaciones candidatas cuya procedencia y owner deben verificarse antes
de portarlas:

- Descubrimiento de Codex en `~/.local/bin/codex`.
- Manejo de `rules/` conforme al contrato actual de perfiles y runtime.

Hallazgos de procedencia ya comprobados, aun no implementados:

- El upstream historico `abffcba` buscaba Codex en
  `~/.local/bin/codex`, pero el adapter actual de `6efb0d2` ya no declara esa
  ruta. Si se restaura, pertenece a los candidatos declarativos del adapter y
  no a una excepcion hardcodeada en el launcher.
- El adapter de Claude ya declara `rules/`. Para Codex, `~/.codex/rules/`
  pertenece a su [configuracion de usuario actual](https://learn.chatgpt.com/docs/agent-configuration/rules),
  pero las reglas siguen documentadas como experimentales. El flag
  `--ignore-rules` de MultiCLI AI es un comportamiento de heartbeat distinto y
  no demuestra por si solo que el directorio deba compartirse. Cualquier cambio
  exige alinear schema, adapters, runtime, guia y pruebas en ambas
  implementaciones.

La integracion con Hyper no pertenece a esta etapa. Es comportamiento de
MultiCLI AI: el commit `6eac14f` de `legacy-gui` detecta la terminal, abre Hyper,
transmite el comando y argumentos, establece el titulo de la pestana y enfoca la
ventana como best effort. El motor base `6efb0d2` y Nini Agents no contienen una
integracion especifica con Hyper.

Metodo:

- Comparar historia, contrato y pruebas de cada cambio con `6efb0d2`.
- Identificar el modulo propietario en Bash y PowerShell.
- Portar comportamiento minimo y agregar caracterizacion focalizada.
- Declarar como no probada toda plataforma que no pueda ejecutarse.

Criterios de salida:

- Cada personalizacion tiene origen trazable, owner claro y prueba que falla sin
  el cambio.
- Solo se porta al motor aquello que forme parte de descubrimiento, perfiles,
  adapters, runtime, aislamiento o lanzamiento independiente de una UI.
- No se ha importado UI Flutter ni dependencia de Codexporter.
- El runtime no debilita containment, overlays ni validacion de adapters.

### Etapa D: auditar y cerrar brechas del nucleo existente

Objetivo: caracterizar el nucleo heredado de `6efb0d2`, corregir solo las brechas
demostradas y congelar los contratos internos que usaran la transferencia y los
consumidores futuros. Esta etapa no reconstruye desde cero perfiles,
aislamiento, sesiones, adapters ni schema v2 que ya existen.

Fronteras:

- Parsing y dispatch en `nini-agents` y su launcher PowerShell.
- Runtime, migracion, transferencia, credenciales y OS-user isolation en los
  modulos existentes bajo `lib/`.
- Contratos declarativos en `schema/adapter.schema.json` y
  `ai-tools/*/adapter.json`.
- Schema v2 con `.profile.json`, `auth/`, `.runtime/` reconstruible y estado
  normal declarado por el adapter.

Criterios de salida:

- Cada capacidad se clasifica como existente y caracterizada, brecha corregida
  o trabajo pendiente; no se presenta codigo heredado como implementacion nueva.
- Crear, lanzar, clonar, renombrar, borrar, autenticar, continuar sesiones,
  exportar, importar y migrar conservan sus invariantes documentadas.
- Las categorias credential files, shared paths y session paths no se solapan.
- Un fallo de enlace de runtime aborta; nunca degrada a una copia divergente.
- Bash y PowerShell exponen la misma semantica donde corresponde.

Skills principales: `nini-agents-change-integral`,
`nini-agents-profile-security` y `nini-agents-adapter-runtime`.

### Etapa E: incorporar el movimiento seguro de Codexporter

Objetivo: construir un protocolo transaccional independiente del transporte
para mover un perfil entre equipos sin revocar, regenerar ni duplicar su
credencial activa.

Codexporter se usa como contrato legacy a verificar, no como codigo ya
integrado. Se preservan estas propiedades:

- copia integra del home permitido mediante una frontera de transporte; el
  comportamiento legacy usa SSH, pero el protocolo central no depende de SSH;
- validacion estructural del JSON de autenticacion;
- staging previo;
- comparacion de origen y staging;
- bloqueo si Codex esta activo;
- desactivacion atomica del origen;
- activacion posterior del destino;
- backup inactivo;
- restauracion del origen si falla la activacion.

Formatos que debe detectar el motor:

```text
Legacy
<perfil>/auth.json

Schema v2
<perfil>/auth/auth.json
<perfil>/.profile.json
<perfil>/.runtime/auth.json
```

`<perfil>/.runtime/auth.json` es runtime reconstruible. Su tratamiento debe
derivarse del adapter y nunca convertirlo en una segunda fuente de credenciales.

La implementacion se divide en fronteras separadas:

1. Protocolo local transaccional: estados, staging, integridad, ownership,
   activacion atomica, backup y rollback sobre roots sinteticos.
2. Transporte: interfaz que entrega una copia candidata sin decidir ownership
   ni activacion. Primero se prueba con transporte sintetico.
3. Integracion remota: SSH y equipos reales quedan para un alcance y una
   autorizacion posteriores; no forman parte de las pruebas de construccion.

Antes de congelar la maquina de estados se inventarian con la Etapa F los
resultados, errores y transiciones que debera representar la salida JSON. La
implementacion completa de la interfaz JSON permanece en la Etapa F.

Secuencia contractual:

1. Resolver origen, destino, formato, adapter y propietario activo.
2. Confirmar que no hay procesos relevantes activos en ninguno de los extremos.
3. Validar containment, tipos, permisos, JSON y ausencia de contenido no
   permitido sin mostrar secretos.
4. Copiar a un staging exclusivo en destino.
5. Comparar estructura, tamanos y hashes entre origen y staging.
6. Preparar rollback antes de cambiar ownership activo.
7. Desactivar el origen mediante movimiento atomico.
8. Activar el staging en destino mediante movimiento atomico.
9. Repetir validaciones y comparacion de credenciales.
10. Conservar la copia de origen como backup inactivo.
11. Si falla la activacion, desactivar cualquier destino parcial y restaurar el
    origen; si no puede demostrarse un estado seguro, fallar cerrado y conservar
    todos los artefactos recuperables.

Invariantes adicionales:

- Existe un propietario activo antes y despues de una operacion exitosa; nunca
  existen dos copias activas. Una ventana transitoria sin propietario activo
  solo puede ocurrir entre desactivacion y activacion bajo rollback preparado.
- Una credencial destino existente y diferente bloquea la operacion.
- La comparacion de credenciales usa bytes o hash, no equivalencia JSON.
- Ningun fallo borra automaticamente el backup inactivo.
- Los errores y el JSON de salida no contienen secretos ni identificadores
  privados.
- La primera bateria de pruebas usa solo filesystem y perfiles sinteticos bajo
  `/tmp`; SSH real y otros equipos quedan fuera hasta una autorizacion protegida.

Criterios de salida:

- Exito, rechazos de seguridad y fallos inyectados en cada limite demuestran el
  estado final y el rollback.
- Legacy y schema v2 estan caracterizados por separado.
- No hay llamadas a logout, revoke, auth clear ni APIs de OpenAI.
- El contrato de movimiento no contamina `export`, `import`, templates o
  `continue`.

Skill principal: `nini-agents-profile-security`, coordinada por
`nini-agents-change-integral`.

### Etapa F: implementar y congelar la CLI JSON estable

Objetivo: ofrecer una interfaz consumible por MultiCLI AI, Codexporter y futuras
automatizaciones sin depender de texto humano.

El inventario contractual comienza antes de congelar la transferencia de la
Etapa E, para evitar adaptar despues una interfaz disenada solo para texto
humano. Contrato minimo a definir antes de implementar:

- activacion explicita y compatible, por ejemplo `--json`;
- version de schema en cada respuesta;
- envelope estable para exito y error;
- codigos de salida documentados y consistentes;
- stdout reservado al JSON y diagnosticos controlados en stderr;
- orden y tipos deterministas donde formen parte del contrato;
- identificadores publicos necesarios, sin tokens, secretos ni rutas privadas;
- errores estructurados para validacion, conflicto, proceso activo, transporte,
  activacion y rollback;
- soporte equivalente en Bash y PowerShell.

Antes de congelarlo se debe inventariar cada comando consumidor y decidir que
campos son estables, opcionales o internos. El texto humano actual permanece
compatible durante la migracion.

Criterios de salida:

- Fixtures contractuales validan exito, error y redaccion de secretos.
- MultiCLI AI y Codexporter pueden integrarse sin parsear texto libre.
- Existe una politica explicita de versionado y compatibilidad del schema.

### Etapa G: auditoria y congelamiento del motor

Objetivo: demostrar que el motor es una base segura antes de migrar consumidores.

La auditoria debe revisar:

- trazabilidad desde `6efb0d2` y separacion del legacy Flutter;
- paridad Bash/PowerShell;
- path safety, enlaces, hardlinks, permisos y ownership;
- manejo de procesos y concurrencia;
- credenciales, staging, activacion y rollback;
- schema v2, adapters, runtime y compatibilidad legacy;
- contrato JSON y ausencia de filtraciones;
- instaladores y release en modo de comprobacion, sin instalar ni publicar.

Gate minimo previsto:

```text
bash tests/run-bats.sh <suites focalizadas>
bash tests/coverage/run-bash-coverage.sh
bash scripts/validate-adapters.sh
python3 scripts/validate-docs.py
bash release/build.sh --check
```

En Windows, cuando exista el entorno autorizado:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -CI
powershell -NoProfile -ExecutionPolicy Bypass -File tests/coverage/Run-PowerShellCoverage.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Validate-Adapters.ps1
```

Los tests focalizados se eligen segun los archivos cambiados. Un gate no
ejecutado se registra como no verificado, nunca como aprobado.

Criterios de salida:

- No quedan hallazgos criticos o altos abiertos en fronteras de cuenta.
- Los cambios productivos cumplen el gate de cobertura aplicable.
- El contrato del motor y de JSON queda congelado para consumidores.
- Existe un plan de rollback probado antes de iniciar la migracion coordinada.

### Etapa H: migracion coordinada de MultiCLI AI y Codexporter

Objetivo: convertir ambos proyectos en consumidores del motor definitivo sin
mantener dos implementaciones propietarias de perfiles o credenciales.

Precondiciones:

- Etapa G cerrada con evidencia suficiente.
- Contrato CLI JSON congelado y versionado.
- Matriz de comandos consumidores inventariada.
- Backups y rollback definidos para ambos proyectos.
- Alcance y aprobacion separados para modificar cada repositorio.

Trabajo previsto:

- Migrar MultiCLI AI desde su logica legacy a la CLI JSON de Nini Agents.
- Preservar en MultiCLI AI su integracion de terminales, incluida Hyper, sus
  titulos `perfil · proyecto` y el enfoque best effort de ventanas; esta logica
  permanece del lado consumidor y cambia solamente la invocacion del motor.
- Migrar Codexporter desde motor independiente a consumidor del movimiento
  seguro integrado.
- Coordinar el corte para evitar una ventana con implementaciones incompatibles.
- Conservar temporalmente adaptadores o shims solo donde exista un consumidor
  comprobado.
- Verificar que ningun consumidor ejecute logout, regenere credenciales o
  manipule directamente ownership fuera del motor.

Criterios de salida:

- Ambos consumidores usan el mismo motor y schema soportado.
- La UI no parsea salida humana ni accede directamente a secretos.
- La UI conserva sus comportamientos propios de terminal sin introducir
  dependencias de Hyper en Nini Agents.
- Codexporter deja de ser owner del algoritmo de transferencia.
- Rollback de cada consumidor restaura el ultimo contrato compatible sin tocar
  credenciales reales durante pruebas sinteticas.
- La migracion no se presenta como completa hasta verificar ambos consumidores.

### Etapa I: retiros y entrega bajo autorizaciones independientes

Objetivo: retirar deuda temporal solo despues de medir adopcion y confirmar que
no quedan consumidores legacy. Esta etapa agrupa trabajo futuro por
dependencias, pero no puede aprobarse ni ejecutarse como una sola operacion.

Subtramos que requieren alcance, evidencia y aprobacion propios:

- I1, deprecacion: medir consumidores y decidir el retiro del shim `multi-cli`.
- I2, almacenamiento: decidir cualquier cambio de `MULTICLI_HOME`,
  `~/MultiCliProfiles` o formatos legacy.
- I3, instalacion: probar primero destinos temporales y autorizar por separado
  cualquier cambio sobre una copia activa.
- I4, datos reales: inspeccionar, migrar, limpiar o borrar perfiles reales solo
  con objetivos y recuperacion explicitos.
- I5, operacion remota: conectarse a equipos reales o ejecutar SSH real.
- I6, publicacion: crear tags, releases, artefactos publicados o distribucion.

La aprobacion de un subtramo no autoriza ninguno de los siguientes.

Criterios de salida:

- Cada retiro tiene inventario de consumidores, advertencia, migracion y
  rollback.
- La release se construye desde una historia limpia y atribuida.
- Las plataformas se declaran unicamente con evidencia real protegida.
- Los backups inactivos no se eliminan por una politica implicita.

## Gates de autorizacion

| Gate | Accion que habilita | Nunca queda implicito por |
|---|---|---|
| G0 | Editar documentacion y esta bitacora | Aprobar la direccion del producto |
| G1 | Crear o mover branches locales | Haber documentado la topologia objetivo |
| G2 | Cambiar motor, launchers, adapters o pruebas | Aprobar una etapa funcional |
| G3 | Leer codigo externo de consumidores para portar contratos | Aprobar solo cambios del motor |
| G4 | Modificar MultiCLI AI o Codexporter | Congelar el motor o leer sus repositorios |
| G5 | Usar perfiles o credenciales reales | Pasar pruebas sinteticas |
| G6 | Conectarse a otros equipos o ejecutar SSH real | Implementar transporte sintetico |
| G7 | Instalar o desinstalar contra un destino temporal acordado | Pasar `release/build.sh --check` |
| G8 | Modificar una instalacion activa | Probar un destino temporal |
| G9 | Migrar, limpiar o borrar datos y perfiles reales | Inspeccionarlos o pasar fixtures sinteticos |
| G10 | Retirar shims, variables, rutas o formatos legacy | Completar la migracion de un consumidor |
| G11 | Crear o empujar un tag | Construir artefactos o completar la auditoria |
| G12 | Publicar una release, artefactos o distribucion | Crear un tag o aprobar un build local |

## Matriz de ownership y skills

| Trabajo | Owner tecnico | Skill canonica principal |
|---|---|---|
| Historia, branches, renombre y release | Integracion del fork | `nini-agents-upstream-integration` |
| Flujo que cruza launchers, modulos y pruebas | Contrato multiplataforma | `nini-agents-change-integral` |
| Perfiles, credenciales y movimiento | Seguridad de cuenta | `nini-agents-profile-security` |
| Schema, adapters, runtime y mecanismos | Runtime declarativo | `nini-agents-adapter-runtime` |
| Fallo de causa desconocida | Diagnostico read-only | `nini-agents-diagnostico-incidentes` |

`nini-agents-change-integral` coordina cambios amplios, pero no sustituye las
reglas especializadas de seguridad, adapters o upstream.

## Decisiones abiertas

Estas preguntas se resuelven en el alcance de la etapa correspondiente, no por
suposicion:

- Nombre y forma exacta del comando de movimiento entre equipos.
- Envelope, version inicial y politica de evolucion de la CLI JSON.
- Mecanismo de transporte remoto y sus dependencias por plataforma.
- Representacion persistente del propietario activo sin crear una segunda fuente
  de verdad.
- Politica y ubicacion del backup inactivo en ambos extremos.
- Duracion y telemetria local de la ventana de compatibilidad `multi-cli`.
- Momento y estrategia para cambiar `MULTICLI_HOME` o el directorio de perfiles,
  si alguna vez se aprueba.
- Secuencia exacta de corte coordinado de MultiCLI AI y Codexporter.

## Plantilla de entrada de bitacora

Copiar esta seccion para cada cambio aprobado:

```text
Fecha y agente:
Etapa:
Estado: propuesto | aprobado | en curso | bloqueado | terminado
Objetivo:
Alcance aprobado:
Branch y commit inicial:
Archivos y contratos:
Efecto sobre credenciales o datos:
Compatibilidad:
Exclusiones:
Decisiones tomadas:
Cambios realizados:
Validaciones ejecutadas:
Plataformas no verificadas:
Resultado y evidencia sanitizada:
Rollback o recuperacion:
Pendientes y siguiente gate:
```

## Bitacora

### 2026-08-22 — creacion del plan maestro

- Estado: terminado dentro de G0.
- Objetivo: conservar el contexto end-to-end antes de modificar branches o
  construir el motor.
- Base comprobada: `6efb0d2` para `multi-cli-base` y `nini-agents-cli`;
  `7426e98` para `main` y `legacy/main`.
- Cambio autorizado: este documento y su enlace desde `AGENTS.md`.
- Efecto sobre credenciales y datos: ninguno.
- Funcionalidad implementada: ninguna.
- Plataformas verificadas: ninguna; el cambio es exclusivamente documental.
- Siguiente gate: presentar el alcance detallado de la Etapa A y obtener G1
  antes de reorganizar branches.

### 2026-08-22 — fork publico y topologia Git

- Estado: terminado bajo G1 y autorizacion explicita de publicacion.
- Objetivo: crear el fork publico `LuchoNoPrograma/nini-agents`, preservar la
  atribucion MIT y establecer `main`, `legacy-gui` y `multi-cli-base`.
- Alcance aprobado: reorganizar referencias locales sin rebase ni reset, crear
  el commit documental inicial, crear el fork formal de GitHub y publicar las
  tres branches.
- Preflight: autenticacion GitHub confirmada; nombres remotos libres; auditoria
  de rutas y firmas sin hallazgos propios. Las coincidencias observadas estan
  limitadas a fixtures de seguridad ya publicos en el upstream.
- Efecto sobre credenciales y datos: ninguno; no se leen perfiles ni secretos.
- Compatibilidad: no cambia el motor, sus comandos ni el almacenamiento local.
- Exclusiones: renombre funcional, instalacion, migracion, consumidores, tags y
  releases.
- Resultado: fork formal creado en
  `https://github.com/LuchoNoPrograma/nini-agents`; `main` contiene el commit
  documental inicial `e893730`, `multi-cli-base` conserva `6efb0d2` y
  `legacy-gui` conserva `7426e98`.
- Validacion: GitHub reporta parent `Spielewoy/multi-cli`, visibilidad publica y
  default branch `main`; la licencia conserva el blob upstream original, las
  cinco skills pasan `quick_validate.py` y la documentacion pasa
  `scripts/validate-docs.py`.
- Plataformas no verificadas: Windows y macOS; no hubo cambio funcional.
- Siguiente gate: delimitar la Etapa B y obtener G2 antes de renombrar producto,
  ejecutables, instaladores o contratos publicos.

### 2026-08-22 — identidad Nini Agents y compatibilidad temporal

- Estado: Etapa B terminada bajo G2; validacion local y CI remoto completos.
- Objetivo: convertir `nini-agents` y `nini-agents.ps1` en los entrypoints
  canonicos del motor sin mover perfiles ni romper consumidores existentes.
- Antes: `multi-cli` y `multi-cli.ps1` contenian las implementaciones completas
  del motor y el producto visible conservaba la identidad upstream.
- Despues: los entrypoints `nini-agents` contienen el motor y los entrypoints
  `multi-cli` son shims temporales sin logica de perfiles o credenciales. Los
  instaladores, aliases nuevos, completions, packaging, documentacion, pruebas
  y configuracion de GitHub usan la identidad Nini Agents y publican ambos
  comandos durante la ventana de compatibilidad.
- Contratos preservados: `MULTICLI_HOME`, `~/MultiCliProfiles`,
  `MULTICLI_PROFILE_ID`, targets de credenciales `multi-cli/...`, nombres de
  modulos `MultiCli.*` e identificadores y etiquetas de ownership de usuarios
  de sistema. `LICENSE` conserva exactamente el blob de `multi-cli-base` y
  `NOTICE` mantiene la atribucion upstream.
- Efecto sobre credenciales y datos: ninguno. No se leyeron perfiles reales, no
  se ejecuto logout, revocacion, migracion, instalacion ni uninstall, y todas
  las pruebas mutables usaron directorios temporales y datos sinteticos.
- Validacion local: sintaxis Bash; 23 pruebas focalizadas de branding,
  instalacion, aliases, packaging y seguridad de uninstall; 18 pruebas de
  transferencia con el alias de `python3` que espera el harness; validadores de
  adapters, documentacion y metadata de release. La suite Bash completa ejecuto
  218 pruebas: 213 pasaron o fueron omitidas y cinco quedaron bloqueadas por
  dependencias ausentes del host, cuatro por Secret Service/keyring y una por
  la ausencia del nombre `python`; esta ultima paso al proveer un alias temporal
  dentro de `/tmp`.
- Validacion remota: el workflow CI manual sobre `2498629` termino con sus
  11 jobs correctos, incluidos Bats en Ubuntu y macOS, Pester con 345 pruebas
  en Windows, cobertura Bash y PowerShell, ShellCheck, PSScriptAnalyzer,
  Actionlint, metadata de release y smoke tests de instalacion en los tres
  sistemas. La primera ejecucion detecto dos expectativas de branding
  incorrectas en las pruebas del uninstaller; se corrigieron sin cambiar el
  comportamiento del motor y la segunda ejecucion quedo verde.
- Plataformas no verificadas localmente: Windows PowerShell y macOS. Se
  verificaron en runners efimeros de GitHub Actions, no con herramientas o
  cuentas reales.
- Exclusiones confirmadas: movimiento entre equipos, CLI JSON, port de mejoras
  propias, migracion de MultiCLI AI y Codexporter, instalacion activa, tag y
  release.
- Recuperacion: antes de publicarse, todo el cambio es un diff no instalado
  sobre `main`; el snapshot Flutter permanece separado en `legacy-gui` y la
  base upstream pura permanece en `multi-cli-base`.
- Publicacion: `3c38eac` implementa el renombre y `2498629` alinea las dos
  expectativas Pester. Ambos commits estan en `origin/main`; no se creo tag ni
  release.
- Siguiente gate: delimitar la Etapa C y obtener una aprobacion nueva antes de
  auditar la procedencia de `~/.local/bin/codex` y `rules/` y portar solo los
  comportamientos que pertenezcan al motor.

### 2026-08-22 — correccion de ownership de la integracion Hyper

- Estado: terminado como correccion documental bajo G0.
- Hallazgo: Hyper no es una capacidad del motor Multi-CLI `6efb0d2` ni del
  motor Nini Agents. Su implementacion vive en el commit `6eac14f` del snapshot
  Flutter `legacy-gui` y forma parte de la experiencia de terminal de MultiCLI
  AI.
- Correccion: se retiro Hyper de las candidatas de la Etapa C y se traslado su
  preservacion a la migracion consumidora de MultiCLI AI en la Etapa H.
- Efecto sobre codigo, perfiles o credenciales: ninguno.
- Compatibilidad: no cambia comandos ni contratos; evita introducir una
  dependencia de una terminal concreta dentro del motor.
- Pendiente: auditar por procedencia y owner `~/.local/bin/codex` y `rules/`
  antes de proponer el alcance funcional de la Etapa C.

### 2026-08-22 — auditoria y precision del recorrido pendiente

- Estado: terminado como cambio documental bajo G0.
- Objetivo: evitar que futuros agentes reconstruyan capacidades heredadas,
  acoplen la transferencia a SSH o interpreten una aprobacion amplia como
  permiso para operar sobre instalaciones, equipos o datos reales.
- Estado verificado: `main` y `origin/main` en `6704860`;
  `multi-cli-base` y su branch remota en `6efb0d2`; `legacy-gui` y su branch
  remota en `7426e98`.
- Hallazgos de Etapa C: `~/.local/bin/codex` existia en el upstream historico
  `abffcba` y hoy falta en el adapter; `rules/` ya tiene contrato para Claude,
  mientras su posible uso en Codex requiere una decision separada de
  `--ignore-rules` y validacion integral del adapter.
- Cambios documentales: se separaron estado inicial y actual; la Etapa D paso a
  ser auditoria y cierre de brechas; la Etapa E separa protocolo local,
  transporte e integracion SSH; la Etapa F inventaria JSON antes de congelar la
  transferencia; la Etapa I y los gates sensibles quedaron divididos por
  autoridad.
- Efecto sobre codigo, perfiles, credenciales e instalaciones: ninguno.
- Compatibilidad: no cambia comandos, schema, adapters ni comportamiento de
  runtime.
- Plataformas verificadas: ninguna; no hubo cambio funcional.
- Siguiente gate: presentar el alcance funcional focalizado de la Etapa C y
  obtener G2 antes de modificar adapters, guias o pruebas.

### 2026-08-22 — Etapa C: descubrimiento local y reglas de Codex

- Estado: terminado bajo G2; validacion local y CI remoto completos.
- Objetivo: restaurar el descubrimiento de Codex instalado en
  `~/.local/bin/codex` y compartir el directorio de reglas de usuario como
  estado normal declarado por el adapter.
- Alcance funcional inicial: adapter de Codex, guia, matriz, pruebas
  contractuales Bash y PowerShell y esta bitacora. Quedaron excluidos
  launchers, modulos, schema, Hyper, Codexporter, CLI JSON, SSH, instalacion,
  perfiles reales y release. Una autorizacion posterior incluyo commit, push y
  CI para cerrar las Etapas C y D juntas.
- Antes: los candidatos macOS/Linux omitian `~/.local/bin/codex` y `rules/` no
  formaba parte de `normalState.sharedPaths`.
- Despues: macOS y Linux declaran el candidato local; `rules/` es estado normal
  compartido, nunca credencial ni estado de sesion. Un runtime schema v2 previo
  se reconstruye en el siguiente lanzamiento porque cambia su manifiesto
  esperado, sin modificar `auth/`.
- Prueba previa: las nuevas caracterizaciones Bash fallaron por ambos contratos
  ausentes. Dos pruebas existentes de `overlay_state` fallaron de manera
  transitoria en esa primera ejecucion y pasaron al repetir la suite completa.
- Validacion posterior: 37 pruebas Bash focalizadas correctas en
  `runtime_paths.bats`, `adapter_schema.bats` y `overlay_state.bats`; 17 adapters
  validados; documentacion validada; `git diff --check` correcto. El CI
  `32595087549` comprobo el contrato PowerShell, PSScriptAnalyzer, Bats en
  Ubuntu y macOS, cobertura y smoke tests de instalacion sobre runners
  efimeros.
- Efecto sobre credenciales y datos: ninguno. Todas las operaciones mutables
  usaron homes sinteticos temporales; no se leyeron perfiles reales ni se
  ejecuto logout, revocacion, migracion o instalacion.
- Plataformas no verificadas localmente: Windows PowerShell y macOS. Se
  verificaron en GitHub Actions, no con cuentas ni herramientas reales. No se
  probo un binario Codex real.
- Publicacion Git: la secuencia compartida con la Etapa D quedo en `3ebfef7`,
  `4c40ae3` y `dd03bad`, publicada en `origin/main`; no se creo tag ni release.
- Siguiente gate al cierre: la Etapa D quedo cerrada en el mismo run y el tramo
  interno aprobado de la Etapa E requirio su propio alcance G2.

### 2026-08-22 — Etapa D: cierre focalizado de brechas del nucleo

- Estado: terminado bajo G2; validacion local y CI remoto completos.
- Objetivo: corregir brechas demostradas en el contrato declarativo, la
  reconstruccion y auditoria del runtime y el ciclo de vida seguro de perfiles,
  manteniendo paridad Bash/PowerShell.
- Alcance funcional inicial: adapter de Command Code; validadores y runtime
  Bash y PowerShell; `doctor --deep`; borrado process-secret; ayuda/completion
  y compatibilidad `--shared`; documentacion y pruebas sinteticas. Se
  excluyeron Hyper, Codexporter, movimiento/SSH, CLI JSON, instalacion, perfiles
  reales y release. Una autorizacion posterior incluyo commit, push y CI para
  cerrar las Etapas C y D juntas.
- Antes: Command Code tomaba el home completo como shared root aunque su estado
  documentado vive bajo `.commandcode`; un runtime existente podia reutilizar
  enlaces hacia una raiz antigua; shared/session podian solaparse; `filePaths`
  podia declarar estado huerfano; el doctor PowerShell no comprobaba enlaces y
  el doctor Bash no interpretaba `runtimeSubdir`; Bash podia borrar un perfil
  aunque fallara la limpieza de su secreto; PowerShell omitía `auth` y trataba
  `--shared` schema v2 como el marcador legacy.
- Despues: Command Code declara `.commandcode` como shared root y mantiene
  `.commandcode` como subdirectorio de runtime; la vigencia del overlay exige
  que cada enlace apunte al origen actual; ambos validadores rechazan
  shared/session solapados y `filePaths` no clasificados; ambos doctors revisan
  faltantes y destinos incorrectos respetando `runtimeSubdir`; el borrado Bash
  falla cerrado y conserva el perfil si el keyring no se limpia; PowerShell
  incluye `auth` y conserva la semantica default de `--shared` para schema v2.
- Hermeticidad: los flujos process-secret de alto nivel usan un `secret-tool`
  sintetico dentro del scratch y la prueba de archivo grande invoca
  `python3`. Ninguna prueba consulta el keyring, perfiles o homes reales.
- Caracterizacion previa: fallaron como se esperaba la raiz de Command Code,
  separacion shared/session, pertenencia de `filePaths`, invalidacion por cambio
  de raiz, auditoria con `runtimeSubdir` y conservacion del perfil ante fallo de
  limpieza. Las cuatro dependencias previas de Secret Service y el uso de
  `python` quedaron eliminados del gate local mediante fixtures hermeticos.
- Validacion posterior: 42/42 pruebas Bash focalizadas; suite Bash completa de
  228 casos sin fallos (los casos exclusivos de otras plataformas quedaron
  omitidos por el propio harness); sintaxis Bash correcta; 17 adapters y toda
  la documentacion validados; `git diff --check` correcto.
- Validacion remota: el workflow `32595087549` termino verde con 11 jobs. Bats
  ejecuto 228 casos en Ubuntu y macOS; Pester ejecuto 359 casos sin fallos; la
  cobertura instrumentada ejecuto 240 casos y obtuvo 100% en
  `MultiCli.Transfer.psm1`, 99.52% total y cero misses inesperados. Tambien
  pasaron ShellCheck, PSScriptAnalyzer, Actionlint, metadata de release y smoke
  tests efimeros de instalacion en Linux, macOS y Windows.
- Efecto sobre credenciales y datos: no se leyeron secretos ni perfiles reales;
  no hubo logout, revocacion, migracion, instalacion, borrado real ni acceso a
  equipos remotos. El cambio de `delete` aumenta recuperabilidad al preservar
  el perfil cuando no puede demostrarse la limpieza de su secreto.
- Compatibilidad: se conservan Bash 3.2, PowerShell 5.1, `MULTICLI_HOME`,
  `~/MultiCliProfiles`, el shim `multi-cli` y los comandos legacy. No se declara
  verificacion real en Windows, macOS, Command Code ni Codex.
- Publicacion Git: `3ebfef7`, `4c40ae3` y `dd03bad` estan en `origin/main`; no
  se creo tag ni release.
- Siguiente gate al cierre: el movimiento seguro de la Etapa E requirio un
  alcance G2 independiente.

### 2026-08-22 — Etapa E: motor transaccional interno de movimiento

- Estado: tramo interno aprobado terminado bajo G2; la interfaz publica, el
  transporte remoto y la CLI JSON permanecen pendientes.
- Objetivo: incorporar al motor el contrato valioso de Codexporter —staging,
  integridad, procesos cerrados, propietario activo unico, activacion atomica,
  backup y rollback— sin logout, revocacion, regeneracion ni consulta a
  OpenAI.
- Alcance aprobado: implementaciones equivalentes Bash y PowerShell;
  deteccion legacy y schema v2; validacion JSON sin mostrar valores; hashes
  SHA-256; lock atomico por perfil; transporte y process probe inyectados;
  reconstruccion de `.runtime`; inventario de estados y codigos para la futura
  CLI JSON; documentacion, fixtures sinteticos, commit, push y CI.
- Antes: `lib/transfer.sh` y `lib/MultiCli.Transfer.psm1` implementaban
  templates, export e import sin credenciales, pero no existia un motor
  separado que pudiera transferir ownership de credenciales.
- Despues: `move_profile_transaction` e `Invoke-MultiCliProfileMove` ejecutan el
  mismo protocolo interno. Legacy reconoce `<perfil>/auth.json`; schema v2
  reconoce `.profile.json` y las credenciales declaradas bajo `auth/`. El
  runtime se excluye del transporte y se reconstruye desde el adapter despues
  de activar el destino.
- Seguridad: el motor falla cerrado ante identifiers inseguros, roots
  enlazados, traversal implicito, contenido desconocido, enlaces, hardlinks no
  declarados, credenciales faltantes o distintas, procesos activos o
  indeterminados, artefactos preexistentes y carreras de ownership. Un destino
  parcial se mueve a `.failed/`; el origen verificado permanece en
  `.inactive/`; ningun artefacto recuperable se poda automaticamente.
- Ownership y rollback: la copia viaja primero a `.staging/`, se compara por
  estructura, tamano y hash, se revalida bajo `.move-lock.<perfil>`, el origen
  se desactiva antes de activar destino y cualquier fallo tardio intenta
  cuarentena y restauracion. Si no puede probarse la restauracion, devuelve
  `ownership_indeterminate` y conserva todos los artefactos.
- Separacion de contratos: `export`, `import`, templates y `continue` siguen
  libres de credenciales. No se agrego un comando `move` a los entrypoints ni
  se congelo el envelope JSON.
- Archivos principales: `lib/transfer.sh`, `lib/MultiCli.Transfer.psm1`,
  `tests/move_safety.bats`, `tests/MoveSafety.Tests.ps1`,
  `tests/coverage/Invoke-ModuleCoverage.ps1`, `docs/move-protocol.md` y
  `docs/testing.md`.
- Caracterizacion y correcciones: las pruebas detectaron y corrigieron una
  colision con la variable automatica `$HOME`, la reduccion escalar de targets
  de hardlink en PowerShell 5.1 y una expresion regular invalida al normalizar
  `runtimeSubdir`. El gate de cobertura se completo con escenarios reales e
  inyecciones focalizadas, sin agregar excepciones.
- Validacion local: 18/18 pruebas focalizadas Bash; suite Bash completa de
  246 casos; 17 adapters validados; documentacion validada; sintaxis Bash y
  `git diff --check` correctos. Todas las pruebas mutables usaron scratch
  sintetico bajo directorios temporales.
- Validacion remota: el workflow `32599572338` termino verde con sus 11 jobs.
  Bats ejecuto 246/246 en Ubuntu y macOS; Pester ejecuto 385/385 en Windows; la
  cobertura instrumentada ejecuto 266 casos, alcanzo 948/948 comandos (100%)
  en `MultiCli.Transfer.psm1`, 99.61% total y cero misses inesperados. Bash
  obtuvo 76.79% global y paso el gate de lineas cambiadas; tambien pasaron
  ShellCheck, PSScriptAnalyzer, Actionlint, metadata y smoke tests efimeros en
  los tres sistemas.
- Commits publicados: `f0b83f0`, `8a3dba5`, `1fc2811`, `02e6024`, `2e09b41`,
  `7784d94`, `858d57b` y `73c9d50`, todos en `origin/main`. No se creo tag ni
  release.
- Efecto sobre credenciales y datos: ninguno real. No se leyeron ni
  modificaron perfiles del operador, `MULTICLI_HOME`, `~/.codex`, keyrings,
  instalaciones activas ni otros equipos; no hubo logout, revoke, auth clear,
  migracion real ni acceso a OpenAI.
- Plataformas verificadas: Linux local con fixtures; Linux, macOS y Windows en
  runners efimeros con fixtures. No se verifico una herramienta, cuenta,
  credencial, instalacion o maquina remota real.
- Exclusiones confirmadas: SSH y transporte de produccion, comando publico,
  CLI JSON estable, instalacion activa, release, modificacion de MultiCLI AI o
  Codexporter y migracion de consumidores.
- Recuperacion: una operacion exitosa conserva el origen como backup inactivo;
  una operacion fallida no poda staging, backup ni cuarentena. Los cambios del
  repositorio no fueron instalados sobre la copia activa.
- Siguiente gate: Etapa F debe definir y congelar la CLI JSON y decidir la
  interfaz publica de movimiento. SSH/equipos reales, auditoria final y la
  migracion simultanea de MultiCLI AI y Codexporter conservan autorizaciones
  separadas.

### 2026-08-22 — Etapa F: contrato JSON v1 para consultas

- Estado: tramo aprobado de consultas JSON v1 terminado y publicado en `main`;
  la Etapa F permanece abierta para el comando publico de movimiento, transporte
  y process probe de produccion.
- Objetivo: sustituir el futuro parsing de texto humano por un envelope
  versionado y seguro, manteniendo el modo humano y el shim `multi-cli`.
- Inventario consumidor: MultiCLI AI invoca el shim y conserva descubrimiento
  propio basado en filesystem y texto; Codexporter expone texto humano y SSH.
  Ninguno tenia un contrato JSON que debiera copiarse literalmente. No se
  modifico ninguno de los dos repositorios.
- Contrato: `schemaVersion`, `command`, `ok`, `data` y `error`; consultas
  `version`, `list/status`, `tools`, `doctor`, `stats` y `template list`; arrays
  ordenados, tamanos numericos y codigos de salida deterministas.
- Frontera de datos: se exponen solo nombres elegidos por el usuario necesarios
  para direccionar perfiles/templates y capacidades publicas de adapters. No se
  leen valores de credenciales ni se emiten rutas absolutas, rutas de binarios,
  `profileId`, IDs de cuenta, tokens, hashes o detalles privados de runtime.
- Movimiento: ambos motores pueden serializar cualquier resultado mediante
  `code`, `state` y `format`, sin rutas ni identificadores. No existe dispatch
  publico `move`; falta implementar transporte y una deteccion real de procesos
  antes de autorizarlo.
- Compatibilidad: Bash 3.2 y PowerShell 5.1 conservan su salida humana; `--json`
  puede ir antes del delimitador de argumentos. `doctor --deep` y comandos de
  mutacion rechazan JSON antes de operar.
- Pruebas: `tests/json_cli.bats` y `tests/JsonCli.Tests.ps1` usan exclusivamente
  homes, adapters, perfiles y credenciales sinteticos bajo temporales. La
  caracterizacion Bash fallo 7/7 antes de implementar y paso 7/7 tras el primer
  delta funcional; la suite contractual final contiene 11 casos Bash y su
  equivalente PowerShell.
- Validacion local: JSON Bash 11/11, suite Bash completa 257/257, sintaxis Bash,
  documentacion y `git diff --check` correctos. El host local no dispone de
  PowerShell, PSScriptAnalyzer ni Bashcov, por lo que esas comprobaciones se
  ejecutaron en CI.
- Validacion remota: el workflow CI `32603326309` sobre `5b74f5c` termino verde
  en sus 11 jobs. Bats paso 257/257 en Ubuntu y macOS; Pester paso 393/393 en
  Windows. La cobertura Bash fue 76.85% global y 100% en lineas cambiadas; la
  cobertura de modulos PowerShell fue 99.61% global, 100% para
  `MultiCli.Json.psm1` y 100% en lineas cambiadas. Tambien pasaron ShellCheck,
  PSScriptAnalyzer, actionlint, metadatos y smoke tests efimeros de instalacion
  en Linux, macOS y Windows.
- Publicacion: commits `852164c`, `120aeb1`, `13118c3` y `5b74f5c` enviados a
  `origin/main`. No se creo tag ni release.
- Pendiente de la Etapa F: integrar el serializador con un dispatch publico de
  movimiento solo despues de completar process probe y transporte seguros. La
  migracion de MultiCLI AI y Codexporter conserva su gate independiente.

### 2026-08-22 — compatibilidad whole-root legacy y migracion gradual a v2

- Estado: cambio G2 terminado localmente; no se hizo commit, push, instalacion
  ni prueba con una cuenta real.
- Objetivo: hacer verdadera la compatibilidad que upstream documenta para
  perfiles antiguos, manteniendo schema v2 como unico formato de creacion y
  como destino de una migracion posterior, voluntaria y gradual.
- Branch y base: `main`, tip inicial `293c48d`; upstream puro fijado en
  `6efb0d2`.
- Hallazgo upstream: su README afirma que los perfiles antiguos conservan el
  comportamiento whole-root, pero el dispatcher de un adapter schema v2
  enviaba todo perfil sin `.profile.json` al runtime account-overlay y la
  prueba upstream exigia el error `missing schema-v2 metadata`. Por tanto, la
  intencion contractual y la implementacion no coincidian.
- Decision del producto: los perfiles nuevos siguen siendo schema v2; los
  legacy existentes permanecen utilizables; `migrate` nunca se ejecuta de
  forma implicita. La adopcion v2 sobre datos existentes empezara con perfiles
  elegidos por el usuario como poco importantes y conservara la ruta legacy
  hasta completar y verificar la transicion.
- Inventario real previo, solo lectura y sanitizado: 15 perfiles Codex, todos
  legacy, todos con un `auth.json` raiz que parsea como objeto JSON. No se
  leyeron ni registraron valores, nombres privados, IDs o hashes. Un recorrido
  recursivo posterior fue interrumpido por ser innecesariamente lento y no se
  repetira para este cambio.
- Antes: un perfil `accountOverlay` sin `.profile.json` abortaba incluso cuando
  el mecanismo `fileOverlay` podia conservar de forma segura su home completo.
- Despues: Bash y PowerShell detectan exclusivamente la combinacion
  `accountOverlay + fileOverlay + metadata ausente` y lanzan el directorio del
  perfil como whole-root. El launcher no crea `.profile.json`, `auth/` ni
  `.runtime`, no mueve `auth.json` y limpia cualquier `MULTICLI_PROFILE_ID`
  heredado en vez de atribuirle al legacy una identidad v2. Un proceso real de
  la herramienta puede modificar su propio home como siempre; eso no se probo
  ni se autorizo en este tramo.
- Fallo cerrado: `processSecret`, `osUserCredentialStore` e `inseparable` no
  heredan esta compatibilidad. Sin metadata siguen rechazados por sus rutas
  schema v2. Un enlace, incluso roto, en `.profile.json` no se reinterpreta en
  Bash como ausencia segura.
- Portabilidad legacy: clone, export, import y templates legacy permanecen
  bloqueados para impedir que una copia whole-root transporte credenciales. La
  compatibilidad agregada cubre lanzamiento y recuperacion, no copia insegura.
- Archivos modificados: `nini-agents`, `nini-agents.ps1`,
  `tests/overlay_state.bats`, `tests/OverlayState.Tests.ps1` y esta bitacora. No
  cambiaron adapters, schema JSON, modulos de migracion, shims ni consumidores.
- Caracterizacion previa: la nueva prueba Bash de file-overlay legacy fallo
  antes del cambio porque el launcher devolvio estado 1 antes de iniciar el
  proceso sintetico.
- Validacion posterior: sintaxis Bash correcta; 2/2 casos legacy; 38/38 casos
  combinados de overlay e isolated-mode; 2/2 casos focalizados de migracion
  (dry-run sin escritura y lanzamiento posterior a migracion); suite Bash
  completa 258/258 sobre el diff productivo final; documentacion validada;
  `git diff --check` correcto. Todo uso filesystem mutable ocurrio bajo homes
  temporales con credenciales ficticias. La prueba legacy compara la credencial
  sintetica antes y despues, inyecta un `MULTICLI_PROFILE_ID` obsoleto y
  demuestra que el hijo no lo recibe y que no aparece metadata ni runtime.
- Plataformas no verificadas: el host no dispone de Windows PowerShell,
  PowerShell Core, Pester, ShellCheck ni Bashcov. La paridad PowerShell fue
  implementada y caracterizada, pero no ejecutada. Tampoco se probo macOS,
  Windows, un binario Codex real ni una cuenta real. El gate formal de cobertura
  se intento con baseline `HEAD` y termino con codigo 2 antes de instrumentar
  porque `bashcov` no esta instalado; no se instalo ninguna dependencia fuera
  del alcance.
- Efecto sobre credenciales y datos reales: ninguno. No se establecio
  `CODEX_HOME` hacia un perfil real, no se ejecuto Codex, logout, revoke,
  `auth clear`, migracion, copia, borrado ni escritura bajo el store real.
- Recuperacion del cambio: revertir solamente las ramas de dispatch restaura el
  rechazo anterior; no existe recuperacion de datos asociada porque el cambio
  no transforma perfiles.
- Preparacion de MultiCLI AI: el consumidor futuro debe aceptar
  `profile.schemaVersion` 1 y 2 y delegar launch al motor. Antes de ese G4, el
  motor aun debe decidir un estado publico de credencial que no exponga rutas y
  una ejecucion machine-safe con stdout limpio para `codex app-server`; el
  launch humano actual escribe una linea informativa y no debe contaminar
  JSON-RPC.
- Plan del piloto real, aun no autorizado: elegir explicitamente un perfil de
  baja importancia; cerrar procesos; revisar `migrate --dry-run`; preparar un
  backup inactivo y rollback verificables; migrar solo ese perfil; comprobar
  cuenta, credencial, sesiones y configuracion; y restaurar ante cualquier
  diferencia. No usar `--prefer-profile` sin revisar cada conflicto.
- Siguientes gates: G5/G9 separados para inspeccion y migracion del perfil real
  elegido; G2 para ampliar el contrato machine-safe o JSON; G4 para modificar
  MultiCLI AI. Ninguno queda autorizado por este cierre.
- Punto de reanudacion tras compactacion: este G2 esta completo y validado
  localmente, pero permanece sin commit ni push. El siguiente trabajo requiere
  presentar un alcance nuevo; no repetir la auditoria profunda de perfiles ni
  iniciar automaticamente la migracion real o el refactor consumidor.

### 2026-08-22 — migrador legacy a v2 endurecido antes del piloto

- Estado: cambio G2 terminado localmente; no se hizo commit, push, instalacion,
  lanzamiento real ni acceso nuevo a perfiles o credenciales reales.
- Objetivo: convertir el `migrate` ya existente en una transaccion suficientemente
  conservadora para preparar un primer piloto voluntario sin copiar, regenerar,
  revocar ni dejar dos propietarios independientes de la credencial.
- Candidato acordado para una fase real posterior: `codex-example`.
  `codex-vivi` queda expresamente fuera. Registrar el candidato no autoriza
  inspeccionarlo, ejecutar su dry-run ni migrarlo.
- Antes: el motor producia un plan ordenado, usaba movimientos atomicos y
  escribia journal, pero no comprobaba procesos, no serializaba migraciones y
  un fallo manejado podia dejar operaciones completadas para recuperacion
  manual. Tampoco demostraba que el movimiento de la credencial conservara su
  identidad fisica.
- Despues, preflight: apply comprueba los procesos antes de escribir y otra vez
  bajo un lock exclusivo por perfil. Linux busca el environment de aislamiento
  declarado por el adapter —para Codex, `CODEX_HOME`— en procesos del mismo
  usuario; otros hosts usan de forma conservadora los nombres de binario
  declarados. Un resultado ocupado o indeterminado aborta cerrado. El lock
  serializa migraciones del motor; no impide por si solo que un proceso externo
  sea iniciado despues de la segunda comprobacion, por lo que el piloto exige
  una ventana operativa sin lanzamientos.
- Despues, rutas: dry-run y apply rechazan locks, staging o temporales
  inconclusos, metadata enlazada, perfiles enlazados, destinos de credencial o
  estado que crucen symlinks/junctions, credenciales hardlinked, destinos de
  credencial no regulares y volumenes que convertirian el rename en copia.
  Schema, adapter y plan siguen siendo la fuente declarativa de las rutas.
- Despues, credencial: Bash registra en memoria dispositivo e inode, ejecuta un
  rename dentro del mismo volumen y exige la misma identidad con link count uno
  al terminar. PowerShell exige el mismo volumen y una unica ruta regular no
  enlazada alrededor de `Move-Item`; el host actual no permite ejecutar ni
  demostrar esa rama. Ningun valor, hash, token o identificador se escribe al
  journal o a la salida.
- Despues, rollback: operaciones destructivas o de reemplazo conservan su
  contraparte en `.migration-rollback`; un fallo manejado revierte en orden
  inverso, retira solo directorios creados por la transaccion, restaura el root
  compartido si fue creado por ella y deja journal `rolled_back`. Si no puede
  demostrar la restauracion, conserva evidencia, marca `rollback_failed` y
  ordena no lanzar. Un corte abrupto, `SIGKILL` o caida del equipo no ejecuta
  cleanup automatico: el lock, journal o staging remanente bloquean nuevos
  intentos, incluso dry-run, hasta una recuperacion manual separada.
- Determinismo: con el mismo arbol, adapter y politica de conflictos, el
  inventario, orden de operaciones y decisiones son reproducibles. El
  `profileId` de una migracion nueva sigue siendo un UUID aleatorio por diseno;
  nunca se deriva de la credencial. Un reintento tras `rolled_back` vuelve a
  calcular el mismo plan; un perfil ya v2 es no-op.
- Distincion de ownership: esta migracion local no crea un backup de
  `auth.json`; mueve el mismo archivo a `auth/auth.json` y el rollback invierte
  el rename. El runtime posterior puede exponer esa credencial mediante
  symlink/hardlink reconstruible, que es otra ruta al mismo objeto y no una
  segunda copia ni un token regenerado. El requisito de copia inactiva pertenece
  al futuro movimiento entre equipos, no a este cambio de layout dentro del
  mismo perfil.
- Compatibilidad: no se crean perfiles schema v1, el lanzamiento whole-root
  legacy sigue disponible y la migracion continua siendo voluntaria. No cambio
  el schema, el adapter Codex, los shims ni los contratos de MultiCLI AI o
  Codexporter. Bash 3.2 y Windows PowerShell 5.1 conservan implementaciones
  equivalentes en el codigo.
- Archivos de este endurecimiento: `lib/migration.sh`,
  `lib/MultiCli.Migration.psm1`, `tests/migration.bats`,
  `tests/Migration.Tests.ps1`, `tests/ModuleFunctions.Tests.ps1` y esta
  bitacora. El worktree conserva ademas los launchers y pruebas del G2
  whole-root anterior.
- Caracterizacion: cuatro casos nuevos de seguridad fallaron 4/4 contra sus
  bordes anteriores —destinos enlazados o cross-volume, limpieza del root
  creado y movimiento cross-volume de estado— y pasaron 4/4 tras sus deltas.
  La suite focalizada final contiene 31 casos Bash; incluye proceso real
  sintetico con environment del perfil, lock, rollback posterior a reemplazo,
  links, hardlinks, artefactos stale, identidad fisica y lanzamiento schema v2
  sobre credenciales ficticias.
- Efecto sobre datos reales: ninguno. No se leyo, parseo, comparo, copio ni
  modifico `auth.json` de ningun perfil real; no se establecio `CODEX_HOME`
  hacia uno, no se ejecuto Codex y no hubo logout, refresh, revoke, auth clear,
  migracion o backup de una cuenta real.
- Fase real siguiente, aun pendiente de G5: inspeccion read-only de
  `codex-example` limitada a tipo/existencia de entradas declaradas, links,
  link-count, volumen, artefactos de control y procesos; confirmar que no existe
  un segundo destino `auth/auth.json`; luego ejecutar solamente
  `nini-agents migrate codex/codex-example --dry-run` desde el checkout aislado.
  No se leeran valores de auth, no se lanzara Codex y no se escribira el perfil.
- Apply real, aun pendiente de un G9 separado: solo despues de revisar juntos
  el preflight y el plan. Sera un apply sin `--prefer-profile`, con todos los
  procesos cerrados y sin lanzamientos concurrentes; cualquier conflicto o
  evidencia inconclusa cancela el piloto. Verificar el lanzamiento y la cuenta
  requerira otro alcance explicito porque el proceso real puede escribir estado
  o refrescar su propia sesion.
- Validacion final local: caracterizacion nueva 4/4 fallos antes de sus deltas
  y 4/4 pases despues; migracion Bash 31/31; bloque acumulado hasta migracion
  145/145; sintaxis Bash correcta; 17/17 adapters validos; documentacion valida
  y `git diff --check` limpio. Una suite completa anterior al ultimo guard
  cross-volume paso 268/268. Con el diff final, tres pasadas completas de 269
  casos terminaron 267/269, 268/269 y 268/269 por fallos intermitentes distintos
  fuera del migrador; cada caso fallido paso al repetirlo aisladamente y el
  migrador permanecio verde. Por ello no se registra un gate completo limpio
  de 269/269. Una reproduccion adicional localizo una causa preexistente:
  `validate_adapter_object_fields` combina `printf | grep -q` con `pipefail`, y
  el cierre temprano de `grep` puede convertir el `SIGPIPE` del productor en un
  falso campo no soportado. El validador paso 17/17 al repetir; no se modifico
  porque ese arreglo pertenece a otro alcance G2. Su efecto actual sobre un
  piloto es fail-closed antes de cualquier escritura. La cobertura se intento
  con baseline `HEAD` y termino con codigo 2 antes de instrumentar porque
  `bashcov` no esta instalado; no se instalo la dependencia.
- Plataformas no verificadas: PowerShell/Pester, Windows y macOS no estan
  disponibles en este host. La paridad PowerShell fue implementada y
  caracterizada en pruebas, pero no ejecutada; tampoco se probo un binario
  Codex real ni una cuenta real.
- Punto de reanudacion tras compactacion: cerrar los gates sinteticos y reportar
  resultados. No inspeccionar ni migrar automaticamente `codex-example`; pedir G5
  para el preflight read-only y dry-run, y despues G9 para un apply distinto.

### 2026-08-22 — preflight de `codex/luis` y limite moderno del adapter Codex

- Estado: el G5 read-only del candidato y el G2 minimo derivado quedaron
  completados localmente. No se hizo apply real, lanzamiento de Codex, commit,
  push, instalacion ni publicacion.
- Correccion de identidad: `codex-example` es el launcher legacy y corresponde al
  spec almacenado `codex/example`; el spec `codex/codex-example` escrito en la entrada
  anterior fue una suposicion incorrecta. No se listaron otros perfiles para
  resolverla.
- Preflight real sanitizado: el perfil existe como directorio legacy regular;
  `auth.json` existe como archivo regular con link count uno;
  `auth/auth.json`, `auth/`, metadata v2 y artefactos de migracion no existen;
  perfil y root compartido estan en el mismo volumen; el root compartido es un
  directorio regular; y el probe Linux demostro el perfil inactivo. El arbol
  legacy contiene seis symlinks y ningun archivo hardlinked.
- Dry-run real: `nini-agents migrate codex/luis --dry-run`, ejecutado desde el
  checkout con el store legacy explicitamente seleccionado, termino en rechazo
  fail-closed por entradas no declaradas. La identidad estructural de
  `auth.json` —dispositivo, inode, link count, tamano y mtime— quedo igual;
  `auth/auth.json`, `.profile.json`, journal, lock y rollback siguieron
  ausentes. No se abrio ni parseo el contenido de autenticacion.
- Inventario read-only limitado al rechazo: 37 entradas top-level no
  declaradas y cero overlaps. Por nombre y tipo, 29 parecen estado operativo
  moderno —bases SQLite y sus sidecars, caches, logs, locks, snapshots y
  marcadores—, cuatro son configuracion o backups locales y cuatro pertenecen
  a la topologia de credenciales/OAuth MCP y sus respaldos. Esta agrupacion es
  una inferencia; no concede una clasificacion de adapter.
- Enlaces sensibles: `.credentials.json` y `mcp-oauth-locks` son symlinks con
  target existente fuera tanto del perfil como del root compartido Codex. Se
  determino solo el alcance del target; no se mostro la ruta, no se siguio para
  leer contenido y no se modifico. Por ello `codex/luis` no es un piloto simple
  y no debe forzarse con `--prefer-profile`, borrados ni allowlists locales.
- Evidencia primaria: la documentacion oficial de
  [autenticacion de Codex](https://developers.openai.com/codex/auth) confirma
  que `auth.json` bajo `CODEX_HOME` contiene tokens y que el store puede ser
  file/keyring/auto. La
  [referencia de configuracion](https://developers.openai.com/codex/config-reference)
  confirma `log/` bajo `CODEX_HOME` y un store separado file/keyring/auto para
  OAuth MCP. La guia oficial de
  [AGENTS.md](https://developers.openai.com/codex/guides/agents-md) confirma
  `AGENTS.md` global bajo `CODEX_HOME`. El paquete local
  `@openai/codex` 0.147.0 se inspecciono sin ejecutarlo; sus strings confirman
  `.credentials.json`, `mcp-oauth-locks`, los nombres de bases observados,
  caches, locks y snapshots, pero no prueban por si solos que puedan
  compartirse entre cuentas.
- Decision implementada: el adapter Codex agrega solo las rutas ordinarias
  demostradas `AGENTS.md` —tambien en `filePaths`— y `log/` a `sharedPaths`.
  No se agregaron las bases, `.credentials.json`, `mcp-oauth-locks`, backups o
  marcadores; no se amplio schema v2 y no se debilito el rechazo de entradas
  desconocidas. La documentacion del adapter y la matriz aclaran que OAuth MCP
  file-based aun no pertenece al boundary probado.
- Validador: se reemplazo `printf | grep -q` dentro de
  `validate_adapter_object_fields` por una entrada directa a `grep`. Esto
  elimina el falso campo no soportado causado por `SIGPIPE` bajo `pipefail` sin
  cambiar el conjunto de campos permitido. Una prueba con una allowlist mayor
  que el pipe buffer caracteriza el caso de forma determinista.
- Pruebas sinteticas: el adapter se caracterizo primero en rojo —23/24, fallo
  exclusivo por `AGENTS.md` y `log/` ausentes— y luego paso 25/25 con la
  regresion del validador. Overlay Bash paso 14/14 y demuestra links compartidos
  para instrucciones, rules y logs sin crearlos bajo `auth/`. El migrador
  incorpora un perfil Codex sintetico con `state_5.sqlite`, `.credentials.json`
  y `mcp-oauth-locks`: debe rechazar y conservar sin cambios la credencial
  ficticia, metadata y journal ausentes. Migracion Bash paso 32/32 y la suite
  Bash completa paso 271/271 en una unica ejecucion limpia. Ninguna prueba uso
  el store o home real.
- Archivos de este tramo: `ai-tools/codex/adapter.json`,
  `lib/adapter-validation.sh`, `tests/adapter_schema.bats`,
  `tests/AdapterSchema.Tests.ps1`, `tests/migration.bats`,
  `tests/Migration.Tests.ps1`, `tests/overlay_state.bats`,
  `tests/OverlayState.Tests.ps1`, `docs/adapters/codex.md`,
  `docs/support-matrix.md` y esta bitacora. El resto del worktree modificado
  pertenece a los G2 anteriores y se preservo.
- Plataformas y gates: 17/17 adapters, sintaxis Bash, JSON del adapter,
  validacion documental y `git diff --check` pasan; la suite Bash completa pasa
  271/271. El gate formal de cobertura termino con codigo 2 antes de
  instrumentar porque `bashcov` no esta instalado. PowerShell, Pester, Windows,
  macOS, ShellCheck y Bashcov no estan disponibles en este host; no se instalo
  nada y esas plataformas permanecen sin ejecutar.
- Efecto sobre credenciales: ningun valor, hash, token, ID de cuenta o ruta
  privada fue leido, registrado o versionado. No hubo logout, refresh, revoke,
  reautenticacion, copia, move, borrado ni regeneracion. El unico acceso real
  fue estructural/read-only y el dry-run se rechazo antes de escribir.
- Punto de reanudacion tras compactacion: no repetir el inventario real y no
  volver a tocar `codex/luis` automaticamente. El siguiente G2 debe investigar
  y decidir, con evidencia primaria y fixtures, la frontera de las bases
  modernas y de OAuth MCP —incluido si schema v2 necesita credenciales
  opcionales o un mecanismo distinto— antes de modificar runtime, schema o el
  adapter. Solo despues repetir el dry-run real bajo un G5 nuevo. El apply real
  conserva un G9 separado; MultiCLI AI y Codexporter siguen fuera de este gate.

### 2026-08-23 — checkpoint compacto de continuidad

- Estado: G0 documental completado; no se modificaron codigo, adapters, schema,
  perfiles, credenciales, instalaciones ni referencias Git.
- Objetivo: evitar releer toda la bitacora en cada compactacion sin borrar su
  historia, evidencia ni decisiones. Se creo
  [nini-agents-resume.md](nini-agents-resume.md) como indice operativo y se
  mantuvo este documento como fuente historica canonica.
- Contenido preservado en el checkpoint: direccion schema v2 con compatibilidad
  legacy, estado del worktree, garantias del migrador, semantica de rutas,
  preflight sanitizado de `codex/luis`, validaciones, plataformas ausentes,
  bloqueo moderno Codex y secuencia restante G2, G5 y G9.
- Regla de lectura: una reanudacion ordinaria lee `AGENTS.md`, el checkpoint y
  la skill aplicable. Este documento completo queda para reconstruir historia,
  resolver contradicciones o delimitar una etapa nueva.
- Seguridad: el resumen no contiene valores, hashes, IDs ni rutas privadas; no
  concede autorizacion para repetir el inventario real, ejecutar otro dry-run,
  aplicar la migracion ni lanzar Codex.
- Validacion: `python3 scripts/validate-docs.py` y `git diff --check` correctos.
- Siguiente gate: permanece sin cambios. Investigar y aprobar un G2 funcional
  para la frontera de bases modernas y OAuth MCP antes de volver a operar sobre
  `codex/luis` bajo un G5 nuevo.

### 2026-08-23 — G2 de SQLite moderno y bloqueo explicito de OAuth MCP

- Alcance aprobado: investigar el almacenamiento moderno de Codex con fuentes
  primarias y homes sinteticos; alinear schema, validadores Bash/PowerShell,
  runtime, migrador, adapter, pruebas y documentacion sin acceder de nuevo a
  `codex/luis`, `~/.codex` ni credenciales reales. MultiCLI AI, Codexporter,
  instalaciones, commits y publicaciones quedaron excluidos.
- Evidencia primaria: la documentacion oficial de
  [autenticacion](https://learn.chatgpt.com/docs/auth) mantiene `auth.json`
  bajo `CODEX_HOME` o el credential store del sistema; la
  [referencia de configuracion](https://learn.chatgpt.com/docs/config-file/config-reference)
  declara `sqlite_home` para las bases de estado y un store separado para OAuth
  MCP. No documenta `.credentials.json`, `mcp-oauth-locks/` ni
  `CODEX_SQLITE_HOME` como contrato portable.
- Evidencia sintetica: Codex local 0.147.0, ejecutado solo con homes bajo
  `/tmp`, creo las familias `goals_1`, `logs_2`, `memories_1`, `queue_1` y
  `state_5`; `doctor` reconocio tambien `thread_history_1`. Cada familia usa
  `.sqlite`, `-shm` y `-wal`. `installation_id` pudo persistir mediante el link
  normal existente. La CLI acepto `-c sqlite_home=...` tanto antes como despues
  de un subcomando. Un intento sintetico de login OAuth no pudo demostrar el
  formato de archivo ausente ni una semantica equivalente para hardlinks de
  Windows; no se invento ese contrato.
- Schema/runtime: `normalState.directPaths` es una clasificacion opcional que
  debe ser subconjunto exacto de `sharedPaths` o `sessionPaths`. Se migra segun
  esa clase, pero el runtime no crea source ni link para esa ruta. En
  account-overlay file/process, `isolation.args` se expande y se agrega despues
  de las opciones del usuario pero antes de un delimitador literal `--`,
  permitiendo imponer el root directo sin convertir el flag en input posicional.
  Bash y PowerShell implementan el mismo contrato.
- Adapter Codex: `installation_id` es estado compartido; las seis familias
  SQLite conocidas y sus sidecars son archivos de sesion directos. El launch
  limpia un `CODEX_SQLITE_HOME` heredado y fuerza el `sqlite_home` documentado
  al shared root. Los nombres son exactos y versionados; un nombre futuro queda
  `unknown`, sin globs que puedan capturar secretos.
- OAuth MCP: `.credentials.json` y `mcp-oauth-locks/` son `unsafePaths`. El
  migrador Bash/PowerShell los distingue de `unknown` y rechaza antes de todo
  write. No son `credentialFiles`, no generan placeholders, no se siguen ni se
  materializan symlinks y no se presupone que puedan compartirse entre cuentas.
- Ciclo rojo/verde: seis fallos focalizados iniciales demostraron schema,
  adapter, runtime, SQLite y OAuth ausentes. Tras implementar, las pruebas
  focalizadas de schema/overlay/migracion pasan 75/75; la suite Bash completa
  pasa 275/275 y 17/17 adapters validan. Tambien pasan sintaxis Bash, JSON y la
  comprobacion real-sintetica de posicion de argumentos. PowerShell/Pester,
  Windows y macOS no estan disponibles en este host; la paridad esta escrita y
  caracterizada, no ejecutada.
- Seguridad: no se accedio al perfil real, no se leyo ni mostro contenido de
  auth/OAuth, y no hubo logout, refresh, revoke, copia, move, borrado,
  regeneracion ni escritura fuera de fixtures temporales. La compatibilidad
  whole-root legacy sigue intacta y no se crearon perfiles schema v1.
- Estado del end-to-end: G2 sintetico cerrado, pero `codex/luis` no es migrable
  mientras conserve entradas OAuth `unsafe`. El siguiente gate es un G5 nuevo,
  read-only y dry-run, para confirmar el rechazo explicito y descubrir residuos
  `unknown`; no autoriza apply. Despues se debe elegir otro piloto sin OAuth o
  aprobar otro G2 de ownership OAuth. G9 y un lanzamiento real siguen siendo
  autorizaciones separadas.

### 2026-08-23 — G2 de credencial MCP compartida y preservacion legacy inactiva

- Alcance aprobado: sustituir el bloqueo sintetico de OAuth MCP por un contrato
  schema v2 seguro, manteniendo `auth.json` por perfil y un unico store OAuth
  MCP para todos los perfiles Codex administrados por Nini Agents. Incluyo
  schema, validadores, runtime, migracion, transferencia, diagnostics,
  adapters, pruebas y documentacion con paridad Bash/PowerShell. Excluyo
  `codex/luis`, `codex/vivi`, `~/.codex`, stores o instalaciones activas,
  MultiCLI AI, Codexporter, login/logout real, commits y publicaciones.
- Evidencia usada: la documentacion oficial separa
  `cli_auth_credentials_store` de `mcp_oauth_credentials_store`. Codex local
  0.147.0, ejecutado solo con homes sinteticos, acepto el modo MCP `file`, creo
  `mcp-oauth-locks/file-store.lock` y acepto `{}` como store inicial sin
  producir una credencial real. Sus strings muestran `.credentials.json`, los
  locks y una transaccion de refresh serializada. No se leyo ningun valor real.
- Contrato nuevo: `sharedCredentialState` es opcional y exclusivo de adapters
  schema v2 `fileOverlay`. Su `root` debe quedar bajo
  `.shared/<adapter-id>/` dentro de `MULTICLI_HOME`; `entries` admite
  `jsonObjectFile` y `directory`; `legacyMigration` solo admite
  `preserveInactive`. Sus rutas deben ser seguras, unicas/no solapadas y
  separadas de credenciales de perfil, estado normal, sesiones y `unsafe`.
- Runtime: Codex usa `MULTICLI_HOME/.shared/codex/mcp/.credentials.json` y
  `mcp-oauth-locks/` como un grupo. Cada `.runtime` enlaza ambos al mismo
  backing store, mientras `auth.json` sigue enlazando a `profile/auth/` de cada
  cuenta. La inicializacion entre perfiles se serializa; un archivo ausente se
  crea como `{}` y los directorios POSIX con permisos privados. Se aborta ante
  symlinks, tipos inesperados o hardlinks POSIX no esperados, sin fallback de
  copia ni lectura del contenido existente. `doctor --deep` reconoce la fuente
  compartida. El adapter fuerza `cli_auth_credentials_store="file"`,
  `mcp_oauth_credentials_store="file"` y `sqlite_home` despues de opciones del
  usuario y antes de `--`.
- Migracion legacy: `.credentials.json` y `mcp-oauth-locks` dejan de ser
  `unsafe` y se clasifican `shared-credential`. Nunca se importan al store
  activo: el objeto legacy mismo —archivo, directorio o link— se mueve por
  rename del mismo volumen a
  `.inactive/migrations/<adapter>/<profile>/shared-credentials/`. El target de
  un link no se sigue ni se imprime. Cada operacion se journaliza como
  `preserve-shared-credential`; un fallo posterior la devuelve al layout
  legacy y elimina solo los directorios de recuperacion creados por esa
  transaccion. Tras exito, la recuperacion queda inactiva y no se elimina
  automaticamente. La migracion no crea el store compartido ni autentica MCP.
- Transferencia: el store compartido esta fuera del perfil y no viaja en
  templates, export, import, clone o move. Ademas, toda ruta declarada y sus
  descendientes se consideran credencial para rechazar payloads hostiles. La
  recuperacion inactiva tambien queda fuera del perfil activo.
- Semantica de dos procesos: `nini-agents launch codex/luis` y
  `nini-agents launch codex/vivi` tendran `CODEX_HOME` runtime distintos y
  `auth.json` fisicamente distintos, pero `.credentials.json` y
  `mcp-oauth-locks/` apuntaran al mismo store. Una autenticacion MCP hecha desde
  uno queda disponible al otro sin mezclar las cuentas Codex principales.
- Pruebas sinteticas en este tramo: schema/adapter Bash 32/32, overlay 18/18,
  migracion 36/36 y transferencia 19/19; 17/17 adapters validos. La suite Bash
  completa pasa 287/287. Tambien pasan sintaxis Bash, parseo JSON, validacion de
  documentacion y `git diff --check`. El runtime demuestra inicializacion
  concurrente desde dos perfiles, identidad compartida de MCP, separacion de
  auth y rechazo de links/hardlinks inesperados; migracion demuestra dry-run
  sin writes, preservacion inactiva sin tocar targets y rollback completo;
  transferencia demuestra exclusion de export y rechazo de import.
- Paridad no ejecutada: se implementaron validadores, runtime, migracion,
  transferencia, diagnostics y Pester equivalentes para Windows PowerShell
  5.1, pero este host no tiene PowerShell/Windows. Tampoco se ejecuto macOS ni
  un Codex real contra una cuenta. ShellCheck tampoco esta instalado. El gate
  de cobertura Bash no pudo instrumentarse porque falta `bashcov`; no se
  instalaron dependencias para ampliar el alcance.
- Seguridad real: ningun perfil, token, ID, hash, target privado o archivo de
  credenciales real fue abierto, modificado o mostrado. No hubo logout,
  refresh, revoke, regeneracion, migracion o lanzamiento real. El preflight de
  `codex/luis` no se repitio.
- Siguiente gate: el G2 sintetico y su revision quedan cerrados. Un G5 separado
  puede repetir solo el preflight estructural minimo y
  `nini-agents migrate codex/luis --dry-run`; se espera preservacion inactiva de
  los dos objetos MCP y todavia pueden quedar otras entradas `unknown`. Un
  apply real, el primer lanzamiento y cualquier login MCP siguen siendo gates
  independientes.

### 2026-08-23 — segundo G5 real de `codex/luis` tras el contrato MCP compartido

- Alcance aprobado: repetir una sola vez el preflight estructural minimo y
  `nini-agents migrate codex/luis --dry-run` con el motor G2 actualizado;
  comparar despues la estructura del perfil y registrar evidencia sanitizada.
  Quedaron excluidos apply, `--prefer-profile`, launch, login/logout, refresh,
  revoke, copia, rename, borrado, seguimiento de targets, otros perfiles,
  consumidores, instalaciones y operaciones Git.
- Preflight real: el perfil seguia legacy, regular e inactivo; `auth.json`
  seguia siendo un archivo regular con link count uno; `auth/auth.json`,
  metadata y artefactos de control seguian ausentes; el perfil y el shared root
  estaban en el mismo volumen. El store MCP compartido y la recuperacion
  inactiva aun no existian. Solo se fijaron huellas de metadata; no se abrio ni
  parseo contenido de autenticacion y no se resolvieron ni mostraron targets.
- Resultado del unico dry-run: termino con codigo 1 y rechazo fail-closed antes
  de construir o imprimir el plan porque permanecen 14 entradas `unknown`:
  `.credentials.json.before-shared-supabase-20260721T202703Z`,
  `.personality_migration`, `.sandbox_migration`, `.tmp`, `cache`,
  `config.toml.bak-20260704`, `config.toml.bak-20260705-516-workaround`,
  `gpt-5.5-no-intermediary-updates.md`,
  `mcp-oauth-locks.before-shared-supabase-20260721T202703Z`,
  `models_cache.json`, `shell_snapshots`, `thread-writer-locks`, `tmp` y
  `version.json`. No hubo overlaps ni entradas `unsafe` reportadas.
- Evidencia del contrato nuevo: los objetos activos `.credentials.json` y
  `mcp-oauth-locks` ya no aparecen como `unknown`, a diferencia del primer G5.
  Esto confirma su clasificacion `shared-credential`; sin embargo, el rechazo
  global ocurre antes de `migration_plan_ops`, por lo que este dry-run no llego
  a imprimir las operaciones `preserve-shared-credential`. No debe afirmarse
  todavia que el plan real completo esta limpio.
- Postflight real: las huellas estructurales de `auth.json` y del top-level del
  perfil fueron identicas; proceso, destinos y artefactos de control siguieron
  ausentes; tampoco se crearon el store MCP compartido ni la recuperacion
  inactiva. No hubo logout, refresh, revoke, regeneracion, copia, move, borrado
  ni escritura sobre el perfil o credenciales reales.
- Validacion de cierre: `python3 scripts/validate-docs.py` y
  `git diff --check` pasaron. No se repitieron suites funcionales porque este
  gate no cambio codigo, schema, adapter ni pruebas. PowerShell/Windows, macOS,
  ShellCheck y cobertura Bash permanecen sin ejecutar en este host.
- Bloqueo siguiente: decidir bajo un G2 separado la clasificacion contractual
  de las 14 entradas restantes usando evidencia primaria y fixtures
  sinteticos. Los dos objetos `*.before-shared-supabase-*` son backups OAuth
  por nombre y deben permanecer fail-closed hasta definir preservacion o una
  frontera explicita; esa inferencia no autoriza borrarlos ni declararlos estado
  normal. Solo despues corresponde otro G5. G9, launch real y login MCP siguen
  siendo autorizaciones independientes.

### 2026-08-23 — G2 sintetico de residuos reconstruibles y backups MCP

- Alcance aprobado: investigar las 14 entradas rechazadas por el segundo G5 y
  clasificar solo las demostrables; alinear schema, validadores, migracion,
  transferencia, `doctor`, adapter, pruebas y documentacion con paridad
  Bash/PowerShell. Quedaron excluidos nuevos accesos a perfiles/home/credenciales
  reales, apply, launch, login/logout, `--prefer-profile`, consumidores,
  instalaciones y operaciones Git.
- Evidencia primaria: la [referencia oficial de configuracion de
  Codex](https://learn.chatgpt.com/docs/config-file/config-reference) documenta
  `CODEX_HOME/config.toml`, `sqlite_home`, `log_dir` y el store OAuth MCP, pero
  no declara los nombres de cache, snapshots, locks o marcadores observados. La
  [documentacion oficial de autenticacion](https://learn.chatgpt.com/docs/auth)
  mantiene `auth.json` como estado portador de tokens bajo `CODEX_HOME`; no se
  reclasifico ningun residuo ambiguo como auth principal.
- Evidencia local sintetica: strings del binario instalado Codex 0.147.0
  vinculan `.sandbox_migration` al migrador de sandbox, `models_cache.json` al
  manager/cache de modelos, `shell_snapshots` al snapshot de shell,
  `thread-writer-locks` al lock local de escritura y `version.json` al cache de
  actualizacion. Homes enteramente bajo `/tmp` demostraron que archivos vacios
  o `{}` para `models_cache.json` y `version.json` son formatos invalidos; por
  eso el motor no los inicializa. `.personality_migration` no obtuvo evidencia
  suficiente y permanece desconocido.
- Contrato nuevo: `normalState.runtimePaths` contiene rutas exactas de estado
  reconstruible generado por la herramienta dentro de `.runtime`. No crea
  source, placeholder, link ni entrada de `.runtime-manifest`; `doctor --deep`
  reconoce la ruta y descendientes. Migracion preserva el objeto legacy por
  rename del mismo volumen bajo
  `.inactive/migrations/<adapter>/<profile>/runtime-state/`, journaliza
  `preserve-runtime-state` y lo devuelve durante rollback.
- Backups MCP: `sharedCredentialState.legacyBackupPattern: dotSuffix` reconoce
  siblings `<entry>.<sufijo-no-vacio>`. Se clasifican como credenciales,
  permanecen fuera de transferencias y se preservan por la misma operacion
  `preserve-shared-credential` usada para objetos MCP activos. No se leen,
  copian, fusionan ni activan. Los validadores rechazan cualquier solapamiento
  de este namespace con otra declaracion.
- Adapter Codex: `shell_snapshots/` y `thread-writer-locks/` pasan a sesion;
  `.sandbox_migration`, `cache/`, `models_cache.json` y `version.json` pasan a
  runtime reconstruible; los backups `.credentials.json.*` y
  `mcp-oauth-locks.*` usan la frontera de credencial compartida. Permanecen
  deliberadamente `unknown` `.personality_migration`, `.tmp`, `tmp`, los dos
  `config.toml.bak-*` observados y `gpt-5.5-no-intermediary-updates.md`.
- Pruebas sinteticas: el ciclo rojo expuso campos ausentes en schema/adapter.
  Las pruebas focalizadas verdes cubren validacion y separacion de rutas,
  dry-run sin writes, apply por rename, journal, rollback, exclusion/rechazo de
  transferencia, reconocimiento de `doctor` y una fixture con las 14 rutas que
  conserva exactamente las seis ambiguas como `unknown`.
- Validacion de cierre: schema/adapter 34/34, overlay 18/18, migracion 38/38,
  transferencia 19/19 y suite Bash completa 291/291; 17/17 adapters validos.
  Tambien pasan sintaxis Bash, parseo JSON, documentacion y `git diff --check`.
  El gate de cobertura termina antes de instrumentar porque falta `bashcov`.
  PowerShell/Pester 5.1, Windows, macOS y ShellCheck no estan disponibles en
  este host; no se instalaron dependencias y no se declaran ejecutados.
- Seguridad y estado real: no se repitio el G5, no se accedio a
  `codex/luis`, `codex/vivi`, `~/.codex` ni a ningun valor/target de credencial.
  No hubo logout, refresh, revoke, autenticacion, copia, move, borrado o
  regeneracion real. El siguiente gate es otro G5 explicitamente autorizado;
  aun debe fallar cerrado si los seis residuos permanecen. G9 y launch/login
  reales siguen separados.

### 2026-08-23 — preservacion transaccional y dry-run de perfiles excepto `codex/tienda`

- Alcance aprobado: con `codex/tienda` activo, corregir primero el riesgo
  descubierto
  en el plan real de Luis y despues ejecutar `migrate --dry-run` sobre Luis y
  los otros perfiles Codex excepto `codex/tienda`. Quedaron excluidos apply,
  launch, cierre o migracion de `codex/tienda`, `--prefer-profile`, lectura de
  credenciales, login/logout/refresh/revoke, consumidores, instalaciones y
  operaciones Git.
- Riesgo corregido: el plan anterior podia omitir una base SQLite ya existente
  en el root compartido y a la vez mover sidecars ausentes desde un perfil
  legacy. Esa combinacion podia formar una familia transaccional inconsistente.
  `thread-writer-locks/` tambien era estado volatil que no debia fusionarse con
  otro escritor activo.
- Contrato nuevo: `normalState.migrationPreservePaths` es una subclasificacion
  opcional y exclusiva de migracion. Cada ruta debe ser segura y pertenecer
  exactamente a `sharedPaths` o `sessionPaths`; no introduce estado ni cambia
  el runtime. El objeto legacy se mueve completo por rename del mismo volumen a
  `.inactive/migrations/<adapter>/<profile>/profile-state/`, queda journalizado
  como `preserve-profile-state` y vuelve a su ubicacion original en rollback.
- Adapter Codex: las seis familias SQLite exactas —archivo `.sqlite` y
  sidecars `-shm`/`-wal`— y `thread-writer-locks/` conservan su declaracion de
  estado de sesion para schema v2, pero sus instancias legacy se preservan
  inactivas. No se comparan, deduplican, fusionan ni activan automaticamente.
  Sesiones individuales, history, snapshots, configuracion, plugins y skills
  conservan la politica ordinaria de merge.
- Implementacion: schema y validadores Bash/PowerShell aceptan y restringen el
  campo; ambos migradores clasifican, planean, reportan, ejecutan y revierten
  `preserve-profile-state` con el mismo root inactivo y protecciones de volumen,
  traversal, links y destinos preexistentes. Runtime, launchers, auth principal
  y store MCP no cambiaron.
- Pruebas sinteticas: schema/migracion focalizadas pasan 78/78. Cubren field
  valido, traversal y rutas no declaradas; dry-run de una familia SQLite sin
  writes; apply que conserva SQLite/sidecars/locks inactivos; journal y rollback
  que los devuelve al legacy. La suite Bash completa pasa 297/297, los adapters
  17/17 y la documentacion valida. Sintaxis Bash, JSON y `git diff --check`
  pasan. Cobertura se intento y termino antes de instrumentar porque falta
  `bashcov`; no se instalaron dependencias. PowerShell/Pester, Windows, macOS,
  ShellCheck no estan disponibles y no se declaran ejecutados.
- G5 real protegido: se ejecuto primero Luis y despues los otros catorce
  perfiles Codex autorizados, siempre con `--dry-run --preserve-unknown`, sin
  `--prefer-profile`; `codex/tienda` quedo excluido. Los quince comandos
  terminaron con codigo cero y produjeron planes completos. Cada plan incluyo una credencial
  principal por rename, preservacion transaccional, preservacion MCP/runtime
  segun los objetos presentes y preservacion explicita de los residuos
  desconocidos observados.
- Postflight real: para los quince perfiles, un snapshot estructural completo y
  la metadata de filesystem de `auth.json` coincidieron antes/despues. No se
  abrio contenido de autenticacion ni se imprimieron nombres privados de
  sesiones, targets, IDs o hashes. No se crearon `auth/`, `.profile.json`,
  journal, lock, rollback, recuperacion inactiva ni store MCP. `~/.codex` y
  `codex/tienda` no fueron modificados por el migrador. El contenedor previo y
  vacio `.inactive/codex/` permanecio como estaba; no aparecio un subtree
  `.inactive/migrations/`.
- Estado en ese cierre: el gate read-only solicitado quedo cerrado. Se dejo
  pendiente un preflight especifico de la sesion `codex/tienda` antes de aplicar
  solamente Luis. Launch de Luis, migracion de los otros perfiles y
  `codex/tienda` siguieron siendo decisiones posteriores.

### 2026-08-23 — G9 real y launch controlado de `codex/luis`

- Alcance aprobado: identificar expresamente la sesion activa como
  `codex/tienda`, demostrar que no solapaba los destinos del apply, migrar solo
  `codex/luis` con `--preserve-unknown` y sin `--prefer-profile`, verificar el
  resultado, ejecutar un launch real controlado sin prompts y actualizar las
  bitacoras. Quedaron fuera otros perfiles, consumidores, instalaciones y Git.
- Preflight real: el primer sondeo dentro del sandbox no podia observar los
  procesos Codex del host y se descarto como evidencia. El preflight repetido
  fuera del sandbox confirmo que el `CODEX_HOME` efectivo correspondia a
  `codex/tienda`, que era un perfil legacy regular distinto de Luis y que tres
  procesos activos usaban esa raiz. No habia procesos con el environment de
  Luis, overrides SQLite, enlaces, hardlinks, descriptores abiertos ni cwd de
  tienda hacia Luis, `~/.codex` o la recuperacion inactiva. No se mostraron
  rutas, argumentos, IDs ni contenido de archivos.
- Apply: `nini-agents migrate codex/luis --preserve-unknown` se ejecuto fuera
  del sandbox y termino con codigo cero. El journal completo registro 339
  operaciones: una `move-credential`, cuatro
  `preserve-shared-credential`, cuatro `preserve-runtime-state`, diecinueve
  `preserve-profile-state`, seis `preserve-unknown`, 235 `merge-move`, sesenta
  y cuatro `remove-duplicate`, cinco `skip-conflict` y una `write-metadata`.
  Quedaron 334 operaciones `done` y cinco `skipped`, sin fallos ni pendientes.
- Postflight previo al launch: `auth.json` desaparecio de la raiz legacy y el
  mismo objeto de filesystem aparecio bajo `auth/auth.json`, conservando
  dispositivo, inode, link count uno, modo, tamano y mtime. `.profile.json` es
  schema v2 para Codex/accountOverlay; el journal quedo `completed`; no quedaron
  lock, temporal ni rollback; y las recuperaciones `shared-credentials`,
  `runtime-state`, `profile-state` y `unknown-state` quedaron regulares. El
  migrador no creo `.runtime` ni inicializo el store MCP.
- Launch: los smokes capturados de version y `login status` terminaron con
  codigo cero. El motor construyo `.runtime`, enlazo su `auth.json` al archivo
  del perfil e inicializo y enlazo el store MCP compartido. Despues se mantuvo
  la interfaz real activa durante ocho segundos en un pseudo-terminal con la
  pantalla suprimida, no se envio ningun prompt y se cerro normalmente con
  `Ctrl-C` y codigo cero.
- Efecto observado de upstream: hasta los smokes no interactivos la metadata de
  filesystem de la credencial permanecio identica. Durante la interfaz Codex
  escribio el mismo archivo: dispositivo, inode, link count y modo siguieron
  iguales, mientras tamano y mtime cambiaron. No se leyo ni comparo contenido,
  por lo que no se atribuye la escritura a refresh, normalizacion u otra causa.
  No quedo ningun proceso Luis activo. `codex/tienda` permanecio legacy y la
  metadata de filesystem de su credencial no cambio.
- Estado: el canary Luis ya esta migrado a schema v2 y el launch con el motor
  nuevo quedo demostrado en este host Linux. Los cinco conflictos omitidos
  conservaron la version existente del root compartido; no se uso
  `--prefer-profile`. Los otros catorce perfiles y `codex/tienda` siguen sin
  apply. PowerShell, Windows y macOS no fueron probados en este gate.

### 2026-08-23 — incidente durante el apply masivo de perfiles Codex

- Alcance autorizado: continuar la migracion protegida de los perfiles Codex
  restantes con `--preserve-unknown`, sin `--prefer-profile`, instalar sus
  wrappers Nini y hacer smokes controlados. `codex/tienda` quedo expresamente
  excluido por ser la sesion activa. La recuperacion de `codex/amigo` se separo
  del resto: debe volver a layout legacy y recibir solo un dry-run, sin apply ni
  cambio de wrapper.
- Avance confirmado antes del incidente: `codex/abejita` completo apply,
  postflight, wrapper y smokes. No se atribuye ese resultado a los otros
  perfiles del lote.
- Incidente de `codex/amigo`: `migration_journal_write` reconstruia todo el
  arreglo de operaciones despues de cada paso mediante invocaciones repetidas
  de `jq`. El costo era cuadratico y, con el plan grande de Amigo, la
  serializacion termino excediendo `ARG_MAX`. La escritura no protegia el
  journal anterior ante ese error y publico un journal vacio desde el temporal.
  La interrupcion del comando supervisor tampoco termino el proceso real fuera
  del sandbox; ese proceso siguio moviendo estado hasta que fue localizado y
  detenido expresamente.
- Evidencia congelada para recuperacion: sin abrir ni comparar valores de
  credenciales, el postflight estructural registra la credencial y 32
  preservaciones ya movidas, 285 `merge-move` ejecutados y 16 slots regulares
  de rollback. Esos conteos sustituyen las estimaciones anteriores; no debe
  intentarse launch, un nuevo apply ni una reconstruccion por intuicion mientras
  el perfil permanezca parcial.
- Fix local del journal: la serializacion completa usa un unico `jq` en modo
  streaming por escritura, y el temporal solo reemplaza el journal vigente si
  `jq` termina correctamente. Ante error se conserva el journal previo y se
  elimina el temporal fallido. Se mantienen el journal por operacion y el
  rollback; no se omite ni se difiere evidencia transaccional.
- Estado al registrar este checkpoint: `codex/amigo` aun no esta recuperado ni
  migrado; su siguiente operacion autorizada es la recuperacion fail-closed y,
  si la verificacion estructural coincide, unicamente
  `migrate --dry-run --preserve-unknown`. Los otros once perfiles del lote aun
  estan pendientes de apply normal. `codex/tienda` permanece excluido. No se
  afirma que ninguna de esas doce operaciones pendientes haya terminado.
- Issue separada de rendimiento: el preflight de `launch` con el motor nuevo
  tarda aproximadamente siete segundos en la validacion repetida del adapter,
  incluso antes de entregar control a Codex. No bloqueo los smokes ya
  completados, pero debe perfilarse y optimizarse despues de cerrar la migracion
  sin debilitar la validacion fail-closed.

### 2026-08-23 — recuperacion de Amigo y cierre del lote excepto Tienda

- Recuperacion real de `codex/amigo`: con el proceso viejo ya detenido, se
  restauraron en orden inverso y contra la evidencia congelada los 16 slots de
  rollback, 285 `merge-move`, 32 preservaciones y la credencial principal. El
  perfil volvio al layout legacy y la identidad de filesystem de la credencial
  quedo preservada. No se abrio ni comparo su contenido.
- Verificacion de Amigo: se ejecuto una sola vez
  `migrate codex/amigo --dry-run --preserve-unknown`. Termino con codigo cero y
  un plan de 500 operaciones. El arbol estructural y la metadata de la
  credencial coincidieron antes y despues; el dry-run no creo metadata v2,
  `auth/`, journal, lock, rollback ni recuperacion inactiva. Amigo queda legacy,
  sin apply y con su wrapper anterior; no debe presentarse como migrado.
- Apply secuencial restante: `codex/ari`, `codex/diego`, `codex/kitsune`,
  `codex/magic`, `codex/mari`, `codex/nexo`, `codex/nico`, `codex/omega`,
  `codex/pro`, `codex/sam` y `codex/willy` completaron migracion schema v2 con
  `--preserve-unknown` y sin `--prefer-profile`. Sus journals terminaron
  `completed` y registraron cero operaciones `failed`.
- Totales de journal por perfil: Ari 317, Diego 560, Kitsune 77, Magic 432,
  Mari 294, Nexo 319, Nico 1776, Omega 53, Pro 26, Sam 97 y Willy 65; en total,
  4016 operaciones. Los conteos incluyen las operaciones `skipped` conservadas
  por la politica de conflicto y no implican que se haya preferido el perfil.
- Lanzamiento: los once perfiles recibieron su wrapper Nini, `login status`
  confirmo estado autenticado y cada TUI completo el smoke controlado. Estos
  smokes prueban el flujo observado en este host Linux; PowerShell, Windows y
  macOS no se verificaron.
- Exclusiones y estado final: `codex/tienda` permanecio activo, legacy e
  intacto durante todo el lote. `codex/amigo` queda deliberadamente en estado
  dry-run-only, legacy y sin wrapper Nini. El cierre no autoriza aplicar ninguno
  de esos dos perfiles ni resolver los conflictos omitidos de Luis.
- Rendimiento pendiente: el fix streaming del journal permitio conservar el
  journal por operacion sin el comportamiento cuadratico del incidente. La
  validacion previa de `launch`, observada en aproximadamente siete segundos,
  permanece como issue separada para una etapa posterior.

### 2026-08-23 — apply final de Amigo y handoff de Tienda

- Alcance posterior autorizado: migrar solamente `codex/amigo`, instalar su
  wrapper Nini conservando la seleccion de navegador y verificar login, runtime
  y TUI. `codex/tienda`, los otros perfiles, `--prefer-profile`, codigo y
  documentacion quedaron fuera de ese apply.
- Preflight de Amigo: despues de consolidar los otros perfiles se repitio fuera
  del sandbox el guard de procesos, la revision estructural metadata-only y el
  dry-run. Amigo estaba legacy, inactivo, con credencial regular de un solo
  enlace, wrapper legacy que exportaba Microsoft Edge y sin artefactos de
  control o recuperacion. El dry-run fresco termino con codigo cero y no cambio
  el arbol ni la metadata de la credencial.
- Plan aplicado: 500 operaciones con `--preserve-unknown` y sin
  `--prefer-profile`: 213 `merge-move`, 246 duplicados, seis conflictos
  omitidos, una credencial, tres preservaciones de credencial compartida,
  cuatro de runtime, 17 de estado de perfil, ocho unknown, un link omitido y
  una escritura de metadata.
- Resultado: el journal termino `completed`, con 493 operaciones `done`, siete
  `skipped` y cero `failed`. La credencial paso a `auth/auth.json` conservando
  su identidad de filesystem; no quedaron lock ni rollback. No se abrio ni se
  imprimio contenido de autenticacion.
- Wrapper y launch: `codex-amigo` ahora ejecuta
  `~/.local/bin/nini-agents launch codex/amigo` y conserva
  `BROWSER=/usr/bin/microsoft-edge`. `login status` confirmo autenticacion, el
  runtime enlazo la credencial del perfil, el smoke TUI paso y no quedaron
  procesos residuales ni cambios de metadata de la credencial.
- Estado de continuidad: `codex/tienda` es el unico perfil Codex pendiente de
  migracion. Otro agente debe ejecutarse desde un perfil schema v2 ya migrado,
  esperar a que esta sesion Tienda y cualquier proceso con su `CODEX_HOME`
  terminen, y repetir preflight y dry-run reales. No debe inferir el plan desde
  otros perfiles ni aplicar sin una autorizacion explicita posterior.
- Procedimiento Tienda: verificar metadata-only y ausencia de control/recovery;
  ejecutar `migrate codex/tienda --dry-run --preserve-unknown`; informar el
  plan exacto y obtener autorizacion; repetir el guard y aplicar sin
  `--prefer-profile`; verificar journal, identidad de credencial, metadata v2 y
  recuperacion; finalmente cambiar el wrapper conservando exactamente
  `BROWSER=/usr/bin/brave-browser` y probar `login status`, runtime y TUI. No
  ejecutar logout, refresh, revoke ni leer valores de autenticacion.

### 2026-08-23 — G9 final de Tienda y cierre de migracion Codex

- Alcance aprobado: desde un agente ejecutado con otro perfil schema v2,
  realizar el G5 read-only y despues un G9 separado para migrar solamente
  `codex/tienda`, cambiar su wrapper conservando Brave, validar version, login,
  runtime y TUI, y actualizar las bitacoras. Quedaron fuera `--prefer-profile`,
  otros perfiles, limpieza de conflictos o recuperaciones, logout, refresh,
  revoke, codigo, consumidores y operaciones Git.
- Preflight G5: la sesion del agente no pertenecia a Tienda. Un guard inicial
  excesivamente amplio encontro un proceso del usuario cuyo entorno no era
  legible, pero el diagnostico contractual mostro que no correspondia a ningun
  binario Codex declarado; 97 procesos eran atribuibles y ninguno apuntaba al
  `CODEX_HOME` de Tienda. El perfil era legacy regular, `auth.json` era regular
  con link count uno y no existian metadata v2, destino de credencial, journal,
  lock, rollback ni recuperacion previa.
- Dry-run G5: termino con codigo cero y 1144 operaciones: una
  `move-credential`, tres `preserve-shared-credential`, cuatro
  `preserve-runtime-state`, 15 `preserve-profile-state`, ocho
  `preserve-unknown`, 887 `merge-move`, 218 `remove-duplicate`, seis
  `skip-conflict`, un `skip-link` y una `write-metadata`. No hubo reemplazos ni
  `--prefer-profile`; el arbol estructural y la metadata de la credencial
  coincidieron antes y despues, sin artefactos creados.
- Apply G9: el guard y un dry-run frescos repitieron exactamente el plan antes
  de escribir. El journal termino `completed` con 1137 operaciones `done`, siete
  `skipped`, cero `failed` y cero pendientes. `auth.json` dejo la raiz legacy,
  la operacion de credencial quedo `done` bajo la verificacion de identidad del
  migrador y `auth/auth.json` quedo regular con link count uno. `.profile.json`
  declara schema v2/accountOverlay; las recuperaciones `shared-credentials`,
  `runtime-state`, `profile-state` y `unknown-state` estan presentes; no quedaron
  lock, rollback, temporal ni runtime prematuro.
- Anomalia de supervision: el proceso que encapsulaba el apply devolvio no cero
  despues de que el journal ya estaba `completed`. El postflight inmediato e
  independiente verifico todos los invariantes anteriores y una invocacion
  posterior de `migrate` termino como no-op por schema v2. No se repitio el
  apply y no se atribuye la causa del retorno al motor sin evidencia adicional.
- Wrapper y smokes: `codex-tienda` ejecuta el launcher Nini y conserva
  exactamente `BROWSER=/usr/bin/brave-browser`. `--version` y `login status`
  terminaron con codigo cero; el runtime reconstruido enlaza `auth.json` al
  archivo del perfil. Dos TUI se mantuvieron ocho segundos sin prompts y se
  cerraron con `Ctrl-C`; el segundo registro codigo cero. La metadata de la
  credencial fue identica antes y despues del smoke medido y no quedaron
  procesos con el entorno de Tienda.
- Seguridad y datos: no se abrio, parseo, imprimio ni comparo contenido de
  autenticacion; no hubo logout, refresh, revoke ni reautenticacion solicitada.
  El apply real modifico el perfil, el estado compartido y las recuperaciones
  conforme al journal; el wrapper activo tambien cambio. No se borraron las
  recuperaciones inactivas ni se resolvieron los seis conflictos omitidos.
- Validacion documental: `python3 scripts/validate-docs.py` y
  `git diff --check` pasaron. Las advertencias de normalizacion CRLF proceden de
  archivos PowerShell ya modificados en el worktree y no cambiaron durante este
  cierre.
- Estado final: los quince perfiles Codex estan migrados a schema v2, usan
  wrappers Nini y pasaron smokes en este host Linux. PowerShell, Windows y macOS
  no fueron verificados. Permanecen como gates separados los cinco conflictos
  historicos de Luis, la latencia previa a `launch`, el comando publico de
  movimiento, las mutaciones JSON y las migraciones de MultiCLI AI y
  Codexporter.

### 2026-08-24 — launcher rapido y permisos Codex compartidos

- Alcance aprobado: optimizar el launcher posterior a la migracion de todas las
  cuentas y agregar un comando general de permisos para Codex. Quedaron fuera
  accesos o cambios a perfiles y credenciales reales, instalaciones,
  publicaciones, Git y migraciones adicionales.
- Causa: el launch schema v2 ejecutaba el validador semantico completo y volvia
  a consultar el mismo adapter mediante cientos de procesos `jq` antes de
  entregar control a Codex. El fixture caliente reprodujo 388 invocaciones; en
  uso real se habian observado aproximadamente 7--10 s de espera frente a
  0.03--0.04 s del binario directo.
- Cambio: Bash carga en una sola pasada NUL-delimitada el contrato consumido por
  launch y runtime; PowerShell usa un unico `ConvertFrom-Json`. El overlay
  vigente se comprueba antes del lock y se vuelve a comprobar dentro de el.
  Los campos ya cargados se reutilizan durante descubrimiento, expansion,
  manifest y dispatch.
- Frontera de seguridad: launch sigue rechazando JSON ilegible, IDs,
  estrategias y binarios basicos inconsistentes y valida traversal justo antes
  de cada join de filesystem. La validacion semantica exhaustiva no se elimino:
  permanece en creacion y mutaciones, `permissions`, `doctor` y los validadores
  del repositorio. Una prueba muta una ruta usada y demuestra rechazo antes de
  escapar del root; otra demuestra que `doctor` detecta una ruta invalida no
  usada por launch.
- Resultado medido: el mismo fixture Codex caliente paso de 388 a dos procesos
  `jq` (99.5 % menos) y midio 0.08 s. La medicion no relanzo ninguna cuenta ni
  proceso real.
- Permisos: `nini-agents permissions show` y
  `nini-agents permissions set <read-only|workspace|full-access>` operan sobre
  el `config.toml` normal compartido por los perfiles Codex account-overlay no
  aislados. Los presets
  escriben `:read-only`/`on-request`, `:workspace`/`on-request` o
  `:danger-full-access`/`never`; eliminan overrides sandbox legacy, preservan
  configuracion no relacionada, rechazan links y claves top-level duplicadas,
  validan un staging con Codex y publican por reemplazo atomico. En POSIX el
  archivo queda `0600`.
- Semantica de sesion: el archivo compartido puede guardarse mientras existen
  sesiones abiertas, pero define el default de sesiones nuevas. Una seleccion
  hecha dentro de una sesion Codex activa sigue siendo local a ese proceso
  hasta reiniciarlo. El comando no abre ni modifica `auth.json`, tokens ni el
  store MCP.
- Validacion: suite Bash 310/310, pruebas focalizadas 74/74, 17/17 adapters,
  sintaxis Bash, documentacion y `git diff --check`. Un home sintetico paso
  `codex --strict-config --version` con Codex CLI 0.147.0. El runner completo
  tambien ejercito builds y uninstalls hermeticos en temporales; no instalo,
  desinstalo ni publico nada real. El gate de cobertura no inicio porque falta
  `bashcov`. PowerShell/Pester, Windows y macOS no estan disponibles en este
  host y permanecen sin ejecucion.

### 2026-08-24 — handoff para migracion completa de MultiCLI AI

- Intencion del usuario: el siguiente trabajo debe migrar completamente la
  aplicacion MultiCLI AI para que Nini Agents sea su unico motor. No se considera
  suficiente seguir usando indefinidamente el shim ni limitarse a renombrar el
  comando.
- Estado base: `main` local esta en `ad9630c99648`, un commit delante de
  `origin/main`. Ese commit agrupa el motor transaccional y sus protecciones,
  los quince perfiles Codex migrados y probados en Linux, el launcher rapido,
  permisos compartidos, pruebas y documentacion. No fue publicado, instalado
  ni convertido en release como parte de este cierre.
- Compatibilidad existente: `multi-cli` es un shim delgado que delega a
  `nini-agents`, de modo que el consumidor puede atravesar transitoriamente el
  motor nuevo sin haber completado su propia migracion. El inventario vigente
  de MultiCLI AI indica invocacion del shim y descubrimiento propio por
  filesystem y texto; se debe verificar de nuevo contra su worktree antes de
  disenar cambios.
- Brechas conocidas: JSON v1 solo cubre consultas read-only; mutaciones y
  `doctor --deep` rechazan JSON, no existe un dispatch publico de movimiento y
  launch no tiene todavia una ejecucion machine-safe con stdout limpio para el
  flujo `codex app-server`. No presentar estas superficies como implementadas.
- Frontera deseada: MultiCLI AI debe invocar directamente `nini-agents`, usar
  contratos versionados y delegar al motor descubrimiento, perfiles,
  credenciales, ownership y mutaciones. La GUI no debe leer secretos, resolver
  rutas privadas ni decidir por parsing de salida humana.
- UX que se conserva en el consumidor: deteccion y apertura de terminales,
  Hyper, titulos `perfil · proyecto`, navegador y enfoque best effort de
  ventanas. La migracion cambia el backend invocado, no traslada esas
  responsabilidades visuales al launcher.
- Procedimiento para reanudar: leer las reglas de ambos repositorios; obtener
  aprobacion read-only para auditar el worktree real de MultiCLI AI; inventariar
  cada comando, parser, acceso a filesystem y prueba; construir una matriz de
  capacidades contra el contrato Nini; y separar las brechas que requieren G2
  en el motor de las que requieren G4 en el consumidor.
- Implementacion futura: usar una branch dedicada, fixtures y homes temporales;
  agregar primero los contratos machine-safe faltantes con paridad Bash y
  PowerShell; despues portar la GUI sin duplicar logica del motor. Definir y
  probar rollback antes del corte y conservar el shim mientras existan
  consumidores legacy comprobados.
- Gates de cierre: pruebas contractuales y de redaccion de secretos, suite del
  motor aplicable, validacion del repositorio Flutter, smoke controlado de
  terminal y `codex app-server`, preservacion de Hyper/titulos, y rollback sin
  tocar credenciales reales durante pruebas sinteticas. Registrar Windows,
  macOS o PowerShell como no verificados si no se ejecutan.
- Coordinacion: esta prioridad no autoriza migrar Codexporter en el mismo delta.
  MultiCLI AI puede cerrar su corte con evidencia propia, pero la Etapa H global
  no se declara completa hasta que Codexporter tambien consuma el motor comun.
- Autorizacion de esta entrada: solo actualizar las dos bitacoras. Quedaron
  fuera cambios en MultiCLI AI o Nini Agents, lectura nueva de perfiles reales,
  instalaciones, releases, push, commits y retiro de compatibilidad.

### 2026-08-24 — ENG-02A: JSON v1 para crear y renombrar perfiles

- Alcance aprobado: ampliar exclusivamente `new` y `rename` con respuestas JSON
  v1 equivalentes en Bash y PowerShell, congelar schema/pruebas/documentacion y
  actualizar la bitacora de Nini Hub. Quedaron fuera delete, exec, codigo
  Flutter, SQLite, perfiles o credenciales reales, instalaciones, Git y
  publicacion.
- Contrato: exito devuelve `state: applied` y un resumen publico con `tool`,
  `name`, `type` y `schemaVersion`; rename agrega la direccion publica `from`.
  Los rechazos usan codigos estables y `error.details.state` con
  `not_applied` o `partially_applied`. No se serializan paths, `profileId`,
  nombres o contenido de credenciales ni detalles privados de runtime.
- Implementacion: ambos entrypoints siguen llamando los owners vigentes
  `cmd_new`/`cmd_rename` y `New-Profile`/`Rename-Profile`; JSON solo agrega
  preflight machine-safe, supresion de salida humana, inspeccion estructural
  posterior y envelope. El schema v1 fija las formas de exito y los estados de
  fallo sin cambiar el envelope de consultas o movimiento.
- Incidente encontrado con fixture: el rename Bash movia el directorio y luego
  terminaba por `set -e` cuando `remove_shortcut()` no encontraba un desktop
  shortcut de un adapter CLI. Tras diagnostico y ampliacion explicita, se agrego
  un retorno exitoso al final de esa limpieza idempotente. No cambia targets ni
  elimina archivos adicionales; permite completar alias y el mensaje humano.
- Seguridad: todas las mutaciones de prueba usaron `HOME`, `MULTICLI_HOME` y
  tools temporales con el adapter Codex publico. No se abrieron perfiles,
  credenciales, stores o procesos reales y no hubo logout, revoke, refresh,
  instalacion, stage, commit o push.
- Evidencia Linux: 8/8 en `json_mutations.bats`, 11/11 en `json_cli.bats` y
  12/12 en la suite de seguridad de perfiles. Cuatro respuestas de exito/rechazo
  validaron contra `schema/cli-output.schema.json`. Overlay paso 22/23; el unico
  fallo es el protocolo de titulo Hyper de cambios concurrentes y no participa
  en new/rename. Sintaxis Bash, parseo del schema, validacion documental y
  `git diff --check` del alcance pasaron.
- Gates abiertos: PowerShell/Pester y Windows no estan disponibles en este host;
  los tests equivalentes quedaron implementados pero no ejecutados. El gate de
  cobertura Bash no inicio porque `bashcov` no esta instalado. ENG-02A queda
  implementada y validada en Bash, pero no se declara cerrada multiplataforma.
- Siguiente orden: cerrar esos gates o registrar evidencia CI de este delta;
  solo despues delimitar ENG-02B para delete JSON con confirmacion explicita.

### 2026-08-24 — validacion CI aislada de ENG-02A

- Alcance aprobado: aislar exactamente ENG-02A sobre `ad9630c`, validar con
  ramas/commits temporales y PR borrador, actualizar los relevos y detenerse
  ante cualquier fix. No se autorizo mezclar movimiento remoto, modificar
  `main`, corregir la base, mergear, instalar localmente, publicar o limpiar
  las refs remotas.
- Aislamiento: una copia temporal creo la base
  `validation/eng-02a-base-ad9630c` y el delta `a155613` de nueve archivos. El
  tip `94c1ef1` agrega solo un commit vacio para reintentar el evento. PR
  borrador `#1`; `origin/main` permanece en `293c48d` y el worktree original no
  fue stageado ni modificado por el aislamiento.
- Contenido exacto: helpers JSON Bash/PowerShell, dispatch `new`/`rename`,
  `remove_shortcut()` idempotente, schema, dos suites de mutaciones y
  documentacion contractual. Busquedas y diff excluyeron `remote-move`,
  devices, launch/runtime, delete y exec.
- Validacion local aislada: 31/31 pruebas dirigidas exitosas — 8 mutaciones, 11
  contrato JSON y 12 seguridad — mas sintaxis Bash, parseo JSON Schema,
  `validate-docs.py` y `git diff --check`.
- CI manual `32741318583` sobre `94c1ef1`: las siete pruebas nuevas pasaron en
  Windows PowerShell 5.1 con Pester 3.4.0. Tambien pasaron PSScriptAnalyzer,
  install smoke Windows, install smoke Ubuntu, shellcheck, Bats Ubuntu,
  actionlint y metadata de release.
- Gate Pester global: 419 passed, 18 failed, 0 skipped/pending/inconclusive. La
  primera falla aparecio despues de las siete mutaciones en
  `tests/Migration.Tests.ps1:286`; la cobertura PowerShell no se ejecuto. Los
  fallos restantes estan fuera de los nueve archivos ENG-02A y no fueron
  corregidos ni atribuidos al contrato de mutaciones.
- Gate Bash ampliado: 313/332 lineas, 94,28 %. Los 19 misses pertenecen al
  delta `origin/main..ad9630c` en permisos, migracion, runtime, transfer y
  entrypoint. Los rangos exactos ENG-02A — `lib/cli-json.sh:32-39` y
  `nini-agents:1213,1736-1870,2304-2305,2414-2427` — no aparecen entre los
  misses. Esta evidencia no reemplaza formalmente el gate con baseline
  `ad9630c`.
- Incidente macOS separado: install smoke y Bats fallaron al parsear
  `lib/migration.sh:195` bajo Bash 3.2; `git blame` ubica esa linea en
  `ad9630c`. No cruza ENG-02A y requiere diagnostico/fix propio.
- Resultado: ENG-02A sigue `validating`. La siguiente accion necesita un nuevo
  alcance para ejecutar una harness temporal con baseline `ad9630c` y permitir
  cobertura PowerShell aun cuando la suite base falle, o para corregir primero
  los incidentes de la base. No iniciar ENG-02B mientras falte ese gate.

### 2026-08-24 — cobertura exacta aislada de ENG-02A

- Alcance aprobado `VALID-ENG-02A-B`: modificar solo el workflow de la rama
  temporal, fijar `ad9630c` como baseline Bash/PowerShell y ejecutar cobertura
  PowerShell aunque la suite Pester base falle. El commit `b7790c9` cambio tres
  lineas de `.github/workflows/ci.yml`; `actionlint` paso en CI `32743230689`.
- Primer resultado exacto: Bash changed-line paso 100 % (4/4). PowerShell se
  ejecuto y encontro 33,33 % (1/3), con misses en
  `lib/MultiCli.Json.psm1:41-42`. `MultiCli.Json.psm1` obtuvo 91,67 % (33/36).
- Causa observada: `JsonMutations.Tests.ps1` prueba los entrypoints mediante
  procesos hijos, que Pester 3.4 no contabiliza en el runspace de cobertura.
  `ModuleFunctions.Tests.ps1`, owner de las llamadas in-process, importaba los
  otros modulos pero no `MultiCli.Json.psm1` ni llamaba el helper de error.
- Alcance aprobado `VALID-ENG-02A-C`: agregar solo una prueba in-process, volver
  a ejecutar CI y actualizar los cuatro relevos. El commit test-only `879d461`
  importa el modulo JSON y verifica schema, command, `ok`, `data`, codigo,
  mensaje y `error.details.state`; no cambia codigo productivo ni usa perfiles,
  filesystem o credenciales.
- CI `32744574564`: la prueba nueva paso. La suite completa termino 420 passed,
  18 failed y cero skipped/pending/inconclusive. Bash changed-line paso 100 %
  (4/4); PowerShell changed-line paso 100 % (3/3) y
  `MultiCli.Json.psm1` quedo 100 % (36/36).
- El job PowerShell global continua rojo: su subconjunto de cobertura tuvo 283
  passed, 17 failed y 502 comandos inesperadamente no cubiertos en modulos de
  la base. Esta condicion no invalida la cobertura exacta ENG-02A, pero el gate
  de cierre tambien exige `tests/run-pester.ps1 -CI` sin fallos.
- macOS repitio el parse error Bash 3.2 en `lib/migration.sh:195`, perteneciente
  a `ad9630c`; install smoke y Bats macOS siguen como `separate_fix`.
- Resultado: los dos gates de cobertura exacta de ENG-02A estan cerrados. La
  subfraccion permanece `validating` exclusivamente porque Pester global tiene
  18 fallos base. Su diagnostico/fix necesita alcance propio; no iniciar
  ENG-02B, merge, release ni publicacion de `main` mientras falte esa puerta.

### 2026-08-24 — ENG-02B: delete JSON seguro para Nini Hub

- Decision posterior: el usuario autorizo continuar ENG-02B sin perseguir en
  esta fraccion los 18 fallos Pester ni el incidente Bash 3.2 ya atribuidos a
  la base. Esos gates permanecen visibles como `separate_fix`; no se declararon
  corregidos ni se debilitaron sus suites.
- Alcance ejecutado: sobre el tip aislado `879d461` se creo
  `validation/eng-02b` y el commit `c36a229`. Se modificaron solo los entrypoints
  Bash/PowerShell, schema JSON v1, pruebas de mutaciones/contrato/containment,
  README y contrato JSON. No se copiaron estos cambios sobre el worktree
  concurrente original ni se modificaron perfiles, credenciales, Flutter,
  SQLite, launch, app-server, instalacion, release o `main`.
- Contrato: `nini-agents --json delete <tool>/<profile> --confirm
  <tool>/<profile>` es no interactivo y exige que la confirmacion coincida
  exactamente con el target. Falta, mismatch o identificador invalido devuelve
  exit 2 y `not_applied`; perfil ausente devuelve `profile_not_found` y
  `not_applied`. Una falla despues de iniciar cleanup devuelve exit 6,
  `operation_failed` y el estado conservador `partially_applied`.
- Exito: devuelve `state: applied` y solo la direccion publica `{tool,name}`
  del perfil borrado. No serializa paths, `profileId`, archivos de auth,
  credenciales, hashes, IDs de cuenta ni detalles privados. El flujo humano
  conserva su prompt; solo el wrapper JSON usa el bypass interno despues del
  preflight y de la confirmacion explicita.
- Seguridad y ownership: ambos wrappers reutilizan `cmd_delete` /
  `Remove-Profile`, por lo que credential-store, OS-user cleanup, alias,
  shortcut y borrado siguen perteneciendo al motor. El preflight resuelve la
  ruta contenida antes de operar. Si cleanup puede haber comenzado, el motor no
  promete rollback destructivo y obliga al consumidor a reconciliar mediante
  un `list/status` nuevo.
- Evidencia local: sintaxis Bash, parseo del schema, tres envelopes delete,
  documentacion y `git diff --check` pasaron. Las suites focales terminaron
  35/35; despues de agregar las aserciones finales de identificador y junction,
  sus dos tests dirigidos pasaron 2/2. Todo uso de filesystem y credential store
  ocurrio bajo roots y doubles temporales.
- Unico CI autorizado: `32748238240` sobre `c36a229`. Pasaron actionlint,
  metadata, shellcheck, PSScriptAnalyzer, install smoke Windows/Ubuntu, Bats
  Ubuntu completo y Bash changed-line 100 % (9/9). Los cuatro tests delete
  pasaron en Windows PowerShell 5.1/Pester 3.4.0. El gate de modulos PowerShell
  reporto 100 % (3/3) sobre `MultiCli.Json.psm1`; ENG-02B toca el entrypoint y
  su conducta se cubrio con procesos hijos, fuera de ese instrumentador.
- Deuda separada repetida: Pester total termino 424 passed / 18 failed; los
  cuatro tests ENG-02B pasaron antes de la primera falla. macOS volvio a fallar
  por el parse error de `lib/migration.sh:195` bajo Bash 3.2. No se implemento
  ningun fix para esos incidentes.
- Resultado y continuidad: ENG-02B queda implementada y validada en la rama
  temporal, sin merge ni release. Nini Hub ya puede implementar `PRF-01`
  contra el contrato tipado de `new`/`rename`/`delete`; para uso instalado aun
  falta decidir integracion/publicacion del motor. Exec stdout-clean y launch
  permanecen para un gate posterior.

### 2026-08-24 — ENG-02C e integracion local del motor para Nini Hub

- Alcance aprobado: versionar ENG-02C en la branch aislada existente, portar
  manualmente ENG-02B/C sobre el worktree concurrente de `main`, validar solo
  contratos focalizados y actualizar los relevos. Se excluyeron branch nueva,
  installer, perfiles o credenciales reales, builds, suites amplias, merge,
  push, tag y release.
- Linaje: `validation/eng-02b` avanzo al commit `fc3361f` con los nueve archivos
  exactos de ENG-02C. El checkout principal conserva HEAD `ad9630c` y sus
  cambios concurrentes; los hunks de delete JSON y exec se integraron sin
  stagear, borrar, revertir o commitear ese worktree.
- Antes/despues: el checkout activo carecia del delete machine-safe y del
  transporte requerido por Nini Hub. Ahora `--json delete` exige confirmacion
  exacta y `exec <tool>/<profile> -- <args...>` inicia un foreground
  `accountOverlay/fileOverlay` con stdio limpio, entorno/overlay del adapter y
  propagacion del exit code. `launch` humano y perfiles detached no cambiaron.
- Implementacion: los entrypoints Bash/PowerShell agregan dispatch, ayuda,
  completion y validaciones; `lib/multicli-runtime.sh` reemplaza el wrapper por
  el hijo en machine-exec. El schema JSON fija delete; README,
  `docs/json-cli.md` y `docs/exec-contract.md` congelan los contratos. Las
  pruebas cubren confirmacion, containment, estados parciales y stdio/exit.
- Activacion instalada: `~/.local/bin/nini-agents` ya era un wrapper regular
  hacia el entrypoint del checkout local. No fue reescrito ni reinstalado; al
  apuntar al checkout integrado reporto version
  `1.0.0` y mostro `exec` en ayuda.
- Evidencia Linux sintetica: 92/92 pruebas Bats focalizadas pasaron con la
  variable externa de titulo Hyper retirada; tambien pasaron sintaxis Bash,
  parseo JSON Schema, validacion de 17 adapters, documentacion, metadata de
  release, `git diff --check` y la regresion consumidora de Nini Hub (38/38 mas
  guarda arquitectonica 1/1 y analyze focalizado sin issues).
- Limites: PowerShell/Pester, Windows, macOS, Codex real y credenciales reales
  no se ejecutaron. Los 18 fallos Pester y el parseo Bash 3.2 de la base siguen
  como `separate_fix`. `origin/main` y releases publicados aun no contienen
  ENG-02; esa publicacion pertenece al cutover posterior.

### 2026-08-29 — migracion legacy Codex reducida a estado esencial

- Alcance aprobado: reescribir la migracion por defecto de Codex para rescatar
  principalmente `auth.json`, MCP y skills, investigar el resto del estado
  valioso y eliminar el costo absurdo de fusionar cientos de archivos para un
  solo perfil. Se excluyeron perfiles/credenciales reales, apply o launch real,
  instalaciones, Git, release y cambios destructivos.
- Contrato: `normalState.migrationActivatePaths` es una allowlist declarativa
  opcional y exacta. Cuando existe, solo ese subconjunto shared/session llega al
  merge activo; cada otro objeto normal declarado se renombra completo a
  `profile-state/`. Adapters sin el campo mantienen el comportamiento anterior.
  Schema y validadores Bash/PowerShell exigen rutas seguras ya declaradas.
- Codex activa `config.toml` —incluidas definiciones MCP—, `hooks.json`,
  `AGENTS.md`, `AGENTS.override.md`, `skills/`, `agents/`, `prompts/`,
  `mcp-configs/`, `plugins/` y `rules/`. `auth.json` conserva la transaccion de
  credencial. MCP OAuth legacy permanece inactivo y puede exigir reauth.
- `installation_id`, logs, sesiones, history, archivados, snapshots, indice,
  locks y familias SQLite se preservan completos e inactivos. Una prueba con
  200 rollouts produce una unica operacion superior para `sessions/`, no una
  operacion por archivo; apply verifica que el arbol reaparece completo bajo
  recuperacion y que el journal registra una sola preservacion.
- Evidencia local sintetica: schema+migracion Bash pasaron 85/85 antes del
  refuerzo final; los casos dirigidos posteriores de politica selectiva, apply,
  adapter y overlay tambien pasaron. Pasaron validacion de 17 adapters,
  documentacion, sintaxis Bash/JSON, `git diff --check` y 41/41 pruebas de
  overlay/runtime/performance. PowerShell 5.1/Pester, Windows y macOS no estan
  disponibles en este host y no se declaran ejecutados. `bashcov` tampoco esta
  instalado, por lo que el gate de cobertura no se ejecuto ni se instalaron
  dependencias.

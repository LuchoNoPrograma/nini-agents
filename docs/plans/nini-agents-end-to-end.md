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

1. Leer [AGENTS.md](../../AGENTS.md), este documento y la skill canonica
   aplicable bajo `.agents/skills/`.
2. Revisar `git status`, branch, remotes, base comun y cambios concurrentes sin
   modificar referencias ni archivos.
3. Separar siempre estado existente, direccion aprobada y trabajo pendiente.
4. Registrar aqui el alcance aprobado, decisiones estables, validaciones y
   resultado de cada tramo terminado.
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

- El checkout activo es `main`, alineado con `origin/main`; el tip funcional
  anterior a este cierre documental es `73c9d50`.
- `main` contiene el motor Nini Agents renombrado y conserva los shims de
  compatibilidad. Las Etapas A, B, C y D estan cerradas con evidencia local y
  CI remoto efimero. El tramo aprobado de la Etapa E contiene el protocolo
  transaccional interno y sus pruebas, pero no expone todavia comando publico,
  transporte SSH ni respuesta JSON estable.
- `multi-cli-base` y `origin/multi-cli-base` conservan el upstream puro
  `6efb0d2`.
- `legacy-gui` y `origin/legacy-gui` conservan el snapshot Flutter `7426e98`.
- `origin` apunta al fork publico `LuchoNoPrograma/nini-agents` y
  `multi-cli-upstream` apunta a `Spielewoy/multi-cli`.
- El nucleo interno del movimiento seguro inspirado por el contrato de
  Codexporter esta implementado en Bash y PowerShell. La integracion remota, la
  CLI JSON estable y las migraciones consumidoras siguen pendientes; no deben
  presentarse como funcionalidades implementadas.
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

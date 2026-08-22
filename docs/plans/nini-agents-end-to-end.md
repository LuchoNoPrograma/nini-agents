# Nini Agents: plan maestro y bitacora end-to-end

- Estado del documento: activo
- Fecha de inicio: 2026-08-22
- Base upstream fijada: Multi-CLI
  `6efb0d204d4e690c2e0f5e9c2ee900a3cead6afa`
- Branch de trabajo observada al iniciar: `nini-agents-cli`

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

## Estado inicial comprobado

Al 2026-08-22:

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

Topologia Git objetivo:

| Referencia | Responsabilidad objetivo |
|---|---|
| `main` | Desarrollo y entrega del motor Nini Agents |
| `legacy-gui` | Snapshot estable de la aplicacion Flutter MultiCLI AI |
| `multi-cli-base` | Upstream puro fijado en `6efb0d2` |
| `multi-cli-upstream/main` | Seguimiento del upstream, sin mezclar cambios propios |
| `legacy/main` | Fuente local de la historia Flutter mientras dure la migracion |

La topologia objetivo no describe el estado actual. Crear o mover branches,
reescribir referencias o publicar cambios requiere un alcance Git separado y
aprobado.

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

### Etapa C: portar personalizaciones aprobadas

Objetivo: recuperar comportamientos propios necesarios sin mezclar la aplicacion
Flutter ni portar commits a ciegas.

Personalizaciones candidatas ya aprobadas como direccion:

- Descubrimiento de Codex en `~/.local/bin/codex`.
- Manejo de `rules/` conforme al contrato actual de perfiles y runtime.
- Integracion de titulos con Hyper.

Metodo:

- Comparar historia, contrato y pruebas de cada cambio con `6efb0d2`.
- Identificar el modulo propietario en Bash y PowerShell.
- Portar comportamiento minimo y agregar caracterizacion focalizada.
- Declarar como no probada toda plataforma que no pueda ejecutarse.

Criterios de salida:

- Cada personalizacion tiene origen trazable, owner claro y prueba que falla sin
  el cambio.
- No se ha importado UI Flutter ni dependencia de Codexporter.
- El runtime no debilita containment, overlays ni validacion de adapters.

### Etapa D: consolidar el motor de perfiles, aislamiento y sesiones

Objetivo: congelar los contratos internos que usaran la transferencia y los
consumidores futuros.

Fronteras:

- Parsing y dispatch en `nini-agents` y su launcher PowerShell.
- Runtime, migracion, transferencia, credenciales y OS-user isolation en los
  modulos existentes bajo `lib/`.
- Contratos declarativos en `schema/adapter.schema.json` y
  `ai-tools/*/adapter.json`.
- Schema v2 con `.profile.json`, `auth/`, `.runtime/` reconstruible y estado
  normal declarado por el adapter.

Criterios de salida:

- Crear, lanzar, clonar, renombrar, borrar, autenticar, continuar sesiones,
  exportar, importar y migrar conservan sus invariantes documentadas.
- Las categorias credential files, shared paths y session paths no se solapan.
- Un fallo de enlace de runtime aborta; nunca degrada a una copia divergente.
- Bash y PowerShell exponen la misma semantica donde corresponde.

Skills principales: `nini-agents-change-integral`,
`nini-agents-profile-security` y `nini-agents-adapter-runtime`.

### Etapa E: incorporar el movimiento seguro de Codexporter

Objetivo: mover un perfil entre equipos sin revocar, regenerar ni duplicar su
credencial activa.

Codexporter se usa como contrato legacy a verificar, no como codigo ya
integrado. Se preservan estas propiedades:

- copia del home completo permitido por SSH;
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

### Etapa F: CLI JSON estable

Objetivo: ofrecer una interfaz consumible por MultiCLI AI, Codexporter y futuras
automatizaciones sin depender de texto humano.

Contrato minimo a definir antes de implementar:

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
- Codexporter deja de ser owner del algoritmo de transferencia.
- Rollback de cada consumidor restaura el ultimo contrato compatible sin tocar
  credenciales reales durante pruebas sinteticas.
- La migracion no se presenta como completa hasta verificar ambos consumidores.

### Etapa I: retiro de compatibilidad y entrega

Objetivo: retirar deuda temporal solo despues de medir adopcion y confirmar que
no quedan consumidores legacy.

Decisiones que requieren aprobacion futura:

- retiro del shim `multi-cli`;
- cambio de `MULTICLI_HOME` o `~/MultiCliProfiles`;
- limpieza de formatos legacy;
- instalacion sobre la copia activa;
- migracion de perfiles reales;
- conexion a equipos reales;
- tags, release, publicacion o distribucion.

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
| G7 | Instalar, migrar, borrar, publicar o lanzar una release | Completar una auditoria |

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

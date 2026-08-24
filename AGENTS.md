# Instrucciones para agentes

## Producto y etapa

- Nini Agents CLI es un fork personal de Multi-CLI para administrar cuentas aisladas de herramientas de IA en Linux, macOS y Windows.
- La base vigente de esta branch es Multi-CLI `6efb0d2`; el ejecutable principal es `nini-agents` y `multi-cli` es un shim temporal. No presentar todavia la transferencia de Codexporter, la CLI JSON ni las migraciones consumidoras como funcionalidades implementadas.
- El motor actual tiene dos implementaciones equivalentes: Bash 3.2 o superior y Windows PowerShell 5.1 o superior.
- Los datos locales, perfiles y credenciales son reales aunque el producto no este en produccion empresarial. Priorizar siempre recuperabilidad y no revocacion.
- El plan maestro y la bitacora de continuidad viven en `docs/plans/nini-agents-end-to-end.md`; describen direccion y gates, pero no conceden autorizacion para ejecutar etapas pendientes. Para una reanudacion ordinaria, leer primero `docs/plans/nini-agents-resume.md` y consultar la bitacora completa solo si hace falta historia, evidencia detallada o cambiar una etapa.

## Alcance y autorizacion

- Antes de modificar codigo, documentacion, configuracion, migraciones o skills, investigar en lectura, informar el alcance y esperar aprobacion explicita.
- El alcance debe indicar objetivo, comportamiento, archivos o fronteras, compatibilidad, datos o credenciales, exclusiones y validacion.
- La aprobacion cubre solo lo informado. Detenerse si aparece una ampliacion material, una operacion destructiva, una instalacion, una publicacion o acceso a perfiles reales no incluido.
- Diagnosticar no autoriza implementar el fix. Sincronizar upstream no autoriza renombrar el producto, migrar consumidores ni publicar una release.

## Skills canonicas

Las skills del proyecto viven exclusivamente en `.agents/skills/`:

- `nini-agents-change-integral`: cambios funcionales que cruzan launchers, modulos, adapters, pruebas o documentacion.
- `nini-agents-profile-security`: perfiles, credenciales, auth, clone, delete, continue, templates, export, import, migracion y movimiento entre equipos.
- `nini-agents-adapter-runtime`: schema v2, adapters, mecanismos de cuenta, runtime, credential stores y soporte de plataforma.
- `nini-agents-upstream-integration`: sincronizacion del fork, port de parches, renombre, releases y migracion futura de consumidores.
- `nini-agents-diagnostico-incidentes`: localizar causas desconocidas sin implementar el fix.

Activar solo las skills relevantes. `change-integral` coordina, pero no reemplaza las reglas especializadas de seguridad, adapters o upstream.

## Branches y fuentes

- `multi-cli-base` conserva el upstream puro y sigue `multi-cli-upstream/main`.
- `main` contiene la evolucion propia del motor Nini Agents.
- `legacy-gui` y el remote local `legacy` conservan la aplicacion Flutter existente mientras se prepara una migracion separada.
- No copiar cambios entre branches por nombre de archivo. Comparar historia, contrato y pruebas antes de portar comportamiento.
- Conservar `LICENSE` y la atribucion MIT del proyecto original durante el fork y el renombre.

## Arquitectura vigente

```text
nini-agents / nini-agents.ps1
        -> comandos y dispatch
        -> lib/*.sh / lib/MultiCli.*.psm1
        -> schema/adapter.schema.json + ai-tools/*/adapter.json
        -> filesystem, credential store y proceso de la herramienta

multi-cli / multi-cli.ps1
        -> shims temporales sin logica de perfiles
        -> entrypoints nini-agents
```

- Mantener parsing y dispatch en los entrypoints; colocar runtime, migracion, transferencia, validacion, credenciales y OS-user isolation en sus modulos existentes.
- Mantener `multi-cli` y `multi-cli.ps1` como shims delgados hasta migrar los consumidores; no duplicar logica del motor dentro de ellos.
- Conservar paridad observable Bash y PowerShell cuando una capacidad sea multiplataforma.
- Los adapters son contratos declarativos. No dispersar excepciones de una herramienta por el launcher si el schema puede expresarlas sin debilitar validaciones.
- Schema v2 separa metadata `.profile.json`, credenciales bajo `auth/`, runtime reconstruible bajo `.runtime/` y estado normal declarado por el adapter.
- Preservar compatibilidad legacy solo donde el codigo la reconoce expresamente. No crear nuevos perfiles schema v1.

## Seguridad de perfiles y credenciales

- No leer, imprimir, registrar, versionar ni incluir en fixtures valores de `auth.json`, tokens, secretos o identificadores privados.
- No ejecutar logout, revocacion, `auth clear`, borrado, migracion, importacion, uninstall ni reparaciones sobre perfiles reales sin autorizacion especifica.
- No modificar `~/.codex`, el `MULTICLI_HOME` real, `~/.local/share/nini-agents` ni `~/.local/share/multi-cli` durante desarrollo o pruebas.
- Conservar temporalmente `MULTICLI_HOME`, `~/MultiCliProfiles`, `MULTICLI_PROFILE_ID`, targets `multi-cli/...` y ownership interno legacy hasta una migracion separada y aprobada.
- Usar directorios temporales y perfiles sinteticos para toda prueba mutable.
- Fallar cerrado ante traversal, enlaces, hardlinks, rutas fuera del root, archivos desconocidos, conflictos de credenciales o procesos activos.
- No sobreescribir una credencial destino diferente. No borrar el origen antes de verificar staging, destino y rollback.
- `export`, `import`, templates y `continue` permanecen libres de credenciales.
- El futuro movimiento seguro desde Codexporter es un contrato distinto: propietario activo unico, procesos cerrados, staging, validacion, comparacion, activacion atomica, rollback y copia inactiva; nunca logout ni revocacion.

## Adapters y plataformas

- Conservar compatibilidad con Bash 3.2 y Windows PowerShell 5.1.
- No inventar rutas, mecanismos, concurrencia o soporte de una herramienta. Verificarlos en documentacion primaria y, para declarar soporte, mediante una prueba real protegida.
- Mantener alineados schema JSON, validadores Bash/PowerShell, adapter, guia y matriz de soporte.
- No solapar credential files, shared paths y session paths.
- No usar una copia como fallback cuando falle un enlace de runtime; abortar evita estado divergente.
- Registrar como no ejecutada cualquier plataforma que el entorno actual no permita probar.

## Simplicidad y compatibilidad

- Seguir los modulos y funciones existentes antes de crear una abstraccion nueva.
- No agregar frameworks, servicios, caches, bases de datos o daemons por especulacion.
- Mantener logica corta inline cuando no exista una frontera recurrente ni duplicacion relevante.
- Conservar flags y comandos legacy documentados mientras un cambio aprobado no incluya su retiro y migracion.
- Usar ingles para archivos, funciones, variables, mensajes tecnicos y documentacion upstream; usar espanol en reglas internas o texto propio cuando corresponda.

## Git y workspace

- No revertir, borrar, stagear, des-stagear, commitear, taggear, rebasear ni empujar sin instruccion expresa.
- No usar `git reset --hard`, force-push ni resolver conflictos eligiendo un lado completo sin comparar contratos.
- Preservar cambios concurrentes y no modificar artefactos ajenos al alcance.
- No probar el checkout reinstalando sobre la copia activa.

## Validacion

- Empezar con pruebas focalizadas. Un cambio funcional necesita una prueba que falle sin el cambio y pase con el.
- Para Bash usar `bash tests/run-bats.sh <pruebas.bats>` y el gate de cobertura aplicable.
- Para PowerShell usar `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -CI` cuando el entorno este disponible.
- Para adapters ejecutar `bash scripts/validate-adapters.sh` y el validador PowerShell cuando corresponda.
- Para documentacion ejecutar `python3 scripts/validate-docs.py`.
- Para release ejecutar `bash release/build.sh --check` antes de empaquetar.
- No ejecutar instaladores, uninstalls, pruebas E2E reales o builds de release salvo que formen parte del alcance aprobado.
- No afirmar que funciona en Windows, macOS o con una herramienta real sin evidencia de esa ejecucion.

## Cierre

Informar resultado, antes y despues, archivos y contratos modificados, efecto sobre credenciales o compatibilidad, validaciones ejecutadas, plataformas no verificadas y pendientes. Distinguir claramente codigo existente, direccion aprobada y funcionalidad todavia no implementada.

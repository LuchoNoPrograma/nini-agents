---
name: nini-agents-diagnostico-incidentes
description: Diagnostica fallos de Nini Agents CLI con causa desconocida, como cuentas cruzadas, perfiles que no lanzan, migraciones incompletas, runtimes inconsistentes, transferencias rechazadas o diferencias entre Bash y PowerShell. Usar para localizar la causa y reunir evidencia; no usar para implementar el fix ni para una solicitud cuyo cambio ya esta definido.
---

# Nini Agents CLI Diagnostico de Incidentes

## Proposito

Localizar la primera divergencia del recorrido preservando perfiles, credenciales y evidencia antes de proponer cambios.

## Alcance del proyecto

- Dispatchers, adapters, metadata, runtime, filesystem, credential stores, procesos hijos, migraciones, transferencias y diferencias de plataforma.
- Diagnostico read-only sobre datos reales; reproducciones mutables unicamente con homes y perfiles sinteticos.

## Fuentes

- Leer `README.md`, `docs/SUPPORT.md`, el adapter afectado y las pruebas del recorrido observado.
- Leer el dispatcher y seguir llamadas hasta el primer estado, ruta, proceso o contrato que diverge.

## Patrones del proyecto

- `nini-agents` - `cmd_doctor` y `nini-agents.ps1` - `Show-Doctor`: los diagnosticos reportan capacidades y fallos sin reparar silenciosamente el perfil; `multi-cli` solo reproduce el recorrido mediante shim.
- `lib/multicli-runtime.sh` - `runtime_overlay_is_current` y `lib/MultiCli.Runtime.psm1` - `Test-RuntimeOverlayCurrent`: el runtime se compara con el manifest esperado antes de reconstruirlo.
- `tests/profile_safety.bats` y `tests/ProfileSafety.Tests.ps1`: los rechazos por containment, legacy o credenciales se reproducen en almacenamiento sintetico.

## Flujo

1. Definir comportamiento esperado, observado, plataforma, herramienta, comando y momento de la divergencia.
2. Capturar version, branch, rutas efectivas, schema, metadata sanitizada, permisos, tipos de archivo y procesos relevantes sin revelar secretos.
3. Seguir el recorrido desde parsing y adapter hasta runtime, proceso hijo y estado posterior; detenerse en la primera divergencia demostrable.
4. Reproducir con `MULTICLI_HOME` temporal y fixtures minimos cuando la lectura no baste.
5. Entregar causa o hipotesis ordenadas, evidencia, alcance probable del fix y validacion recomendada sin implementarlo.

## Reglas

- No ejecutar `delete`, `auth clear`, `migrate`, `import`, `uninstall`, logout ni reparaciones sobre perfiles reales.
- No imprimir contenido de credenciales, variables secretas, logs privados completos o identificadores de cuenta.
- Distinguir fallo del adapter, defecto del runtime, perfil legacy, instalacion desactualizada y limitacion de plataforma.
- No confundir ausencia de evidencia de Windows o macOS con comportamiento correcto en esas plataformas.
- Solicitar autorizacion nueva antes de pasar del diagnostico al fix.

## Validacion

- Ejecutar primero `nini-agents doctor` o `doctor --deep` solo cuando sea read-only para el entorno inspeccionado.
- Usar las pruebas Bats o Pester focalizadas del recorrido con `MULTICLI_HOME` temporal.
- Comparar Bash y PowerShell solo con evidencia de los entornos realmente ejecutados.
- Sanitizar rutas, metadata y salidas antes de incluirlas en el informe.

## Autoevaluacion

- La primera divergencia esta demostrada y no solo inferida?
- La evidencia se obtuvo sin cambiar perfiles ni exponer secretos?
- El informe separa causa, impacto, hipotesis y fix futuro?

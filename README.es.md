[English](README.md) | **Español** | [العربية](README.ar.md) | [中文](README.zh.md) | [Русский](README.ru.md) | [עברית](README.he.md)

# multi-cli

**Ejecuta varios perfiles de cuenta de herramientas de programación con IA de forma simultánea.**

Un perfil schema-v2 aísla la credencial de la cuenta y la identidad de cuota, mientras comparte el estado normal de la herramienta — conversaciones, configuración, agentes, skills y plugins — cuando el proveedor expone un límite seguro. Los productos que combinan la autenticación con las sesiones o con un estado fijo en el llavero se marcan como experimentales o no compatibles, en lugar de recibir una afirmación de aislamiento falsa. Ningún adaptador ha superado aún la verificación de doble cuenta; consulta [la matriz de compatibilidad](docs/support-matrix.md) para ver el estado exacto por producto, plataforma y modo de autenticación.

Los perfiles schema-v1 existentes siguen siendo perfiles heredados de raíz completa hasta que se migren — consulta [Perfiles heredados](#perfiles-heredados).

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Spielewoy/multi-codex)
[![GitHub profile](https://img.shields.io/badge/GitHub-Spielewoy-lightgrey?logo=github)](https://github.com/Spielewoy)
[![GitHub stars](https://img.shields.io/github/stars/Spielewoy/multi-codex?style=social)](https://github.com/Spielewoy/multi-codex/stargazers)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#instalación)
[![License](https://img.shields.io/badge/license-MIT-green)](#licencia)

---

## Herramientas compatibles

Este repositorio incluye 17 adaptadores. El estado es por sistema operativo: `experimental` significa que existe un límite candidato documentado, pero la verificación completa de doble cuenta no ha superado las pruebas, y `no compatible` significa que multi-cli se niega a afirmar aislamiento de cuentas. Nada está verificado todavía. La fuente autorizada es [docs/support-matrix.md](docs/support-matrix.md).

| Herramienta | Tipo | Windows | macOS | Linux |
|------|------|---------|-------|-------|
| [Claude Code](claude-cli/) | CLI | experimental | no compatible (OAuth almacenado) | experimental |
| [OpenAI Codex CLI](codex/) | CLI | experimental | experimental | experimental |
| [Gemini CLI](gemini-cli/) | CLI | experimental | experimental | experimental |
| [OpenCode](opencode/) | CLI | no compatible | no compatible | no compatible |
| [Command Code](commandcode/) | CLI | no compatible | no compatible | no compatible |
| [Cursor Desktop](cursor/) | IDE | no compatible | no compatible | no compatible |
| [Cursor CLI](cursor-cli/) | CLI | experimental | experimental | experimental |
| [Antigravity](antigravity/) | IDE | experimental | no compatible | no compatible |
| [AGY CLI](agy-cli/) | CLI | experimental | no compatible | no compatible |
| [Kiro](kiro/) | IDE | experimental | no compatible | no compatible |
| [Zed](zed/) | IDE | no compatible | no compatible | experimental |
| [Devin Desktop / Windsurf](windsurf/) | IDE | experimental | no compatible | no compatible |
| [GitHub Copilot CLI](copilot-cli/) | CLI | experimental | experimental | experimental |
| [Copilot en VS Code](copilot-vscode/) | IDE | experimental | no compatible | no compatible |
| [Kimi Code CLI](kimi-cli/) | CLI | experimental | experimental | experimental |
| [Codex Windows App](codex-gui/) | IDE | no compatible | no compatible | no compatible |
| [Grok Build CLI](grok-cli/) | CLI/TUI | experimental | experimental | experimental |

Cada herramienta tiene su propia carpeta en la raíz del repositorio con un `adapter.json` que describe el límite de la cuenta, el estado normal compartido y la evidencia necesaria para ser promovido a verificado.

---

## Instalación

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.sh | bash
```

**Windows** — abre PowerShell:

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.ps1 | iex
```

> Después de la instalación, **reinicia tu terminal** para que los cambios en el PATH surtan efecto.

### Desde el código fuente

```bash
git clone https://github.com/Spielewoy/multi-codex.git
cd multi-codex
./scripts/install.sh --local        # macOS/Linux
.\scripts\install.ps1 -Local        # Windows
```

> Después de la instalación, **reinicia tu terminal** para que los cambios en el PATH surtan efecto.

> [jq](https://jqlang.github.io/jq/) se **instala automáticamente** con el instalador en todas las plataformas — no se requiere configuración manual.

---

## Inicio rápido

```bash
# Create a profile
multi-cli new claude-cli/work

# Launch it
multi-cli launch claude-cli/work

# Or use the shorthand
multi-cli claude-cli/work
```

Cada perfil obtiene un alias de shell automático:

| Plataforma | Ubicación |
|----------|----------|
| macOS / Linux | `~/MultiCliProfiles/bin/` (añadir al `PATH`) |
| Windows | Accesos directos del menú Inicio creados automáticamente |

---

## Comandos

### Gestión de perfiles

| Comando | Descripción |
|---------|-------------|
| `multi-cli new <tool>/<name>` | Crear un nuevo perfil aislado |
| `multi-cli new <tool>/<name> --shared` | Perfil ligero (configuración compartida, autenticación aislada) |
| `multi-cli new <tool>/<name> --from <tpl>` | Crear a partir de una plantilla guardada |
| `multi-cli <tool>/<name>` | Lanzar un perfil (abreviatura) |
| `multi-cli launch <tool>/<name>` | Lanzar un perfil |
| `multi-cli list [<tool>]` | Listar todos los perfiles |
| `multi-cli status` | Mostrar estado de ejecución, tipo, último uso y tamaño |
| `multi-cli clone <tool>/<src> <tool>/<dest>` | Copiar un perfil existente |
| `multi-cli rename <tool>/<old> <tool>/<new>` | Renombrar un perfil |
| `multi-cli delete <tool>/<name>` | Eliminar un perfil y todos sus datos |

### Autenticación de cuentas y migración

| Comando | Descripción |
|---------|-------------|
| `multi-cli auth set <tool>/<profile>` | Guardar la credencial de secreto de proceso del perfil en el almacén de credenciales del sistema operativo (pregunta interactivamente o lee una línea desde stdin) |
| `multi-cli auth status <tool>/<profile>` | Indicar si hay una credencial guardada para el perfil |
| `multi-cli auth clear <tool>/<profile>` | Eliminar la credencial guardada |
| `multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]` | Migrar un perfil heredado schema-v1 a schema-v2 |

`auth` solo se aplica a los adaptadores que usan el mecanismo `processSecret` (`cursor-cli`, `copilot-cli`, `kimi-cli`, `grok-cli`). El lanzamiento permanece deshabilitado hasta que se guarde una credencial. Consulta [Perfiles heredados](#perfiles-heredados) para `migrate`.

### Plantillas

| Comando | Descripción |
|---------|-------------|
| `multi-cli template save <tool>/<profile> <name>` | Guardar un perfil como plantilla reutilizable |
| `multi-cli template list` | Listar las plantillas guardadas |
| `multi-cli template delete <name>` | Eliminar una plantilla |

### Copia de seguridad y transferencia

| Comando | Descripción |
|---------|-------------|
| `multi-cli export <tool>/<name> [path]` | Archivar un perfil en `.tar.gz` (`.zip` en Windows) |
| `multi-cli import <archive> <tool>/<name>` | Restaurar un perfil desde un archivo |

### Sesiones

| Comando | Descripción |
|---------|-------------|
| `multi-cli continue <tool> <src> <dest>` | Copiar el estado de la conversación (sesiones/transcripciones/historial) de un perfil a otro — nunca las credenciales |
| `multi-cli continue <tool> <src> <dest> --no-merge` | Sobrescribir los archivos de destino en lugar de conservar los más recientes |
| `multi-cli continue <tool> <src> <dest> --dry-run` | Previsualizar lo que se copiaría, sin cambiar nada |

`base` funciona como nombre de perfil en cualquiera de los extremos y significa el directorio home real de la herramienta (`~/.codex`, `~/.claude`, …). Compatible con `codex`, `claude-cli`, `gemini-cli` y `commandcode`. Consulta [Continuar un chat entre cuentas](#continuar-un-chat-entre-cuentas).

### Utilidades

| Comando | Descripción |
|---------|-------------|
| `multi-cli tools` | Listar todas las herramientas compatibles y su estado de instalación |
| `multi-cli stats` | Mostrar el uso de disco por perfil |
| `multi-cli doctor` | Diagnosticar tu entorno |
| `multi-cli completion {bash\|zsh\|powershell}` | Configurar el autocompletado del shell |
| `multi-cli help` | Mostrar ayuda |
| `multi-cli version` | Mostrar la versión |

---

## Cómo funciona el aislamiento

Los adaptadores schema-v2 declaran un mecanismo de cuenta separado del estado normal:

| Mecanismo | Cómo funciona |
|-----------|--------------|
| `fileOverlay` | Las credenciales permanecen dentro del perfil; el estado normal declarado enlaza con el home compartido nativo de la herramienta. |
| `processSecret` | Una credencial por perfil, de máxima precedencia, se inyecta únicamente en el proceso hijo. El lanzamiento permanece deshabilitado hasta que se configure un almacenamiento seguro de secretos. |
| `osUserCredentialStore` | Las identidades fijas del llavero se separan con un usuario del sistema operativo propiedad de multi-cli. Permanece deshabilitado hasta que se verifiquen la propiedad y la limpieza. |
| `inseparable` | El proveedor combina la autenticación y el estado normal; el lanzamiento conforme falla de forma cerrada y se muestra la limitación. |

Los perfiles de la versión 1 conservan el comportamiento anterior de raíz completa (`env`, `userDataDir`, `redirectHome`, `appdata` y `sandboxUser`) por compatibilidad. Cada `<id>/adapter.json` indica las capacidades por producto/plataforma y los requisitos de evidencia.

---

<a id="continuar-un-chat-entre-cuentas"></a>

## Continuar un chat entre cuentas

¿Alcanzaste un límite de velocidad en la cuenta A a mitad de una conversación? Cambia a un perfil con sesión iniciada en la cuenta B y retoma el chat donde se quedó. `multi-cli continue` copia el estado portable de la conversación — sesiones, transcripciones, historial — entre perfiles. **Las credenciales nunca se copian.**

```bash
# You were working in codex/work (account A) and got rate-limited.
# codex/personal is logged into account B.
multi-cli continue codex work personal          # copy the conversation state
multi-cli continue codex work personal --dry-run  # preview first, if you like

codex-personal                                  # launch account B's profile
codex resume <session-id>                        # resume the same chat (codex ≥ 0.30)
```

Ejecuta `codex resume` sin argumentos para abrir un selector interactivo de sesiones anteriores, así nunca tendrás que buscar un id. Si lo necesitas, el id de sesión es el UUID del nombre de archivo de rollout bajo `sessions/YYYY/MM/DD/`.

`base` es un nombre de perfil válido en cualquiera de los extremos y se refiere al directorio home real de la herramienta (`~/.codex`, `~/.claude`, …), por lo que puedes continuar hacia o desde tu instalación predeterminada.

Por defecto, los archivos se **fusionan** — se conservan los archivos más recientes del destino. Pasa `--no-merge` para sobrescribir el destino, o `--dry-run` para previsualizar sin cambiar nada.

Después de copiar, reanuda dentro del perfil de destino con el comando propio de la herramienta:

| Herramienta | Comando de reanudación |
|------|----------------|
| codex | `codex resume <session-id>` (≥ 0.30) |
| claude-cli | `claude --resume <session-id>` (ejecutar desde el mismo directorio de proyecto) |
| gemini-cli | `gemini --resume` (última sesión guardada automáticamente) o `/chat resume <tag>` para puntos de control guardados |
| commandcode | lanzar desde el mismo directorio de trabajo |

**No compatible:** `opencode` (las sesiones y las credenciales viven en una única base de datos SQLite compartida) y `cursor` (los chats se almacenan en SQLite indexados por la ruta del espacio de trabajo).

> Los perfiles nuevos se siembran desde `base` por defecto — estado de la conversación, más recursos de skills/configuración para los perfiles completos. Pasa `--no-seed` a `multi-cli new` para empezar vacío.

---

## Tipos de perfil

| Flag | Significado |
|------|---------|
| *(ninguno)* | **Completo** — totalmente aislado. Autenticación nueva, configuración nueva. |
| `--shared` | **Compartido** — enlaza simbólicamente la configuración/extensiones de tu instalación principal. La autenticación permanece aislada. |
| `--cli` | **CLI** — marca el perfil para lanzamiento solo en terminal (omite la detección de GUI). |
| `--from <tpl>` | Clonar desde una plantilla guardada. |

---

## Variables de entorno

| Variable | Valor por defecto | Propósito |
|----------|---------|---------|
| `MULTICLI_HOME` | `~/MultiCliProfiles` | Dónde se almacenan todos los perfiles |
| `MULTICLI_OVERRIDE_BINARY` | *(sin definir)* | Forzar una ruta de binario específica para el próximo lanzamiento |
| `MULTICLI_REPO` | *(sin definir)* | URL de Git para la instalación remota |
| `MULTICLI_PLATFORM` | *(automático)* | Anular la detección de plataforma (`darwin`, `linux`) |

---

## Perfiles heredados

Los perfiles creados antes de schema-v2 son perfiles heredados de raíz completa: conservan el comportamiento anterior de `env`, `userDataDir`, `redirectHome`, `appdata` y `sandboxUser` por compatibilidad. Un directorio de perfil sin archivo `.profile.json` se trata como heredado.

`multi-cli migrate <tool>/<name>` convierte un perfil heredado a schema-v2: las credenciales declaradas se mueven al perfil y el estado normal declarado se enlaza con el home compartido de la herramienta. Usa `--dry-run` para previsualizar el plan de movimiento sin cambiar nada, y `--prefer-profile` para reemplazar los archivos compartidos en conflicto con la copia del perfil — los destinos de credenciales nunca se sobrescriben. El almacenamiento de perfiles y la raíz de estado compartido deben estar en el mismo volumen, porque la migración usa movimientos atómicos dentro del mismo volumen.

---

## Diagnóstico

```bash
multi-cli doctor
```

Comprueba que el almacenamiento de perfiles existe, que el directorio de alias está en el PATH y que el binario de cada herramienta se detecta (o muestra una sugerencia de instalación).

---

## Autocompletado del shell

```bash
multi-cli completion bash   # or zsh, powershell
```

Sigue las instrucciones para añadirlo a tu `.zshrc`, `.bashrc` o `$PROFILE` de PowerShell.

---

## Desinstalación

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.ps1 | iex
```

Se te preguntará si deseas eliminar los datos de tus perfiles — nada se borra sin confirmación.

---

## Enlaces

- [Matriz de compatibilidad](docs/support-matrix.md) — estado de aislamiento por producto y por SO, y los criterios de verificación
- [Política de seguridad](SECURITY.md)
- [Licencia](LICENSE)
- [Repositorio en GitHub](https://github.com/Spielewoy/multi-codex)

---

## Créditos

- **Creador** — [Spielewoy](https://github.com/Spielewoy)

---

## Licencia

[MIT](LICENSE)

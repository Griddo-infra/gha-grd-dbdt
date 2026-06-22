# CLAUDE.md

Contexto del repositorio para futuras sesiones de Claude Code.

## Propósito

Este repo publica una **GitHub Action composite** (`gha-grd-dbdt`) que automatiza el volcado y la restauración de bases de datos **RDS MySQL/MariaDB** entre cuentas AWS, utilizando roles OIDC, AWS Secrets Manager y S3 para el intercambio del dump como URL pre-firmada.

La Action expone dos modos atómicos (`extraer` y `restaurar`); las migraciones extremo a extremo se orquestan a nivel de workflow encadenando ambos modos con su propio `configure-aws-credentials` (ver `.github/example.md`).

## Estructura del repo

| Archivo                  | Rol                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------- |
| `action.yml`             | Contrato público de la Action: `inputs`, `outputs`, `runs.steps`. **Fuente de verdad** de la interfaz. |
| `entrypoint.sh`          | Lógica real: `modo_extraer`, `modo_restaurar`, apertura/cierre temporal del SG, mysqldump/restore, gestión de S3 y URLs pre-firmadas. **Fuente de verdad** del comportamiento. |
| `.github/README.md`      | Documentación de usuario en español.                                                  |
| `.github/example.md`     | Ejemplo de workflow consumidor (incluye orquestación multi-cuenta).                   |
| `.github/SECURITY.md`    | Política de seguridad del repo.                                                       |
| `.github/CODEOWNERS`     | Code owners.                                                                          |
| `CHANGELOG.md`           | Registro de cambios en formato Keep a Changelog.                                      |
| `CLAUDE.md`              | Este archivo.                                                                         |
| `.claude/agents/`        | Sub-agentes de Claude Code (incluye `doc-updater`).                                   |

## Convenciones

- **Idioma**: español en código (mensajes, comentarios), README, CHANGELOG y commits.
- **Commits**: Conventional Commits — `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`. Los cambios *breaking* se marcan con `!` (ej. `feat!: ...`).
- **Tags**:
  - **Tags exactas** por release: `vX.Y.Z` (inmutables, apuntan a un commit concreto).
  - **Tags flotantes** por minor: `vX.Y` (apuntan al último patch publicado dentro de ese minor; se mueven con `git tag -f` + `git push -f`).
  - Las tags exactas **nunca se mueven**; solo las flotantes.
- **README**:
  - Cabeceras con emojis temáticos (📘 ⚙️ 📤 📊 🔍 🟢 🟡 🟣 🧩 🔐 🏷️ 🛟 …) — mantener el set existente, no introducir emojis nuevos sin motivo.
  - Tablas markdown con `|` alineados visualmente.
  - Bloques de código con `~~~` (no triple backtick).

## Reglas operativas críticas

- **Bloqueo de `*_pro`**: el modo `restaurar` aborta si el nombre del secreto de destino contiene `_pro`. No se permite restaurar sobre producción.
- **Red de seguridad en restauración**: el input `backup_before_restore` (default `true`) fuerza un `mysqldump` completo del destino subido a S3 antes de aplicar el dump del origen, y exporta su URL pre-firmada como output `backup_presigned_url`. Si el flag está activo y el secreto de destino no tiene `s3_bucket`, la Action **aborta antes de tocar la base de datos**.
- **Preservación de valores del destino**: durante la restauración se extraen y reaplican `domain_url` por `domain_slug` (tabla `domains`) y credenciales (`email`, `password`) del usuario `Administrator` y de los usuarios `bot`. Esto sobrevive al dump del origen.
- **Acceso temporal al RDS**: la Action abre una regla de ingress al puerto 3306 limitada a la IP del runner y la revoca al terminar (incluido en el `trap` de limpieza). No deja reglas residuales en el security group.
- **Tablas ignoradas en extracción**: ver la lista canónica en `entrypoint.sh` (función `modo_extraer`, flags `--ignore-table`). Puede cambiar entre versiones — **no hardcodear esta lista en `CLAUDE.md`**, leer el archivo.
- **Limpieza local**: el `trap clean_up` borra todos los ficheros temporales (`dump`, `backup`) y el `TMP_DIR` al salir.

## Sub-agente `doc-updater`

Cuando edites `action.yml`, `entrypoint.sh`, o cambies el comportamiento del action (nuevos inputs/outputs, modos, validaciones, fases), invoca **proactivamente** al sub-agente `doc-updater` (definido en `.claude/agents/doc-updater.md`) para mantener sincronizados:

- `.github/README.md` (tabla de entradas, tabla de outputs, combinaciones por modo, flujos detallados por modo, sección de seguridad).
- `CHANGELOG.md` (sección `[Unreleased]` con los cambios desde el último tag).
- `CLAUDE.md` (este archivo, si cambian reglas operativas o estructura).

El sub-agente **no commitea ni mueve tags**, solo modifica archivos y reporta el diff propuesto. La decisión de release y de mover la tag flotante queda en manos del usuario.

## Flujo típico de release

1. Editar `action.yml` y/o `entrypoint.sh` con el cambio de comportamiento.
2. Invocar el sub-agente `doc-updater` para regenerar README, CHANGELOG (`[Unreleased]`) y CLAUDE.md si procede.
3. Revisar el diff, ajustar manualmente lo necesario.
4. Commit con Conventional Commits (`feat:`, `fix:`, `feat!:` …).
5. Crear tag exacta `vX.Y.Z` y mover la tag flotante `vX.Y` al mismo commit (`git tag -f vX.Y vX.Y.Z && git push -f origin vX.Y`).
6. Convertir la sección `[Unreleased]` del CHANGELOG en `[X.Y.Z] - YYYY-MM-DD` en un commit posterior si se prefiere mantener el histórico limpio.

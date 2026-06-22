# Changelog

Todos los cambios relevantes de esta Action se documentan en este archivo.

El formato sigue [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) y este proyecto se adhiere a [Semantic Versioning](https://semver.org/lang/es/).

## [Unreleased]

## [0.6.0] - 2026-06-22

### Added

- Nuevo input `backup_before_restore` (default `true`, opcional, solo aplica en modo `restaurar`): cuando está activo se genera un backup completo del destino con `mysqldump` antes de aplicar el dump del origen, se sube al bucket S3 del secreto de destino como `backup_pre_restore_<timestamp>.sql.gz` y se expone su URL pre-firmada.
- Nuevo output `backup_presigned_url` con la URL pre-firmada del backup pre-restauración. Solo se exporta cuando `backup_before_restore=true`.
- Nueva fase de ejecución en el modo `restaurar`: **BACKUP PRE-RESTAURACIÓN DEL DESTINO**, registrada con logs propios en `entrypoint.sh`.

### Changed

- El modo `restaurar` ahora acepta dos parámetros posicionales adicionales: `<BACKUP_BEFORE_RESTORE>` y `<TTL_SEGUNDOS>` (ambos opcionales con defaults `true` y `7200`).
- El input `ttl` ahora también gobierna la expiración de la URL pre-firmada del backup pre-restauración.

### Security

- Si `backup_before_restore=true` y el secreto de destino no expone `s3_bucket`, la Action **aborta antes de tocar la base de datos** para no restaurar sin red de seguridad.

## [0.5.1] - 2026-06-08

### Fixed

- Se añade la tabla `migrations` a la lista de tablas ignoradas en `mysqldump` durante la extracción.

## [0.5.0] - 2026-05-27

### Breaking

- Se elimina el modo `completo` de la Action. Para una migración extremo a extremo el workflow debe encadenar dos invocaciones (`extraer` + `restaurar`) con sus propios `configure-aws-credentials`, permitiendo flujos multi-cuenta. Ver `example.md`.

### Added

- Logs verbosos por fases en `entrypoint.sh` con cabeceras delimitadoras para facilitar el seguimiento del run.

## [0.4.1] - 2026-05-27

### Added

- Logs verbosos por fases en `entrypoint.sh`.

### Documentation

- Se documenta el uso de tags flotantes por minor (`vX.Y`) y el procedimiento para moverlas tras publicar un nuevo patch.

## [0.4.0] - 2026-05-11

### Added

- Preservación automática en el destino durante una restauración de: `domain_url` por `domain_slug` (tabla `domains`) y credenciales (`email`, `password`) del usuario `Administrator` y de los usuarios marcados como `bot`. Las sentencias se extraen antes de aplicar el dump del origen y se reaplican al terminar.

### Fixed

- Instalación de AWS CLI v2 desde el instalador oficial dentro del runner.

## [0.3.1] - 2025-12-03

### Added

- Se añade la tabla `log_alerts` a la lista de tablas ignoradas en `mysqldump` durante la extracción.

### Documentation

- Actualizaciones varias del README.

## [0.3] - 2025-07-18

### Added

- Mensajes adicionales en logs al cerrar el acceso temporal al security group.

## [0.2] - 2025-07-18

### Changed

- Reducción del ruido en logs del modo `restaurar`.

## [0.1] - 2025-07-18

### Added

- Primera versión publicada de la Action: modos `extraer` y `restaurar` para volcado/restauración de RDS MySQL/MariaDB entre cuentas AWS vía Secrets Manager y S3, apertura/cierre temporal del security group de la instancia RDS, generación de URL pre-firmada y bloqueo de restauraciones contra entornos `*_pro`.

[Unreleased]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.3...v0.3.1
[0.3]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.2...v0.3
[0.2]: https://github.com/Griddo-infra/gha-grd-dbdt/compare/v0.1...v0.2
[0.1]: https://github.com/Griddo-infra/gha-grd-dbdt/releases/tag/v0.1

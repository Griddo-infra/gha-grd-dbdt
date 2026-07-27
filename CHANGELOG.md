# Changelog

Todos los cambios relevantes de esta Action se documentan en este archivo.

El formato sigue [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) y este proyecto se adhiere a [Semantic Versioning](https://semver.org/lang/es/).

## [Unreleased]

### Breaking

- Se elimina el mecanismo de **acceso temporal al RDS vía security group**: las instancias RDS pasan a ser privadas (sin acceso público al endpoint) y la Action ya no abre ni revoca reglas de ingress en ningún momento (funciones `open_temporary_access`/`close_temporary_access` eliminadas de `entrypoint.sh`, incluida la revocación en el `trap` de limpieza y la dependencia de `checkip.amazonaws.com`).
- Los workflows consumidores deben ejecutarse en **runners de AWS CodeBuild asociados a las subnets privadas de la VPC del RDS** (`runs-on: codebuild-<proyecto>-${{ github.run_id }}-${{ github.run_attempt }}`), y el security group del RDS debe permitir el puerto 3306 desde el security group del runner (regla estática). En flujos multi-cuenta, `extraer` corre en el CodeBuild de la cuenta origen y `restaurar` en el de la cuenta destino.
- El campo `db_instance_identifier` del secreto **ya no se lee** (solo servía para descubrir el security group). Los secretos pueden conservarlo, pero deja de ser necesario.
- El rol OIDC ya **no** necesita los permisos `ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress`, `ec2:DescribeSecurityGroups` ni `rds:DescribeDBInstances`.

### Added

- Nuevo modo `preparar_red`: crea (o reutiliza, de forma idempotente) un **NAT gateway efímero** con Elastic IP para dar salida a Internet al runner de CodeBuild en VPCs sin NAT permanente. Descubre por tags (`dbdt:scope=<network_scope>`) la route table del runner (`dbdt:role=runner-rt`) y la subnet pública del NAT (`dbdt:role=nat-subnet`), etiqueta los recursos creados con `dbdt:managed=true` + `dbdt:scope`, espera a que el NAT esté disponible (~2 min) y crea/reemplaza la ruta por defecto `0.0.0.0/0`. Se ejecuta en un runner GitHub-hosted, antes de los jobs de CodeBuild.
- Nuevo modo `limpiar_red`: elimina la ruta por defecto, borra todos los NAT gateways etiquetados con el scope (esperando su borrado) y libera las Elastic IPs etiquetadas no asociadas. Idempotente y tolerante a la ausencia de recursos; pensado para un job final con `if: always()`.
- Nuevo input `network_scope`: identificador de la red del runner (valor de la tag `dbdt:scope`), obligatorio en los modos `preparar_red` y `limpiar_red`.
- Nuevo output `nat_gateway_id`: ID del NAT gateway efímero creado o reutilizado (solo en modo `preparar_red`).
- El rol OIDC necesita permisos EC2 adicionales para los modos de red: `ec2:DescribeRouteTables`, `ec2:DescribeSubnets`, `ec2:DescribeNatGateways`, `ec2:DescribeAddresses`, `ec2:AllocateAddress`, `ec2:ReleaseAddress`, `ec2:CreateNatGateway`, `ec2:DeleteNatGateway`, `ec2:CreateRoute`, `ec2:ReplaceRoute`, `ec2:DeleteRoute` y `ec2:CreateTags`.
- Nueva comprobación previa de conectividad (`check_db_connectivity`): test TCP con timeout de 10s contra `endpoint:3306` al inicio de ambos modos (`extraer` y `restaurar`); si el runner no tiene conectividad, la Action aborta con un mensaje que indica que debe ejecutarse en un runner de CodeBuild dentro de la VPC y que el SG del RDS debe permitir 3306 desde el SG del runner.
- Soporte para runners **Amazon Linux de CodeBuild**: el paso «Instalar Dependencias» de `action.yml` detecta el gestor de paquetes (`apt-get` en Ubuntu, `dnf` en Amazon Linux, donde el cliente MySQL es el paquete `mariadb105`) y falla con un mensaje claro si no encuentra ninguno.

### Changed

- La instalación de dependencias es ahora condicional por modo: el cliente MySQL (`mysql-client`/`mariadb105`) solo se instala en `extraer` y `restaurar`; los modos de red solo instalan las utilidades base (`jq`, `gzip`, `curl`, `unzip`) y AWS CLI v2.

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

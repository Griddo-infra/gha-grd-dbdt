# 🚀 Griddo - GitHub Action para el volcado y restauración de RDS

## 📘 Descripción General

Esta GitHub Action permite realizar volcados y restauraciones de bases de datos **RDS MySQL/MariaDB** entre cuentas AWS mediante roles OIDC y AWS Secrets Manager, de forma segura, auditada y automatizada.

### Modos soportados

La Action expone dos modos atómicos:

- `extraer`: genera un dump comprimido y lo sube a S3 con URL presignada.
- `restaurar`: descarga la URL presignada y restaura en la base destino.

Para una migración extremo a extremo, el workflow encadena ambos modos en pasos separados con su propio `configure-aws-credentials`, lo que permite asumir roles distintos en origen y destino (multi-cuenta) o el mismo role en ambas fases (mono-cuenta). El ejemplo en [example.md](example.md) implementa esta convención bajo la opción `completo` del `workflow_dispatch`.

La Action facilita **migraciones controladas** y **copias de seguridad automatizadas** entre cuentas o entornos AWS diferentes.

---

## 🛠️ Requisitos Previos

Antes de utilizar esta Action, debes contar con:

### 1️⃣ Infraestructura y cuentas AWS

- **Dos cuentas AWS** si planeas extraer de una y restaurar en otra.
- **Roles IAM creados en cada cuenta**, con políticas necesarias para:
  - Acceder a Secrets Manager.
  - Ejecutar `rds:DescribeDBInstances`.
  - Gestionar reglas de seguridad (`ec2:AuthorizeSecurityGroupIngress` y `ec2:RevokeSecurityGroupIngress`).
  - Ejecutar `s3:PutObject`, `s3:GetObject`, y `s3:CreatePresignedUrl`.
  - Ejecutar `sts:AssumeRole`.

Ejemplo de **ARN del rol** esperado:

~~~ruby
arn:aws:iam::<ACCOUNT_ID>:role/DBDumpRoleGH
~~~

El usuario o rol que ejecuta esta Action en GitHub debe contar con permisos para **asumir este rol** vía `sts:AssumeRole`.

---

### 2️⃣ Secrets en AWS Secrets Manager

Cada base de datos requiere un secreto con este **formato JSON**:

~~~json
{
  "endpoint": "mi-base.abcdefghijk.us-west-2.rds.amazonaws.com",
  "username": "admin",
  "password": "supersecreto",
  "database": "nombre_base",
  "db_instance_identifier": "mi-base-id",
  "s3_bucket": "mi-bucket-s3"
}
~~~

| Campo                   | Descripción                                                      |
| ----------------------- | ---------------------------------------------------------------- |
| `endpoint`              | Endpoint DNS de la base RDS                                      |
| `username`              | Usuario con permisos de lectura y escritura                      |
| `password`              | Contraseña del usuario                                           |
| `database`              | Nombre de la base de datos                                       |
| `db_instance_identifier`| Identificador RDS (se utiliza para abrir/cerrar acceso temporal) |
| `s3_bucket`             | Bucket S3 destino del dump                                       |

  **Importante**: El bucket S3 debe existir previamente y el rol `DBDumpRole` debe tener permisos para operar sobre él.

---

### 3️⃣ Entorno CI/CD en GitHub Actions

El repositorio desde el que se ejecute la accion debe tener configurados los siquientes secretos por entorno disponible: ROLE_NAME_(entorno), SECRET_NAME_(entorno). A continuacion un ejemplo con tres entornos:

| Entorno      | Secreto           | Descripcion                                          |
| ------------ | ----------------- | ---------------------------------------------------- |
| PRO          | `SECRET_NAME_PRO` | Nombre del Secreto de AWS Secret Manager para usar   |
|              | `IAM_ROLE_PRO`    | ARN completo del Role a asumir en este entorno       |
| STG          | `SECRET_NAME_STG` | Nombre del Secreto de AWS Secret Manager para usar   |
|              | `IAM_ROLE_STG`    | ARN completo del Role a asumir en este entorno       |
| DEV          | `SECRET_NAME_DEV` | Nombre del Secreto de AWS Secret Manager para usar   |
|              | `IAM_ROLE_DEV`    | ARN completo del Role a asumir en este entorno       |

El job que use esta Action debe:

- Configurar credenciales AWS (por ejemplo, con `aws-actions/configure-aws-credentials`).
- Disponer de los binarios instalados en el runner (`awscli`, `jq`, `mysql`, `mysqldump`, `gzip`, `curl`).

Si usas `ubuntu-latest`, instala estas dependencias en un paso previo:

~~~yaml
- name: Instalar dependencias
  run: sudo apt-get update && sudo apt-get install -y mysql-client jq gzip curl
~~~

  **Recomendación**: Usa entornos aislados o cuentas dedicadas para operaciones de restauración y validación de integridad.

---

## ⚙️ Entradas de la Action

| Nombre          | Requerido   | Descripción                                                                                          |
| --------------- | ----------- | -----------------------------------------------------------------------------------------------------|
| `mode`          |    ✅ Sí    | Modo de operación: `extraer` o `restaurar`.                                                          |
| `secret_origin` | Condicional | Nombre del secreto de origen (obligatorio en `extraer`).                                             |
| `secret_dest`   | Condicional | Nombre del secreto de destino (obligatorio en `restaurar`).                                          |
| `presigned_url` | Condicional | URL presignada del dump a restaurar (obligatorio en `restaurar`).                                    |
| `ttl`           | Opcional    | Tiempo en segundos de validez de la URL pre-firmada (por defecto 7200).                              |
| `aws_region`    |    ✅ Sí    | Región AWS donde residen los recursos.                                                               |

---

### 📊 Tabla de combinaciones requeridas por modo

| Modo      | secret_origin | secret_dest | presigned_url | ttl      |
| --------- | ------------- | ----------- | ------------- | -------- |
| extraer   |      ✅       |             |               | opcional |
| restaurar |               |     ✅      |      ✅       |          |

---

## 🔍 Funcionamiento Detallado

La Action opera de la siguiente forma según el modo:

### 🟢 Modo `extraer`

  1. Asume el rol, configurado en los secrtos del repo, en la cuenta origen.
  2. Recupera las credenciales y detalles de conexión desde Secrets Manager.
  3. Abre acceso temporal en el grupo de seguridad RDS (puerto 3306).
  4. Realiza `mysqldump` de la base de datos (excluyendo tablas `revisions` y `domains`).
  5. Cierra el acceso temporal a la base de datos.
  6. Comprime el dump en Gzip.
  7. Sube el archivo al bucket S3.
  8. Genera una URL pre-firmada.
  9. Devuelve la URL en el output `presigned_url`.

---

### 🟡 Modo `restaurar`

  1. Asume el rol, configurado en los secrtos del repo, en la cuenta  destino.
  2. Recupera credenciales de la base destino.
  3. Descarga el dump desde la URL presignada.
  4. Descomprime y filtra inserciones de usuarios `admin` o `bot`.
  5. Abre acceso temporal a RDS destino.
  6. Restaura el dump en la base especificada.
  7. Cierra el acceso temporal.

---

### 🟣 Convención `completo` (a nivel de workflow)

La Action en sí no expone un modo `completo`: para una migración extremo a extremo el workflow encadena `extraer` y `restaurar` en steps separados, intercalando un `configure-aws-credentials` entre ellos. De este modo:

  1. Se asume el role de la cuenta **origen** y se ejecuta `extraer`.
  2. Se asume el role de la cuenta **destino** y se ejecuta `restaurar` consumiendo la URL presignada del paso anterior.

Si origen y destino están en la misma cuenta, ambos pasos asumen el mismo role (operación idéntica, sin sobrecoste relevante). Si están en cuentas distintas, cada paso obtiene su propio token OIDC para el role correspondiente. El [example.md](example.md) muestra cómo exponer esta opción al usuario bajo la entrada `completo` del `workflow_dispatch`.

---

## 🧩 Ejemplos

### Ejemplo del workflow apicado a un repo

En el este [enlace](example.md) se encuentra un ejemplo completo del workflow tal y como se aplicaria en un repositorio real. En el caso de que los secretos arriba mencionados estuvieran configurados correctamente, funcionaria sin problemas.

### Ejemplos prácticos

| Origen | Destino | Modo workflow | Comentario                                                                         |
| ------ | ------- | ------------- | ---------------------------------------------------------------------------------- |
| `pro`  | N/A     | `extraer`     | Dump de Producción                                                                 |
| `stg`  | `dev`   | `completo`    | Mover datos de staging a desarrollo (encadena extraer + restaurar en un solo run)  |
| `dev`  | `stg`   | `restaurar`   | Restaurar dump dev en staging manualmente a partir de una URL presignada existente |

## 🔐 Seguridad y Buenas Prácticas

- ✅ **No se permiten restauraciones en entornos de producción** (`*_pro`), están bloqueadas por defecto.
- ✅ El **acceso mediante OIDC** esta limitado a los repositorios configurados.
- ✅ Se usa un **bucket S3 dedicado** a estos backups en la cuenta de origen, con ciclo de vida de objetos.
- ✅ El **rol asumido en AWS tiene limitaciones** sobre lo que puede hacer y a lo que puede acceder dentro de la cuenta.
- ✅ **No se almacenan credenciales** en código fuente.
- ✅ Los **secretos del repositorio no se exponen** en la salida de la accion ni en los logs.
- ✅ **Los volcados quedan en S3** solo durante el tiempo definido por el TTL y **maximo por 24 Horas**.
- ✅ **El acceso al puerto MySQL** se abre exclusivamente al runner y **se cierra inmediatamente tras finalizar**.
- ✅ Los ficheros locales se eliminan y los runners son efimeros.

---

## 🏷️ Versionado y tags

Esta Action se publica con dos tipos de tag:

- **Tags exactas por release** (ej. `v0.4.0`, `v0.4.1`): apuntan a un commit concreto y son inmutables. Úsalas si necesitas reproducibilidad estricta.
- **Tags flotantes por minor** (ej. `v0.4`): apuntan al último patch publicado dentro de ese minor. Úsalas en los workflows de los clientes para recibir parches automáticamente sin tener que abrir un PR por cada bump.

Referencia recomendada en los workflows:

~~~yaml
uses: Griddo-infra/gha-grd-dbdt@v0.4
~~~

### Mantenimiento de tags flotantes

Cuando se publica una nueva versión patch (por ejemplo `v0.4.1`), hay que **mover la tag flotante** correspondiente al commit del nuevo release:

~~~bash
# desde el repo del action
git tag -f v0.4 v0.4.1
git push -f origin v0.4
~~~

Al crear una nueva versión minor (por ejemplo `v0.5.0`), se crea una nueva tag flotante:

~~~bash
git tag v0.5 v0.5.0
git push origin v0.5
~~~

⚠️ Las tags flotantes se mueven con `--force`; las tags exactas (`vX.Y.Z`) **nunca** deben moverse.

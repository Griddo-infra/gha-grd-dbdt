# AWS RDS Dump & Restore GitHub Action

## 📘 Descripción General

Esta GitHub Action permite automatizar de manera segura y reproducible la gestión de volcados (dumps) y restauraciones de bases de datos MySQL/MariaDB alojadas en AWS RDS. El flujo soporta:

  - **Extracción** de un dump cifrado y comprimido.
  - **Carga** del dump en un bucket S3 con generación de URL presignada.
  - **Descarga y restauración** en otra base de datos RDS.
  - **Filtrado automático** de datos sensibles (por defecto, inserciones de usuarios `admin` o `bot`).

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
arn:aws:iam::<ACCOUNT_ID>:role/DBDumpRole
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

| Nombre                   | Requerido   | Descripción                                                                                                  |
| ------------------------ | ----------- | ------------------------------------------------------------------------------------------------------------ |
| `mode`                   | ✅ Sí       | Modo de operación: `extraer`, `restaurar` o `completo`.                                                      |
| `aws_account_id_origen`  | Condicional | ID de la cuenta AWS origen donde reside la base de datos origen.                                             |
| `aws_account_id_destino` | Condicional | ID de la cuenta AWS destino donde reside la base de datos destino (obligatorio en `restaurar` y `completo`). |
| `secreto_origen`         | Condicional | Nombre del secreto con las credenciales de la base origen.                                                   |
| `secreto_destino`        | Condicional | Nombre del secreto con las credenciales de la base destino (obligatorio en `restaurar` y `completo`).        |
| `presigned_url`          | Opcional    | URL presignada del dump a restaurar. obligatorio en `restaurar`. Ignorada en otros modos.                    |
| `ttl`                    | Opcional    | Tiempo en segundos de validez de la URL pre-firmadas (por defecto 7200, obligatorio en `restaurar`).         |

---

### 📊 Tabla de combinaciones requeridas por modo
| Modo      | aws_account_id_origen | secreto_origen | aws_account_id_destino | secreto_destino | presigned_url | ttl      |
| --------- | --------------------- | -------------- | ---------------------- | --------------- | ------------- | -------- |
| extraer   |         ✅            |       ✅			 |                        |                 |               | opcional |
| restaurar	|      		              |                |         	✅	           |       ✅        |       ✅      |          |
| completo	|         ✅            |       ✅       |          ✅	           |       ✅        |               |	         |

---

## 🔍 Funcionamiento Detallado

La Action opera de la siguiente forma según el modo:

### 🟢 Modo `extraer`

  1. Asume el rol `DBDumpRole` en la cuenta origen.
  2. Recupera las credenciales y detalles de conexión desde Secrets Manager.
  3. Abre acceso temporal en el grupo de seguridad RDS (puerto 3306).
  4. Realiza `mysqldump` de la base de datos (excluyendo tablas `revision` y `domains`).
  5. Comprime el dump en Gzip.
  6. Sube el archivo al bucket S3.
  7. Genera una URL presignada.
  8. Devuelve la URL en el output `presigned_url`.

---

### 🟡 Modo `restaurar`

  1. Asume el rol `DBDumpRole` en la cuenta destino.
  2. Recupera credenciales de la base destino.
  3. Descarga el dump desde la URL presignada.
  4. Descomprime y filtra inserciones de usuarios `admin` o `bot`.
  5. Abre acceso temporal a RDS destino.
  6. Restaura el dump en la base especificada.
  7. Cierra el acceso temporal.

--- 

### 🟣 Modo `completo`

Combina ambos pasos:
  1. Primero ejecuta extraer.
  2. Luego toma la URL generada y ejecuta restaurar.

**Nota**: Si las cuentas origen y destino coinciden, la Action optimiza el flujo para no re-asumir el rol.

---

## 🧩 Ejemplos de Uso

### Ejemplo 1: Extraer Dump

~~~yaml
jobs:
  extraer-dump:
    runs-on: ubuntu-latest
    steps:
      - name: Hacemos un Pull del Repositorio
        uses: actions/checkout@v4

      - name: Configuramos los Credenciales de AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsRole
          aws-region: us-west-2

      - name: Instalamos dependencias
        run: sudo apt-get update && sudo apt-get install -y mysql-client jq gzip curl
      
      - name: Realizadmos el volcado desde RDS
        id: dump
        uses: Griddo-infra/gha-grd-dbdt@0.2
        with:
          mode: extraer
          aws_account_id_origen: "123456789012"
          secreto_origen: "mi-secreto-origen"
          ttl: "3600"
      
      - name: Publicamos la URL pre-firmada en el Resumen
        run: echo "URL pre-firmada generada: ${{ steps.dump.outputs.presigned_url }}"
~~~

### Ejemplo 2: Restaurar Dump

~~~yaml
jobs:
  restaurar-dump:
    runs-on: ubuntu-latest
    steps:
      - name: Hacemos un Pull del Repositorio
        uses: actions/checkout@v4

      - name: Configuramos los Credenciales de AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsRole
          aws-region: us-west-2

      - name: Instalamos dependencias
        run: sudo apt-get update && sudo apt-get install -y mysql-client jq gzip curl
      
      - name: Validar que el destino no sea Produccion
        run: |
            if [[ "${{ inputs.secreto_destino }}" == *_pro* ]]; then
            echo "ERROR: No está permitido restaurar en un entorno _pro."
            exit 1
            fi

      - name: Restauramos el volcado de RDS
        uses: Griddo-infra/gha-grd-dbdt@0.2
        with:
          mode: restaurar
          aws_account_id_destino: "987654321098"
          secreto_destino: "mi-secreto-destino"
          presigned_url: "https://s3.amazonaws.com/..."
~~~

### Ejemplo 3: Flujo Completo

~~~yaml
jobs:
  completo:
    runs-on: ubuntu-latest
    steps:
      - name: Hacemos un Pull del Repositorio
        uses: actions/checkout@v4

      - name: Configuramos los Credenciales de AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsRole
          aws-region: us-west-2

      - name: Instalamos dependencias
        run: sudo apt-get update && sudo apt-get install -y mysql-client jq gzip curl
      
      - name: Validar que el destino no sea Produccion
        run: |
            if [[ "${{ inputs.secreto_destino }}" == *_pro* ]]; then
            echo "ERROR: No está permitido restaurar en un entorno _pro."
            exit 1
            fi

      - name: Extraer y Restaurar volcado de RDS
        uses: Griddo-infra/gha-grd-dbdt@0.2
        with:
          mode: completo
          aws_account_id_origen: "123456789012"
          secreto_origen: "mi-secreto-origen"
          aws_account_id_destino: "987654321098"
          secreto_destino: "mi-secreto-destino"
          ttl: "7200"
~~~

## 🔐 Seguridad y Buenas Prácticas

- ✅ **No se permiten restauraciones en entornos de producción** (`*_pro`), están bloqueadas por defecto.
- ✅ Se usa un bucket S3 dedicados a estos backups en la cuenta de origen, con ciclo de vida de objetos.
- ✅ **Los secretos solo son accesibles** por el rol `DBDumpRole`.
- ✅ **No se almacenan credenciales** en código fuente.
- ✅ **Los volcados quedan en S3** solo durante el tiempo definido por el TTL y **maximo por 24 Horas**.
- ✅ **El acceso al puerto MySQL** se abre exclusivamente al runner y **se cierra inmediatamente tras finalizar**.
- ✅ Los ficheros locales se eliminan con shred para evitar recuperación.

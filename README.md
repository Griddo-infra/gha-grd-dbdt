# 📘 GitHub Action – Volcado y Restauración de Bases de Datos RDS Multi-Cuenta

Esta Action permite realizar volcados (dumps) y restauraciones de bases de datos MySQL/MariaDB alojadas en AWS RDS, operando en entornos multi-cuenta y utilizando AWS Secrets Manager y S3.

Se soportan tres modos de ejecución:

- extract

  - Realiza el volcado y sube el dump comprimido a S3.

  - Devuelve una URL pre-firmadas para descargar el dump.

- restore

  - Descarga un dump comprimido desde una URL pre-firmadas y lo restaura en la base de datos destino.

- completo

  - Realiza ambas operaciones en secuencia: dump en origen + restauración en destino.

Incluye la capacidad de apertura temporal del puerto 3306 si la base *_pro no es accesible desde internet.

## 🛠 Requisitos

- Repositorio con permisos adecuados para ejecutar GitHub Actions.

- Rol IAM en cada cuenta AWS con permisos de:

        rds:DescribeDBInstances

        rds:ModifyDBInstance

        ec2:AuthorizeSecurityGroupIngress

        ec2:RevokeSecurityGroupIngress

        s3:PutObject
        
        s3:GetObject

        secretsmanager:GetSecretValue

        sts:AssumeRole

- El secreto de la base de datos debe contener los siguientes campos:
    ```json
        {
        "endpoint": "xxxx.rds.amazonaws.com",
        "username": "admin",
        "password": "password",
        "db_instance_identifier": "rds-instance-id",
        "s3_bucket": "nombre-del-bucket"
        }
    ```

## 🎛 Entradas (inputs)
| Nombre                  | Requerido | Descripción                                                                                                |
| ----------------------- | --------- | ---------------------------------------------------------------------------------------------------------- |
| `mode`                  | Sí        | Modo de operación: `extract`, `restore` o `completo`.                                                      |
| `aws_account_id_source` | Sí        | ID de la cuenta AWS origen donde reside la base de datos origen.                                           |
| `aws_account_id_dest`   | No        | ID de la cuenta AWS destino donde reside la base de datos destino (obligatorio en `restore` o `completo`). |
| `secret_name`           | Sí        | Nombre del secreto con las credenciales de la base origen.                                                 |
| `secret_name_dest`      | No        | Nombre del secreto con las credenciales de la base destino (obligatorio en `restore` o `completo`).        |
| `ttl`                   | No        | Tiempo en segundos de validez de la URL pre-firmadas (por defecto 7200).                                     |

---
## 🚦 Ejemplos de uso del Workflow
### 🟢 Modo extract (dump y subida a S3)
```yaml
name: Dump Base de Datos

on:
  workflow_dispatch:

jobs:
  dump:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Realizar dump y obtener URL
        id: dump
        uses: ./github/actions/db-dump-restore
        with:
          mode: extract
          aws_account_id_source: "111111111111"
          secret_name: "pruebas_pro"
          ttl: "3600"

      - name: Mostrar URL de descarga
        run: echo "URL pre-firmadas: ${{ steps.dump.outputs.presigned-url }}"
```
### 🟡 Modo restore (descargar dump y restaurar)
```yaml
name: Restaurar Base de Datos

on:
  workflow_dispatch:

jobs:
  restore:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Validar que el destino no sea _pro
        run: |
            if [[ "${{ inputs.secret_name_dest }}" == *_pro* ]]; then
            echo "ERROR: No está permitido restaurar en un entorno _pro."
            exit 1
            fi

      - name: Restaurar desde dump
        uses: ./github/actions/db-dump-restore
        with:
          mode: restore
          aws_account_id_dest: "222222222222"
          secret_name_dest: "pruebas_dev"
          url_presigned: "https://bucket.s3.amazonaws.com/dump_xxxxx.sql.gz?..."
```
### 🟣 Modo completo (extraer y restaurar entre cuentas)
```yaml
name: Clonar Base de Datos Pro -> Dev

on:
  workflow_dispatch:

jobs:
  clone:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      
      - name: Validar que el destino no sea _pro
        run: |
            if [[ "${{ inputs.secret_name_dest }}" == *_pro* ]]; then
            echo "ERROR: No está permitido restaurar en un entorno _pro."
            exit 1
            fi

      - name: Dump y restauración completa
        id: full
        uses: ./github/actions/db-dump-restore
        with:
          mode: completo
          aws_account_id_source: "111111111111"
          aws_account_id_dest: "222222222222"
          secret_name: "pruebas_pro"
          secret_name_dest: "pruebas_dev"
          ttl: "7200"

      - name: Mostrar URL pre-firmadas
        run: echo "Dump disponible temporalmente en: ${{ steps.full.outputs.presigned-url }}"
```
## 🧩 Funcionamiento interno

1. Assume Role:

    - Se asume un rol IAM en la cuenta de origen para operaciones de dump.

    - Si es necesario, se asume un rol distinto en la cuenta de destino para la restauración.

2. Apertura temporal:

    - Si la base *_pro no es accesible, abre dinámicamente la IP del runner en el security group.

    - El acceso se revoca tras el dump.

3. Dump y filtrado:

    - Se genera el volcado con mysqldump.

    - Se filtran las tablas revision, domains y usuarios admin, bot.

4. S3 Presigned URL:

    - El dump se sube comprimido a S3.

    - Se devuelve una URL pre-firmadas con caducidad (ttl).

5. Restauración:

    - El dump se descarga y se importa en el destino.

## 🔐 Consideraciones de seguridad

- Los dumps quedan en S3 solo durante el tiempo definido por el TTL.

- El acceso al puerto MySQL se abre exclusivamente al runner y se cierra inmediatamente tras finalizar.

- Los ficheros locales se eliminan con shred para evitar recuperación.


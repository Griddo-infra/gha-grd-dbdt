#!/usr/bin/env bash
set -euo pipefail

# Trap para limpiar recursos al salir si ocurre un fallo inesperado
trap clean_up EXIT

# Variables de entorno inyectadas por GitHub Actions (pueden venir vacías)
MODE="${MODE:-}"
AWS_ACCOUNT_ID_ORIGEN="${AWS_ACCOUNT_ID_ORIGEN:-}"
SECRETO_ORIGEN="${SECRETO_ORIGEN:-}"
AWS_ACCOUNT_ID_DESTINO="${AWS_ACCOUNT_ID_DESTINO:-}"
SECRETO_DESTINO="${SECRETO_DESTINO:-}"
TTL="${TTL:-7200}"
URL_PRESIGNED="${URL_PRESIGNED:-}"

# Variables para almacenar Security Group e IP abiertas temporalmente
OPENED_SG_ID=""
OPENED_MY_IP=""

# Crear directorio temporal y definir rutas de dump
TMP_DIR=$(mktemp -d)
DUMP_FILE="$TMP_DIR/dump.sql"
DUMP_FILE_GZ="$DUMP_FILE.gz"

# ---------------------------------------
# Función para limpiar recursos al salir
# ---------------------------------------
clean_up() {
  echo "[*] Limpiando recursos..."
  # Cierra acceso abierto si existe
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    echo "[*] Cerrando acceso temporal en SG $OPENED_SG_ID para $OPENED_MY_IP..."
    aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" || true
  fi

  # Borrar archivos temporales si existen
  shred -u "$DUMP_FILE" || true
  shred -u "$DUMP_FILE_GZ" || true
  rm -rf "$TMP_DIR"
}

# ----------------------------------------------------
# Asume un rol IAM y exporta las credenciales AWS
# ----------------------------------------------------
assume_role() {
  local role_arn=$1
  echo "[*] Asumiendo rol: $role_arn"
  CREDS_JSON=$(aws sts assume-role --role-arn "$role_arn" --role-session-name dbdt-session --duration-seconds 3600)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS_JSON" | jq -r '.Credentials.SessionToken')
}

# ---------------------------------------
# Obtiene secreto desde AWS Secrets Manager
# ---------------------------------------
get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

# ------------------------------------------------
# Abre acceso temporal al puerto 3306 en el SG RDS
# ------------------------------------------------
open_temporary_access() {
  local db_instance_id=$1
  echo "[*] Obteniendo Security Group de RDS $db_instance_id..."
  SG_ID=$(aws rds describe-db-instances \
    --db-instance-identifier "$db_instance_id" \
    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)

  MY_IP=$(curl -s https://checkip.amazonaws.com)/32
  echo "[*] IP pública actual: $MY_IP"

  # Verifica si la regla ya existe para no duplicar
  EXISTING=$(aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`3306\` && IpRanges[?CidrIp=='$MY_IP']]" \
    --output json)
  if [[ "$EXISTING" != "[]" ]]; then
    echo "[*] Ya existe la regla para $MY_IP."
  else
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP"
    echo "[*] Acceso temporal concedido."
  fi

  OPENED_SG_ID="$SG_ID"
  OPENED_MY_IP="$MY_IP"
}

# -----------------------------------------------
# Cierra acceso temporal al puerto 3306 en el SG
# -----------------------------------------------
close_temporary_access() {
  local sg_id=$1
  local my_ip=$2
  echo "[*] Cerrando acceso temporal en SG $sg_id para $my_ip..."
  aws ec2 revoke-security-group-ingress --group-id "$sg_id" --protocol tcp --port 3306 --cidr "$my_ip" || true
}

# -----------------------------------------------
# Filtra el dump para excluir inserciones sensibles
# -----------------------------------------------
filter_dump() {
  grep -v -E "INSERT INTO \`?users\`?.*'(admin|bot)'" "$1" > "$2"
}

# -----------------------------------------------
# Modo extraer: realiza dump, comprime y sube a S3
# -----------------------------------------------
if [[ "$MODE" == "extraer" ]]; then
  ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID_ORIGEN:role/DBDumpRole"
  assume_role "$ROLE_ARN"

  SECRET=$(get_secret "$SECRETO_ORIGEN")
  ENDPOINT=$(echo "$SECRET" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET" | jq -r '.username')
  PASSWORD=$(echo "$SECRET" | jq -r '.password')
  DB_INSTANCE=$(echo "$SECRET" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET" | jq -r '.database')

  open_temporary_access "$DB_INSTANCE"

  mysqldump --single-transaction --quick --lock-tables=false \
    --ignore-table="${DATABASE}.revision" \
    --ignore-table="${DATABASE}.domains" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"

  gzip "$DUMP_FILE"
  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"

  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME"

  # Cerramos acceso nada más subir el dump para no dejar puerto abierto
  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
  OPENED_SG_ID=""
  OPENED_MY_IP=""

  URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --expires-in "$TTL")

  echo "presigned-url=$URL" >> "$GITHUB_OUTPUT"
fi

# -----------------------------------------------
# Modo restaurar: descarga, filtra y restaura dump
# -----------------------------------------------
if [[ "$MODE" == "restaurar" ]]; then
  # Validación para no restaurar sobre entorno _pro
  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "::error::No se permite restaurar sobre _pro"
    exit 1
  fi

  ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID_DESTINO:role/DBDumpRole"
  assume_role "$ROLE_ARN"

  SECRET=$(get_secret "$SECRETO_DESTINO")
  ENDPOINT=$(echo "$SECRET" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET" | jq -r '.username')
  PASSWORD=$(echo "$SECRET" | jq -r '.password')
  DATABASE=$(echo "$SECRET" | jq -r '.database')
  DB_INSTANCE=$(echo "$SECRET" | jq -r '.db_instance_identifier')

  curl -s -o "$DUMP_FILE_GZ" "$URL_PRESIGNED"
  gzip -d "$DUMP_FILE_GZ"

  FILTERED="$TMP_DIR/filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED"

  open_temporary_access "$DB_INSTANCE"

  mysql -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" < "$FILTERED"

  # Cerramos acceso justo después de restaurar
  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
  OPENED_SG_ID=""
  OPENED_MY_IP=""
fi

# -----------------------------------------------
# Modo completo: extraer y restaurar en la misma ejecución
# -----------------------------------------------
if [[ "$MODE" == "completo" ]]; then
  # Validación para no restaurar sobre entorno _pro
  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "::error::No se permite restaurar sobre _pro"
    exit 1
  fi

  # Primera parte: extracción y subida
  ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID_ORIGEN:role/DBDumpRole"
  assume_role "$ROLE_ARN"

  SECRET=$(get_secret "$SECRETO_ORIGEN")
  ENDPOINT=$(echo "$SECRET" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET" | jq -r '.username')
  PASSWORD=$(echo "$SECRET" | jq -r '.password')
  DB_INSTANCE=$(echo "$SECRET" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET" | jq -r '.database')

  open_temporary_access "$DB_INSTANCE"

  mysqldump --single-transaction --quick --lock-tables=false \
    --ignore-table="${DATABASE}.revision" \
    --ignore-table="${DATABASE}.domains" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"

  gzip "$DUMP_FILE"
  FILE="dump_$(date +%Y%m%d_%H%M%S).sql.gz"

  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILE"

  # Cerramos acceso al origen inmediatamente tras subir el dump
  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
  OPENED_SG_ID=""
  OPENED_MY_IP=""

  URL=$(aws s3 presign "s3://$S3_BUCKET/$FILE" --expires-in "$TTL")

  # Segunda parte: restauración
  ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID_DESTINO:role/DBDumpRole"
  assume_role "$ROLE_ARN"

  SECRET=$(get_secret "$SECRETO_DESTINO")
  ENDPOINT=$(echo "$SECRET" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET" | jq -r '.username')
  PASSWORD=$(echo "$SECRET" | jq -r '.password')
  DATABASE=$(echo "$SECRET" | jq -r '.database')
  DB_INSTANCE=$(echo "$SECRET" | jq -r '.db_instance_identifier')

  curl -s -o "$DUMP_FILE_GZ" "$URL"
  gzip -d "$DUMP_FILE_GZ"

  FILTERED="$TMP_DIR/filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED"

  open_temporary_access "$DB_INSTANCE"

  mysql -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" < "$FILTERED"

  # Cerramos acceso a destino al terminar restauración
  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
  OPENED_SG_ID=""
  OPENED_MY_IP=""

  echo "presigned-url=$URL" >> "$GITHUB_OUTPUT"
fi

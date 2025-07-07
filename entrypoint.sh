#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

# === VARIABLES DE EJECUCIÓN DESDE GITHUB ACTION INPUTS ===
MODE="${1:-}"
AWS_ACCOUNT_ID_ORIGEN="${2:-}"
SECRETO_ORIGEN="${3:-}"
AWS_ACCOUNT_ID_DESTINO="${4:-}"
SECRETO_DESTINO="${5:-}"
PRESIGNED_URL_INPUT="${6:-}"
TTL="${7:-7200}"

# Inicializamos flags
_CLEANED_UP=0
OPENED_SG_ID=""
OPENED_MY_IP=""
PRESIGNED_URL=""

TMP_DIR=$(mktemp -d)
DUMP_FILE="$TMP_DIR/dump.sql"
DUMP_FILE_GZ="$DUMP_FILE.gz"

trap clean_up EXIT

# --- FUNCIONES AUXILIARES ---
clean_up() {
  if [[ $_CLEANED_UP -eq 1 ]]; then return; fi
  _CLEANED_UP=1
  echo "[*] Limpieza de recursos..."
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    aws ec2 revoke-security-group-ingress \
      --group-id "$OPENED_SG_ID" \
      --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" || true
  fi
  shred -u "$DUMP_FILE" "$DUMP_FILE_GZ" 2>/dev/null || true
  rm -rf "$TMP_DIR"
  echo "[*] Cleanup completado."
}

assume_role() {
  local role_arn="$1"
  echo "[*] Asumiendo rol: $role_arn"
  local creds_json
  creds_json=$(aws sts assume-role --role-arn "$role_arn" --role-session-name dbdt-session --duration-seconds 3600)
  export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' <<< "$creds_json")
  export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' <<< "$creds_json")
  export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' <<< "$creds_json")
}

get_secret() {
  local secret_name="$1"
  aws secretsmanager get-secret-value --secret-id "$secret_name" --query SecretString --output text
}

open_temporary_access() {
  local db_instance_id="$1"
  SG_ID=$(aws rds describe-db-instances --db-instance-identifier "$db_instance_id" \
    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
  OPENED_SG_ID="$SG_ID"
  MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
  OPENED_MY_IP="$MY_IP"
  echo "[*] Abriendo acceso temporal en SG $SG_ID para IP $MY_IP"
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP" || true
}

close_temporary_access() {
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    echo "[*] Cerrando acceso temporal..."
    aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" || true
  fi
  OPENED_SG_ID=""
  OPENED_MY_IP=""
}

filter_dump() {
  local input="$1"
  local output="$2"
  grep -v -E "INSERT INTO \`?users\`?.*'(admin|bot)'" "$input" > "$output"
}

# --- MODO EXTRAER ---
modo_extraer() {
  assume_role "arn:aws:iam::$AWS_ACCOUNT_ID_ORIGEN:role/DBDumpRole"
  local secret_json
  secret_json=$(get_secret "$SECRETO_ORIGEN")
  ENDPOINT=$(jq -r '.endpoint' <<< "$secret_json")
  USERNAME=$(jq -r '.username' <<< "$secret_json")
  PASSWORD=$(jq -r '.password' <<< "$secret_json")
  DATABASE=$(jq -r '.database' <<< "$secret_json")
  DB_INSTANCE_ID=$(jq -r '.db_instance_identifier' <<< "$secret_json")
  S3_BUCKET=$(jq -r '.s3_bucket' <<< "$secret_json")
  open_temporary_access "$DB_INSTANCE_ID"

  echo "[*] Volcando base de datos $DATABASE"
  mysqldump --single-transaction --quick --lock-tables=false \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"
  close_temporary_access
  gzip "$DUMP_FILE"
  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME"
  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --expires-in "$TTL")
  echo "presigned_url=$PRESIGNED_URL" >> $GITHUB_OUTPUT
}

# --- MODO RESTAURAR ---
modo_restaurar() {
  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "ERROR: No está permitido restaurar en entornos _pro."
    exit 1
  fi
  assume_role "arn:aws:iam::$AWS_ACCOUNT_ID_DESTINO:role/DBDumpRole"
  local secret_json
  secret_json=$(get_secret "$SECRETO_DESTINO")
  ENDPOINT=$(jq -r '.endpoint' <<< "$secret_json")
  USERNAME=$(jq -r '.username' <<< "$secret_json")
  PASSWORD=$(jq -r '.password' <<< "$secret_json")
  DATABASE=$(jq -r '.database' <<< "$secret_json")
  DB_INSTANCE_ID=$(jq -r '.db_instance_identifier' <<< "$secret_json")
  curl -s -o "$DUMP_FILE_GZ" "$PRESIGNED_URL_INPUT"
  gzip -d "$DUMP_FILE_GZ"
  FILTERED="$TMP_DIR/dump_filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED"
  open_temporary_access "$DB_INSTANCE_ID"
  mysql -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" < "$FILTERED"
  close_temporary_access
  echo "[+] Restauración completada."
}

# --- MODO COMPLETO ---
modo_completo() {
  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "ERROR: No se permite restaurar en entornos _pro."
    exit 1
  fi
  modo_extraer
  PRESIGNED_URL_INPUT="$PRESIGNED_URL"
  modo_restaurar
}

# --- EJECUCIÓN SEGÚN MODO ---
case "$MODE" in
  extraer)
    modo_extraer
    ;;
  restaurar)
    modo_restaurar
    ;;
  completo)
    modo_completo
    ;;
  *)
    echo "ERROR: Modo no reconocido: $MODE"
    exit 1
    ;;
esac

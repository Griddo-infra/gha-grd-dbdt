#!/bin/bash
set -euo pipefail

MODE="${INPUT_MODE}"
AWS_ACCOUNT_ID_SOURCE="${INPUT_AWS_ACCOUNT_ID_SOURCE}"
AWS_ACCOUNT_ID_DEST="${INPUT_AWS_ACCOUNT_ID_DEST:-}"
SECRET_NAME="${INPUT_SECRET_NAME}"
SECRET_NAME_DEST="${INPUT_SECRET_NAME_DEST:-}"
TTL="${INPUT_TTL:-7200}"

TMP_DIR=$(mktemp -d)
DUMP_FILE="$TMP_DIR/dump.sql"
DUMP_FILE_GZ="$DUMP_FILE.gz"

clean_up() {
  echo "[*] Limpiando ficheros temporales..."
  if [[ -f "$DUMP_FILE" ]]; then shred -u "$DUMP_FILE"; fi
  if [[ -f "$DUMP_FILE_GZ" ]]; then shred -u "$DUMP_FILE_GZ"; fi
  rm -rf "$TMP_DIR"
}

assume_role() {
  local role_arn=$1
  echo "[*] Asumiendo rol: $role_arn"
  CREDS_JSON=$(aws sts assume-role --role-arn "$role_arn" --role-session-name dbdt-session --duration-seconds 3600)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS_JSON" | jq -r '.Credentials.SessionToken')
}

get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text
}

open_temporary_access() {
  local db_instance_id=$1
  SG_ID=$(aws rds describe-db-instances --db-instance-identifier "$db_instance_id" \
    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
  MY_IP=$(curl -s https://checkip.amazonaws.com)/32
  echo "[*] Abriendo acceso temporal a $MY_IP en SG $SG_ID..."
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP"
  echo "$SG_ID $MY_IP"
}

close_temporary_access() {
  aws ec2 revoke-security-group-ingress --group-id "$1" --protocol tcp --port 3306 --cidr "$2"
}

filter_dump() {
  grep -v -E "DROP TABLE IF EXISTS \`?(revision|domains)\`?" "$1" | \
  grep -v -E "CREATE TABLE \`?(revision|domains)\`?" | \
  grep -v -E "INSERT INTO \`?(revision|domains)\`?" | \
  grep -v -E "UPDATE \`?(revision|domains)\`?" | \
  grep -v -E "DELETE FROM \`?(revision|domains)\`?" | \
  grep -v -E "INSERT INTO \`?users\`?.*'(admin|bot)'" > "$2"
}

# Modo extract
if [[ "$MODE" == "extract" ]]; then
  ROLE_SRC="arn:aws:iam::${AWS_ACCOUNT_ID_SOURCE}:role/DBDumpRole"
  assume_role "$ROLE_SRC"

  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  DB_INSTANCE_ID=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.s3_bucket')

  if [[ "$SECRET_NAME" == *_pro ]]; then
    read -r SG_ID MY_IP <<< "$(open_temporary_access "$DB_INSTANCE_ID")"
    OPENED=1
  fi

  mysqldump --single-transaction --quick --lock-tables=false -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" --all-databases > "$DUMP_FILE"
  gzip "$DUMP_FILE"

  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME"
  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --expires-in "$TTL")

  echo "presigned-url=$PRESIGNED_URL" >> "$GITHUB_OUTPUT"

  if [[ -n "${OPENED:-}" ]]; then
    close_temporary_access "$SG_ID" "$MY_IP"
  fi

  clean_up
  exit 0
fi

# Modo restore
if [[ "$MODE" == "restore" ]]; then
  if [[ -z "${INPUT_URL_PRESIGNED:-}" ]]; then
    echo "ERROR: Se requiere la URL presignada en modo restore."
    exit 1
  fi
  if [[ -z "$SECRET_NAME_DEST" ]]; then
    echo "ERROR: 'secret_name_dest' obligatorio en modo restore."
    exit 1
  fi
  if [[ -z "$AWS_ACCOUNT_ID_DEST" ]]; then
    echo "ERROR: 'aws_account_id_dest' obligatorio en modo restore."
    exit 1
  fi

  ROLE_DEST="arn:aws:iam::${AWS_ACCOUNT_ID_DEST}:role/DBDumpRole"
  assume_role "$ROLE_DEST"

  SECRET_JSON=$(get_secret "$SECRET_NAME_DEST")
  ENDPOINT=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')

  curl -s -o "$DUMP_FILE_GZ" "$INPUT_URL_PRESIGNED"
  gzip -d "$DUMP_FILE_GZ"

  FILTERED_DUMP="$TMP_DIR/dump_filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED_DUMP"

  mysql -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" < "$FILTERED_DUMP"

  clean_up
  exit 0
fi

# Modo completo
if [[ "$MODE" == "completo" ]]; then
  if [[ -z "$SECRET_NAME_DEST" ]]; then
    echo "ERROR: 'secret_name_dest' obligatorio en modo completo."
    exit 1
  fi
  if [[ -z "$AWS_ACCOUNT_ID_DEST" ]]; then
    echo "ERROR: 'aws_account_id_dest' obligatorio en modo completo."
    exit 1
  fi

  ROLE_SRC="arn:aws:iam::${AWS_ACCOUNT_ID_SOURCE}:role/DBDumpRole"
  assume_role "$ROLE_SRC"

  SECRET_JSON_SRC=$(get_secret "$SECRET_NAME")
  ENDPOINT_SRC=$(echo "$SECRET_JSON_SRC" | jq -r '.endpoint')
  USERNAME_SRC=$(echo "$SECRET_JSON_SRC" | jq -r '.username')
  PASSWORD_SRC=$(echo "$SECRET_JSON_SRC" | jq -r '.password')
  DB_INSTANCE_ID=$(echo "$SECRET_JSON_SRC" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET_JSON_SRC" | jq -r '.s3_bucket')

  if [[ "$SECRET_NAME" == *_pro ]]; then
    read -r SG_ID MY_IP <<< "$(open_temporary_access "$DB_INSTANCE_ID")"
    OPENED=1
  fi

  mysqldump --single-transaction --quick --lock-tables=false -h "$ENDPOINT_SRC" -u "$USERNAME_SRC" -p"$PASSWORD_SRC" --all-databases > "$DUMP_FILE"
  gzip "$DUMP_FILE"

  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME"
  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --expires-in "$TTL")

  if [[ -n "${OPENED:-}" ]]; then
    close_temporary_access "$SG_ID" "$MY_IP"
  fi

  ROLE_DEST="arn:aws:iam::${AWS_ACCOUNT_ID_DEST}:role/DBDumpRole"
  assume_role "$ROLE_DEST"

  SECRET_JSON_DEST=$(get_secret "$SECRET_NAME_DEST")
  ENDPOINT_DEST=$(echo "$SECRET_JSON_DEST" | jq -r '.endpoint')
  USERNAME_DEST=$(echo "$SECRET_JSON_DEST" | jq -r '.username')
  PASSWORD_DEST=$(echo "$SECRET_JSON_DEST" | jq -r '.password')

  curl -s -o "$DUMP_FILE_GZ" "$PRESIGNED_URL"
  gzip -d "$DUMP_FILE_GZ"

  FILTERED_DUMP="$TMP_DIR/dump_filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED_DUMP"

  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" < "$FILTERED_DUMP"

  clean_up

  echo "presigned-url=$PRESIGNED_URL" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "ERROR: Modo inválido: $MODE"
exit 1

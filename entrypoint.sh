#!/usr/bin/env bash
# Requiere: awscli, jq, mysql, mysqldump, gzip, curl
set -euo pipefail
if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
export AWS_PAGER=""
_CLEANED_UP=0

print_usage() {
  echo "Uso:"
  echo "  $0 extraer <SECRETO_ORIGEN> [<TTL_SEGUNDOS>]"
  echo "  $0 restaurar <SECRETO_DESTINO> <URL_PRESIGNED>"
  echo "  $0 completo <SECRETO_ORIGEN> <SECRETO_DESTINO> [<TTL_SEGUNDOS>]"
  exit 1
}

if [[ $# -lt 3 ]]; then
  print_usage
fi

MODE=$1
OPENED_SG_ID=""
OPENED_MY_IP=""
PRESIGNED_URL=""
TMP_DIR=$(mktemp -d)
DUMP_FILE="$TMP_DIR/dump.sql"
DUMP_FILE_GZ="$DUMP_FILE.gz"

trap clean_up EXIT

clean_up() {
  if [[ $_CLEANED_UP -eq 1 ]]; then
      return
  fi
  _CLEANED_UP=1
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    if ! aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" --output text; then
      echo "⚠️  No se pudo revocar la regla (posiblemente ya no existe)"
    fi
  fi
  if [[ -f "$DUMP_FILE" ]]; then rm -f "$DUMP_FILE"; fi
  if [[ -f "$DUMP_FILE_GZ" ]]; then rm -f "$DUMP_FILE_GZ"; fi
  rm -rf "$TMP_DIR"  
}

get_secret() {
  local secret_name=$1
  aws secretsmanager get-secret-value --secret-id "$secret_name" --query SecretString --output text
}

open_temporary_access() {
  local db_instance_id=$1
  SG_ID=$(aws rds describe-db-instances \
    --db-instance-identifier "$db_instance_id" \
    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)
  OPENED_SG_ID="$SG_ID"
  MY_IP_PROVIDER="${MY_IP_PROVIDER:-https://checkip.amazonaws.com}"
  MY_IP=$(curl -s "$MY_IP_PROVIDER")/32
  OPENED_MY_IP="$MY_IP"
  EXISTING_RULE=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='$MY_IP']]" --output text)
  if [ -z "$EXISTING_RULE" ]; then
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP" --output text
  fi
}

close_temporary_access() {
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    if ! aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" --output text; then
      echo "⚠️  No se pudo revocar la regla (posiblemente ya no existe)"
    fi
  fi
  OPENED_SG_ID=""
  OPENED_MY_IP=""
}

filter_dump() {
  local input_file=$1
  local output_file=$2
  grep -v -E "INSERT INTO \`?users\`?.*'(admin|bot)'" "$1" > "$2"
}

modo_extraer() {
  local SECRET_NAME=$1
  local TTL=${2:-7200}

  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  DB_INSTANCE_ID=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET_JSON" | jq -r '.database')

  open_temporary_access "$DB_INSTANCE_ID"

  mysqldump --verbose --single-transaction --quick --skip-lock-tables --set-gtid-purged=OFF \
    --ignore-table="${DATABASE}.revisions" --ignore-table="${DATABASE}.domains" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"

  gzip "$DUMP_FILE"

  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME" \
    --region "$AWS_REGION" --metadata-directive REPLACE \
    --content-disposition "attachment; filename=\"$FILENAME\""

  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --endpoint-url "https://s3.${AWS_REGION}.amazonaws.com" --expires-in "$TTL" --region "$AWS_REGION" --output text)
  echo "presigned_url=$PRESIGNED_URL" >> $GITHUB_OUTPUT
}

modo_restaurar() {
  local SECRET_NAME=$1
  local URL_PRESIGNED=$2

  if [[ "$SECRET_NAME" == *_pro* ]]; then
    echo "ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT_DEST=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME_DEST=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD_DEST=$(echo "$SECRET_JSON" | jq -r '.password')
  DATABASE_DEST=$(echo "$SECRET_JSON" | jq -r '.database')
  DB_INSTANCE_ID_DEST=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')

  curl -s -o "$DUMP_FILE_GZ" "$URL_PRESIGNED"

  gzip -d "$DUMP_FILE_GZ"

  FILTERED_DUMP="$TMP_DIR/dump_filtered.sql"
  filter_dump "$DUMP_FILE" "$FILTERED_DUMP"

  open_temporary_access "$DB_INSTANCE_ID_DEST"

  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" --verbose < "$FILTERED_DUMP"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
}

modo_completo() {
  if [[ $# -lt 2 ]]; then
    echo "ERROR: modo completo requiere: <SECRETO_ORIGEN> <SECRETO_DESTINO> [<TTL_SEGUNDOS>]"
    exit 1
  fi

  local SECRETO_ORIGEN=$1
  local SECRETO_DESTINO=$2
  local TTL=${3:-7200}

  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  modo_extraer "$SECRETO_ORIGEN" "$TTL"

  modo_restaurar "$SECRETO_DESTINO" "$PRESIGNED_URL"
}

case "$MODE" in
  extraer)
    if [[ $# -lt 2 ]]; then print_usage; fi  
    modo_extraer "$2" "${3:-7200}"
    ;;
  restaurar)
    if [[ $# -lt 3 ]]; then print_usage; fi  
    modo_restaurar "$2" "$3"
    ;;
  completo)
    if [[ $# -lt 3 ]]; then print_usage; fi  
    modo_completo "$2" "$3" "${4:-7200}"
    ;;
  *)
    print_usage
    ;;
esac

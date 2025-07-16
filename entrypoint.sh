#!/usr/bin/env bash
# Requiere: awscli, jq, mysql, mysqldump, gzip, curl
set -euo pipefail
if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
export AWS_PAGER=""
_CLEANED_UP=0

print_usage() {
  echo "Uso:"
  echo "  $0 extraer <AWS_ACCOUNT_ID_ORIGEN> <SECRETO_ORIGEN> [<TTL_SEGUNDOS>]"
  echo "  $0 restaurar <AWS_ACCOUNT_ID_DESTINO> <SECRETO_DESTINO> <URL_PRESIGNED>"
  echo "  $0 completo <AWS_ACCOUNT_ID_ORIGEN> <SECRETO_ORIGEN> <AWS_ACCOUNT_ID_DESTINO> <SECRETO_DESTINO> [<TTL_SEGUNDOS>]"
  exit 1
}

if [[ $# -lt 3 ]]; then
  print_usage
fi

MODE=$1
OPENED_SG_ID=""
OPENED_MY_IP=""
PRESIGNED_URL=""
ASUMIR_ROLE=true
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
        aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" --output text || true
    fi
    if [[ -f "$DUMP_FILE" ]]; then rm -f "$DUMP_FILE"; fi
    if [[ -f "$DUMP_FILE_GZ" ]]; then rm -f "$DUMP_FILE_GZ"; fi
    rm -rf "$TMP_DIR"  
}

assume_role() {
  local role_arn=$1
  CREDS_JSON=$(aws sts assume-role --role-arn "$role_arn" --role-session-name dbdt-session --duration-seconds 3600)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS_JSON" | jq -r '.Credentials.SessionToken')
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
    aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" --output text || true
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
  local AWS_ACCOUNT_ID=$1
  local SECRET_NAME=$2
  local TTL=${3:-7200}
  ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/DBDumpRoleGH"

  assume_role "$ROLE_ARN"

  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  DB_INSTANCE_ID=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET_JSON" | jq -r '.database')

  open_temporary_access "$DB_INSTANCE_ID"

  mysqldump --single-transaction --quick --lock-tables=false \
    --ignore-table="${DATABASE}.revisions" --ignore-table="${DATABASE}.domains" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"

  gzip "$DUMP_FILE"

  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME" --metadata-directive REPLACE --content-disposition "attachment; filename=\"$FILENAME\""

  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --expires-in "$TTL" --output text)
  echo "$PRESIGNED_URL" >> $GITHUB_OUTPUT
}

modo_restaurar() {
  local AWS_ACCOUNT_ID=$1
  local SECRET_NAME=$2
  local URL_PRESIGNED=$3

  if [[ "$SECRET_NAME" == *_pro* ]]; then
    echo "ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  if [[ "$ASUMIR_ROLE" == true ]]; then
    ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/DBDumpRoleGH"
    assume_role "$ROLE_ARN"
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

  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" < "$FILTERED_DUMP"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
}

modo_completo() {
  if [[ $# -lt 4 ]]; then
    echo "ERROR: modo completo requiere: <AWS_ACCOUNT_ID_ORIGEN> <SECRETO_ORIGEN> <AWS_ACCOUNT_ID_DESTINO> <SECRETO_DESTINO> [<TTL_SEGUNDOS>]"
    exit 1
  fi

  local AWS_ACCOUNT_ID_ORIGEN=$1
  local SECRETO_ORIGEN=$2
  local AWS_ACCOUNT_ID_DESTINO=$3
  local SECRETO_DESTINO=$4
  local TTL=${5:-7200}

  if [[ "$SECRETO_DESTINO" == *_pro* ]]; then
    echo "ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  modo_extraer "$AWS_ACCOUNT_ID_ORIGEN" "$SECRETO_ORIGEN" "$TTL"

  modo_restaurar "$AWS_ACCOUNT_ID_DESTINO" "$SECRETO_DESTINO" "$PRESIGNED_URL"
}

case "$MODE" in
  extraer)
    if [[ $# -lt 3 ]]; then print_usage; fi  
    modo_extraer "$2" "$3" "${4:-7200}"
    ;;
  restaurar)
    if [[ $# -lt 4 ]]; then print_usage; fi  
    modo_restaurar "$2" "$3" "$4"
    ;;
  completo)
    if [[ $# -lt 5 ]]; then print_usage; fi  
    if [[ "$2" == "$4" ]]; then
      ASUMIR_ROLE=false
    fi
    modo_completo "$2" "$3" "$4" "$5" "${6:-7200}"
    ;;
  *)
    print_usage
    ;;
esac

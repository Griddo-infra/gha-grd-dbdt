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
  exit 1
}

if [[ $# -lt 2 ]]; then
  print_usage
fi

MODE=$1
OPENED_SG_ID=""
OPENED_MY_IP=""
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
  echo "🔐 Abriendo acceso temporal a la instancia RDS '$db_instance_id'..."
  SG_ID=$(aws rds describe-db-instances \
    --db-instance-identifier "$db_instance_id" \
    --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
    --output text)
  echo "   • Security Group detectado: $SG_ID"
  OPENED_SG_ID="$SG_ID"
  MY_IP_PROVIDER="${MY_IP_PROVIDER:-https://checkip.amazonaws.com}"
  MY_IP=$(curl -s "$MY_IP_PROVIDER")/32
  OPENED_MY_IP="$MY_IP"
  echo "   • IP de origen: $MY_IP"
  EXISTING_RULE=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='$MY_IP']]" --output text)
  if [ -z "$EXISTING_RULE" ]; then
    echo "   • Añadiendo regla de ingreso al SG..."
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP" --output text
    echo "✅ Acceso temporal abierto"
  else
    echo "ℹ️  Ya existía una regla para esta IP, no se modifica el SG"
  fi
}

close_temporary_access() {
  if [[ -n "$OPENED_SG_ID" && -n "$OPENED_MY_IP" ]]; then
    if ! aws ec2 revoke-security-group-ingress --group-id "$OPENED_SG_ID" --protocol tcp --port 3306 --cidr "$OPENED_MY_IP" --output text; then
      echo "⚠️  No se pudo revocar la regla (posiblemente ya no existe)"
    else
      echo "🔒 Acceso temporal cerrado para $OPENED_MY_IP"
    fi
  fi
  OPENED_SG_ID=""
  OPENED_MY_IP=""
}

modo_extraer() {
  local SECRET_NAME=$1
  local TTL=${2:-7200}

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "📤 FASE: EXTRACCIÓN"
  echo "══════════════════════════════════════════════════════════"
  echo "🔑 Recuperando secreto de origen: $SECRET_NAME"
  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  DB_INSTANCE_ID=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')
  S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET_JSON" | jq -r '.database')
  echo "   • Endpoint: $ENDPOINT"
  echo "   • Base de datos: $DATABASE"
  echo "   • Bucket S3: $S3_BUCKET"
  echo "   • TTL del enlace: ${TTL}s"

  open_temporary_access "$DB_INSTANCE_ID"

  echo ""
  echo "🗄️  Generando dump SQL con mysqldump..."
  echo "   • Tablas ignoradas: revisions, log_alerts, distributor_cache, distributor_cache_structured_data"
  mysqldump --verbose --single-transaction --quick --skip-lock-tables --set-gtid-purged=OFF \
    --ignore-table="${DATABASE}.revisions" --ignore-table="${DATABASE}.log_alerts" \
    --ignore-table="${DATABASE}.distributor_cache" --ignore-table="${DATABASE}.distributor_cache_structured_data" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"
  echo "✅ Dump generado: $(du -h "$DUMP_FILE" | cut -f1)"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"

  echo ""
  echo "🗜️  Comprimiendo dump con gzip..."
  gzip "$DUMP_FILE"
  echo "✅ Dump comprimido: $(du -h "$DUMP_FILE_GZ" | cut -f1)"

  FILENAME="dump_$(date +%Y%m%d_%H%M%S).sql.gz"
  echo ""
  echo "☁️  Subiendo dump a S3: s3://$S3_BUCKET/$FILENAME"
  aws s3 cp "$DUMP_FILE_GZ" "s3://$S3_BUCKET/$FILENAME" \
    --region "$AWS_REGION" --metadata-directive REPLACE \
    --content-disposition "attachment; filename=\"$FILENAME\""
  echo "✅ Subida completada"

  echo ""
  echo "🔗 Generando URL presignada (expira en ${TTL}s)..."
  PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET/$FILENAME" --endpoint-url "https://s3.${AWS_REGION}.amazonaws.com" --expires-in "$TTL" --region "$AWS_REGION" --output text)
  echo "presigned_url=$PRESIGNED_URL" >> $GITHUB_OUTPUT
  echo "✅ URL presignada generada y exportada a GITHUB_OUTPUT"
  echo "══════════════════════════════════════════════════════════"
  echo "✅ FASE EXTRACCIÓN COMPLETADA"
  echo "══════════════════════════════════════════════════════════"
}

modo_restaurar() {
  local SECRET_NAME=$1
  local URL_PRESIGNED=$2

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "📥 FASE: RESTAURACIÓN"
  echo "══════════════════════════════════════════════════════════"

  if [[ "$SECRET_NAME" == *_pro* ]]; then
    echo "❌ ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  echo "🔑 Recuperando secreto de destino: $SECRET_NAME"
  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT_DEST=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME_DEST=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD_DEST=$(echo "$SECRET_JSON" | jq -r '.password')
  DATABASE_DEST=$(echo "$SECRET_JSON" | jq -r '.database')
  DB_INSTANCE_ID_DEST=$(echo "$SECRET_JSON" | jq -r '.db_instance_identifier')
  echo "   • Endpoint destino: $ENDPOINT_DEST"
  echo "   • Base de datos destino: $DATABASE_DEST"

  echo ""
  echo "⬇️  Descargando dump desde URL presignada..."
  curl -s -o "$DUMP_FILE_GZ" "$URL_PRESIGNED"
  echo "✅ Dump descargado: $(du -h "$DUMP_FILE_GZ" | cut -f1)"

  echo ""
  echo "🗜️  Descomprimiendo dump..."
  gzip -d "$DUMP_FILE_GZ"
  echo "✅ Dump descomprimido: $(du -h "$DUMP_FILE" | cut -f1)"

  open_temporary_access "$DB_INSTANCE_ID_DEST"

  PRESERVE_SQL="$TMP_DIR/preserve.sql"
  : > "$PRESERVE_SQL"

  echo ""
  echo "💾 Guardando valores a preservar del destino..."
  echo "   • Extrayendo domain_url de tabla domains..."
  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" -B -N -e \
    "SELECT CONCAT('UPDATE domains SET domain_url = ', QUOTE(domain_url), ' WHERE domain_slug = ', QUOTE(domain_slug), ';') FROM domains WHERE domain_slug IS NOT NULL AND domain_url IS NOT NULL;" >> "$PRESERVE_SQL"
  echo "   • Extrayendo credenciales de Administrator y bots..."
  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" -B -N -e \
    "SELECT CONCAT('UPDATE user SET email = ', IFNULL(QUOTE(email), 'NULL'), ', password = ', IFNULL(QUOTE(password), 'NULL'), ' WHERE name = ''Administrator'';') FROM user WHERE name = 'Administrator';
     SELECT CONCAT('UPDATE user SET email = ', IFNULL(QUOTE(email), 'NULL'), ', password = ', IFNULL(QUOTE(password), 'NULL'), ' WHERE bot = 1;') FROM user WHERE bot = 1;" >> "$PRESERVE_SQL"
  echo "✅ Valores preservados guardados ($(wc -l < "$PRESERVE_SQL") sentencias)"

  echo ""
  echo "🚀 Iniciando restauración del dump en destino..."
  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" --show-warnings < "$DUMP_FILE"
  echo "✅ Restauración completada"

  echo ""
  echo "🔁 Reaplicando valores preservados (domain_url, admin/bot)..."
  mysql -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" --show-warnings < "$PRESERVE_SQL"
  echo "✅ Valores preservados reaplicados"

  close_temporary_access "$OPENED_SG_ID" "$OPENED_MY_IP"
  echo "══════════════════════════════════════════════════════════"
  echo "✅ FASE RESTAURACIÓN COMPLETADA"
  echo "══════════════════════════════════════════════════════════"
}

echo "🟢 Iniciando entrypoint en modo: $MODE"

case "$MODE" in
  extraer)
    if [[ $# -lt 2 ]]; then print_usage; fi
    modo_extraer "$2" "${3:-7200}"
    ;;
  restaurar)
    if [[ $# -lt 3 ]]; then print_usage; fi
    modo_restaurar "$2" "$3"
    ;;
  *)
    print_usage
    ;;
esac

echo "🏁 Ejecución finalizada"

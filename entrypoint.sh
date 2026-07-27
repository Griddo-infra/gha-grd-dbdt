#!/usr/bin/env bash
# Requiere: awscli, jq, mysql, mysqldump, gzip, curl
set -euo pipefail
if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
export AWS_PAGER=""
_CLEANED_UP=0

print_usage() {
  echo "Uso:"
  echo "  $0 extraer <SECRETO_ORIGEN> [<TTL_SEGUNDOS>]"
  echo "  $0 restaurar <SECRETO_DESTINO> <URL_PRESIGNED> [<BACKUP_BEFORE_RESTORE>] [<TTL_SEGUNDOS>]"
  echo "  $0 preparar_red <NETWORK_SCOPE>"
  echo "  $0 limpiar_red <NETWORK_SCOPE>"
  exit 1
}

if [[ $# -lt 2 ]]; then
  print_usage
fi

MODE=$1
TMP_DIR=$(mktemp -d)
DUMP_FILE="$TMP_DIR/dump.sql"
DUMP_FILE_GZ="$DUMP_FILE.gz"
BACKUP_FILE="$TMP_DIR/backup.sql"
BACKUP_FILE_GZ="$BACKUP_FILE.gz"

trap clean_up EXIT

clean_up() {
  if [[ $_CLEANED_UP -eq 1 ]]; then
      return
  fi
  _CLEANED_UP=1
  if [[ -f "$DUMP_FILE" ]]; then rm -f "$DUMP_FILE"; fi
  if [[ -f "$DUMP_FILE_GZ" ]]; then rm -f "$DUMP_FILE_GZ"; fi
  if [[ -f "$BACKUP_FILE" ]]; then rm -f "$BACKUP_FILE"; fi
  if [[ -f "$BACKUP_FILE_GZ" ]]; then rm -f "$BACKUP_FILE_GZ"; fi
  rm -rf "$TMP_DIR"
}

get_secret() {
  local secret_name=$1
  aws secretsmanager get-secret-value --secret-id "$secret_name" --query SecretString --output text
}

modo_preparar_red() {
  local SCOPE=$1

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "🌐 FASE: PREPARAR RED (scope: $SCOPE)"
  echo "══════════════════════════════════════════════════════════"

  echo "🔍 Descubriendo recursos de red por tags (dbdt:scope=$SCOPE)..."
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=tag:dbdt:role,Values=runner-rt" "Name=tag:dbdt:scope,Values=$SCOPE" \
    --query 'RouteTables[0].RouteTableId' --output text)
  NAT_SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=tag:dbdt:role,Values=nat-subnet" "Name=tag:dbdt:scope,Values=$SCOPE" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ -z "$RT_ID" || "$RT_ID" == "None" || -z "$NAT_SUBNET_ID" || "$NAT_SUBNET_ID" == "None" ]]; then
    echo "❌ ERROR: No se encontraron la route table (dbdt:role=runner-rt) y/o la subnet del NAT (dbdt:role=nat-subnet) para el scope '$SCOPE'."
    echo "   Despliega primero la infraestructura base (terraform) de este tenant."
    exit 1
  fi
  echo "   • Route table del runner: $RT_ID"
  echo "   • Subnet pública para el NAT: $NAT_SUBNET_ID"

  NAT_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:dbdt:managed,Values=true" "Name=tag:dbdt:scope,Values=$SCOPE" "Name=state,Values=pending,available" \
    --query 'NatGateways[0].NatGatewayId' --output text)

  if [[ -n "$NAT_ID" && "$NAT_ID" != "None" ]]; then
    echo "ℹ️  Reutilizando NAT gateway existente: $NAT_ID"
  else
    echo "📡 Reservando Elastic IP..."
    ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=dbdt-$SCOPE},{Key=dbdt:managed,Value=true},{Key=dbdt:scope,Value=$SCOPE}]" \
      --query 'AllocationId' --output text)
    echo "   • Allocation ID: $ALLOC_ID"
    echo "🚧 Creando NAT gateway..."
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$NAT_SUBNET_ID" --allocation-id "$ALLOC_ID" \
      --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=dbdt-$SCOPE},{Key=dbdt:managed,Value=true},{Key=dbdt:scope,Value=$SCOPE}]" \
      --query 'NatGateway.NatGatewayId' --output text)
    echo "   • NAT gateway: $NAT_ID"
  fi

  echo "⏳ Esperando a que el NAT gateway esté disponible (~2 min)..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
  echo "✅ NAT gateway disponible"

  echo "🛣️  Configurando ruta por defecto 0.0.0.0/0 → $NAT_ID..."
  if ! aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" --output text >/dev/null 2>&1; then
    aws ec2 replace-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" --output text >/dev/null
    echo "   • Ruta existente reemplazada"
  else
    echo "   • Ruta creada"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "nat_gateway_id=$NAT_ID" >> "$GITHUB_OUTPUT"
  fi
  echo "══════════════════════════════════════════════════════════"
  echo "✅ FASE PREPARAR RED COMPLETADA"
  echo "══════════════════════════════════════════════════════════"
}

modo_limpiar_red() {
  local SCOPE=$1

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "🧹 FASE: LIMPIAR RED (scope: $SCOPE)"
  echo "══════════════════════════════════════════════════════════"

  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=tag:dbdt:role,Values=runner-rt" "Name=tag:dbdt:scope,Values=$SCOPE" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
    echo "🛣️  Eliminando ruta por defecto de $RT_ID..."
    if aws ec2 delete-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --output text >/dev/null 2>&1; then
      echo "   • Ruta eliminada"
    else
      echo "   • No había ruta por defecto (nada que eliminar)"
    fi
  else
    echo "ℹ️  No se encontró route table con scope '$SCOPE'"
  fi

  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:dbdt:managed,Values=true" "Name=tag:dbdt:scope,Values=$SCOPE" "Name=state,Values=pending,available" \
    --query 'NatGateways[].NatGatewayId' --output text)
  if [[ -n "$NAT_IDS" ]]; then
    for nat in $NAT_IDS; do
      echo "🗑️  Eliminando NAT gateway $nat..."
      aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --output text >/dev/null
    done
    echo "⏳ Esperando el borrado de los NAT gateways (~1-2 min)..."
    # shellcheck disable=SC2086
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_IDS
    echo "✅ NAT gateways eliminados"
  else
    echo "ℹ️  No hay NAT gateways gestionados con scope '$SCOPE'"
  fi

  ALLOC_IDS=$(aws ec2 describe-addresses \
    --filters "Name=tag:dbdt:managed,Values=true" "Name=tag:dbdt:scope,Values=$SCOPE" \
    --query 'Addresses[?AssociationId==null].AllocationId' --output text)
  if [[ -n "$ALLOC_IDS" ]]; then
    for alloc in $ALLOC_IDS; do
      echo "📡 Liberando Elastic IP $alloc..."
      aws ec2 release-address --allocation-id "$alloc" --output text >/dev/null
    done
    echo "✅ Elastic IPs liberadas"
  else
    echo "ℹ️  No hay Elastic IPs gestionadas pendientes de liberar con scope '$SCOPE'"
  fi

  echo "══════════════════════════════════════════════════════════"
  echo "✅ FASE LIMPIAR RED COMPLETADA"
  echo "══════════════════════════════════════════════════════════"
}

check_db_connectivity() {
  local endpoint=$1
  echo "🔌 Comprobando conectividad de red con $endpoint:3306..."
  if ! timeout 10 bash -c ">/dev/tcp/$endpoint/3306" 2>/dev/null; then
    echo "❌ ERROR: No hay conectividad con $endpoint:3306."
    echo "   El runner debe ejecutarse dentro de la VPC del RDS (runner de CodeBuild asociado a sus subnets)"
    echo "   y el security group del RDS debe permitir el puerto 3306 desde el security group del runner."
    exit 1
  fi
  echo "✅ Conectividad verificada"
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
  S3_BUCKET=$(echo "$SECRET_JSON" | jq -r '.s3_bucket')
  DATABASE=$(echo "$SECRET_JSON" | jq -r '.database')
  echo "   • Endpoint: $ENDPOINT"
  echo "   • Base de datos: $DATABASE"
  echo "   • Bucket S3: $S3_BUCKET"
  echo "   • TTL del enlace: ${TTL}s"

  check_db_connectivity "$ENDPOINT"

  echo ""
  echo "🗄️  Generando dump SQL con mysqldump..."
  echo "   • Tablas ignoradas: revisions, log_alerts, migrations, distributor_cache, distributor_cache_structured_data"
  mysqldump --verbose --single-transaction --quick --skip-lock-tables --set-gtid-purged=OFF \
    --ignore-table="${DATABASE}.revisions" --ignore-table="${DATABASE}.log_alerts" --ignore-table="${DATABASE}.migrations" \
    --ignore-table="${DATABASE}.distributor_cache" --ignore-table="${DATABASE}.distributor_cache_structured_data" \
    -h "$ENDPOINT" -u "$USERNAME" -p"$PASSWORD" "$DATABASE" > "$DUMP_FILE"
  echo "✅ Dump generado: $(du -h "$DUMP_FILE" | cut -f1)"

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
  local BACKUP_BEFORE_RESTORE=${3:-true}
  local TTL=${4:-7200}

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "📥 FASE: RESTAURACIÓN"
  echo "══════════════════════════════════════════════════════════"

  if [[ "$SECRET_NAME" == *_pro* ]]; then
    echo "❌ ERROR: No está permitido usar un entorno _pro como destino de restauración."
    exit 1
  fi

  if [[ -z "$URL_PRESIGNED" ]]; then
    echo "❌ ERROR: presigned_url está vacío. Si viene del output de otro job, recuerda que GitHub"
    echo "   descarta outputs que contienen secretos (la URL pre-firmada incluye credenciales):"
    echo "   pásala entre jobs mediante un artefacto."
    exit 1
  fi

  echo "🔑 Recuperando secreto de destino: $SECRET_NAME"
  SECRET_JSON=$(get_secret "$SECRET_NAME")
  ENDPOINT_DEST=$(echo "$SECRET_JSON" | jq -r '.endpoint')
  USERNAME_DEST=$(echo "$SECRET_JSON" | jq -r '.username')
  PASSWORD_DEST=$(echo "$SECRET_JSON" | jq -r '.password')
  DATABASE_DEST=$(echo "$SECRET_JSON" | jq -r '.database')
  S3_BUCKET_DEST=$(echo "$SECRET_JSON" | jq -r '.s3_bucket // empty')
  echo "   • Endpoint destino: $ENDPOINT_DEST"
  echo "   • Base de datos destino: $DATABASE_DEST"
  echo "   • Backup previo: $BACKUP_BEFORE_RESTORE"

  echo ""
  echo "⬇️  Descargando dump desde URL presignada..."
  curl -s -o "$DUMP_FILE_GZ" "$URL_PRESIGNED"
  echo "✅ Dump descargado: $(du -h "$DUMP_FILE_GZ" | cut -f1)"

  echo ""
  echo "🗜️  Descomprimiendo dump..."
  gzip -d "$DUMP_FILE_GZ"
  echo "✅ Dump descomprimido: $(du -h "$DUMP_FILE" | cut -f1)"

  check_db_connectivity "$ENDPOINT_DEST"

  if [[ "$BACKUP_BEFORE_RESTORE" == "true" ]]; then
    if [[ -z "$S3_BUCKET_DEST" ]]; then
      echo "❌ ERROR: backup_before_restore=true pero el secret de destino no tiene 's3_bucket'. Abortando para no restaurar sin red de seguridad."
      exit 1
    fi

    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "🛟 FASE: BACKUP PRE-RESTAURACIÓN DEL DESTINO"
    echo "══════════════════════════════════════════════════════════"
    echo "🗄️  Generando dump SQL del destino con mysqldump..."
    mysqldump --verbose --single-transaction --quick --skip-lock-tables --set-gtid-purged=OFF \
      -h "$ENDPOINT_DEST" -u "$USERNAME_DEST" -p"$PASSWORD_DEST" "$DATABASE_DEST" > "$BACKUP_FILE"
    echo "✅ Backup generado: $(du -h "$BACKUP_FILE" | cut -f1)"

    echo ""
    echo "🗜️  Comprimiendo backup con gzip..."
    gzip "$BACKUP_FILE"
    echo "✅ Backup comprimido: $(du -h "$BACKUP_FILE_GZ" | cut -f1)"

    BACKUP_FILENAME="backup_pre_restore_$(date +%Y%m%d_%H%M%S).sql.gz"
    echo ""
    echo "☁️  Subiendo backup a S3: s3://$S3_BUCKET_DEST/$BACKUP_FILENAME"
    aws s3 cp "$BACKUP_FILE_GZ" "s3://$S3_BUCKET_DEST/$BACKUP_FILENAME" \
      --region "$AWS_REGION" --metadata-directive REPLACE \
      --content-disposition "attachment; filename=\"$BACKUP_FILENAME\""
    echo "✅ Backup subido"

    echo ""
    echo "🔗 Generando URL presignada del backup (expira en ${TTL}s)..."
    BACKUP_PRESIGNED_URL=$(aws s3 presign "s3://$S3_BUCKET_DEST/$BACKUP_FILENAME" --endpoint-url "https://s3.${AWS_REGION}.amazonaws.com" --expires-in "$TTL" --region "$AWS_REGION" --output text)
    echo "backup_presigned_url=$BACKUP_PRESIGNED_URL" >> $GITHUB_OUTPUT
    echo "✅ URL presignada del backup exportada a GITHUB_OUTPUT"

    rm -f "$BACKUP_FILE_GZ"
    echo "══════════════════════════════════════════════════════════"
    echo "✅ BACKUP PRE-RESTAURACIÓN COMPLETADO"
    echo "══════════════════════════════════════════════════════════"
  else
    echo ""
    echo "ℹ️  backup_before_restore=false → se omite el backup previo del destino"
  fi

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
    modo_restaurar "$2" "$3" "${4:-true}" "${5:-7200}"
    ;;
  preparar_red)
    if [[ $# -lt 2 ]]; then print_usage; fi
    modo_preparar_red "$2"
    ;;
  limpiar_red)
    if [[ $# -lt 2 ]]; then print_usage; fi
    modo_limpiar_red "$2"
    ;;
  *)
    print_usage
    ;;
esac

echo "🏁 Ejecución finalizada"

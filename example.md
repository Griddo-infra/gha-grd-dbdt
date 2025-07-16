~~~yaml
name: 'Volcado y restauración de RDS'

on:
  workflow_dispatch:
    inputs:
      modo:
        description: 'Modo de operación'
        type: choice
        options:
          - extraer
          - restaurar
          - completo
        required: true
      origen:
        description: 'Cuenta Origen'
        type: choice
        options:
          - pro
          - stg
          - dev
        required: true
      destino:
        description: 'Cuenta Destino (solo para restaurar o completo)'
        type: choice
        options:
          - stg
          - dev
        required: false
      ttl:
        description: 'TTL URL Pre-firmada (segundos)'
        default: '7200'
        required: false
      presigned_url:
        description: 'URL Pre-firmada S3 (solo para restaurar)'
        required: false

env:
  ACCOUNT_ID_PRO: ${{ secrets.ACCOUNT_ID_PRO }}
  ACCOUNT_ID_STG: ${{ secrets.ACCOUNT_ID_STG }}
  ACCOUNT_ID_DEV: ${{ secrets.ACCOUNT_ID_DEV }}
  SECRET_NAME_PRO: ${{ secrets.SECRET_NAME_PRO }}
  SECRET_NAME_STG: ${{ secrets.SECRET_NAME_STG }}
  SECRET_NAME_DEV: ${{ secrets.SECRET_NAME_DEV }}

jobs:
  dbdt:
    runs-on: ubuntu-latest

    outputs:
      origen_account_id: ${{ steps.setvars.outputs.origen_account_id }}
      destino_account_id: ${{ steps.setvars.outputs.destino_account_id }}

    steps:
      - uses: actions/checkout@v4

      - name: Establecer Variables
        id: setvars
        run: |
          # Origen
          case "${{ github.event.inputs.origen }}" in
            pro)
              echo "ORIGEN_ACCOUNT_ID=${ACCOUNT_ID_PRO}" >> $GITHUB_ENV
              echo "ORIGEN_ROLE=arn:aws:iam::${ACCOUNT_ID_PRO}:role/DBDumpRoleGH" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_PRO}" >> $GITHUB_ENV
              ;;
            stg)
              echo "ORIGEN_ACCOUNT_ID=${ACCOUNT_ID_STG}" >> $GITHUB_ENV
              echo "ORIGEN_ROLE=arn:aws:iam::${ACCOUNT_ID_STG}:role/DBDumpRoleGH" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "ORIGEN_ACCOUNT_ID=${ACCOUNT_ID_DEV}" >> $GITHUB_ENV
              echo "ORIGEN_ROLE=arn:aws:iam::${ACCOUNT_ID_DEV}:role/DBDumpRoleGH" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_DEV}" >> $GITHUB_ENV
              ;;
          esac

          # Destino (solo si aplica)
          if [[ "${{ github.event.inputs.destino }}" == "stg" ]]; then
            echo "DESTINO_ACCOUNT_ID=${ACCOUNT_ID_STG}" >> $GITHUB_ENV
            echo "DESTINO_ROLE=arn:aws:iam::${ACCOUNT_ID_STG}:role/DBDumpRoleGH" >> $GITHUB_ENV
            echo "DESTINO_SECRET=${SECRET_NAME_STG}" >> $GITHUB_ENV
          elif [[ "${{ github.event.inputs.destino }}" == "dev" ]]; then
            echo "DESTINO_ACCOUNT_ID=${ACCOUNT_ID_DEV}" >> $GITHUB_ENV
            echo "DESTINO_ROLE=arn:aws:iam::${ACCOUNT_ID_DEV}:role/DBDumpRoleGH" >> $GITHUB_ENV
            echo "DESTINO_SECRET=${SECRET_NAME_DEV}" >> $GITHUB_ENV
          fi

      - name: Configuración de Credenciales de AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: eu-west-1

      - name: Instalación de Dependencias
        run: |
          sudo apt-get update
          sudo apt-get install -y awscli jq mysql-client gzip curl

      - name: 'Volcado y restauración de RDS'
        uses: Griddo-infra/gha-grd-dbdt@0.4
        with:
          mode: ${{ github.event.inputs.modo }}
          aws_account_origin: ${{ env.ORIGEN_ACCOUNT_ID }}
          secret_origin: ${{ env.ORIGEN_SECRET }}
          aws_account_dest: ${{ env.DESTINO_ACCOUNT_ID }}
          secret_dest: ${{ env.DESTINO_SECRET }}
          presigned_url: ${{ github.event.inputs.presigned_url }}
          ttl: ${{ github.event.inputs.ttl }}

      - name: Muestra la URL Pre-firmada si existe
          if: ${{ github.event.inputs.modo != 'restaurar' }}
          run: |
            echo "### ✅ URL Pre-firmada para descargar el volcado:" >> $GITHUB_STEP_SUMMARY
            echo "" >> $GITHUB_STEP_SUMMARY
            echo "\`${{ steps.dbdt.outputs.presigned_url }}\`" >> $GITHUB_STEP_SUMMARY
~~~
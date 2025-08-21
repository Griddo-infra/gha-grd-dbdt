# Ejemplo de Workflow #

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
      region_aws:
        description: 'Región AWS'
        type: choice
        options:
          - eu-central-1
          - eu-central-2
          - eu-north-1
          - eu-south-1
          - eu-south-2
          - eu-west-1
          - eu-west-2
          - eu-west-3
        default: 'eu-south-2'
        required: true

permissions:
  id-token: write
  contents: read

env:
# -------------------------------------
# 👇 AGREGA TANTOS ENTORNOS COMO NECESITES
# Necesitaras IAM_ROLE y SECRET_NAME para Instancia
# y entorno especifico, en caso de que solo sea una
# cuenta, los tres IAM_ROLE, apuntan al mismo secreto.
  IAM_ROLE_PRO: ${{ secrets.IAM_ROLE_PRO }}
  IAM_ROLE_STG: ${{ secrets.IAM_ROLE_STG }}
  IAM_ROLE_DEV: ${{ secrets.IAM_ROLE_DEV }}
  SECRET_NAME_PRO: ${{ secrets.SECRET_NAME_PRO }}
  SECRET_NAME_STG: ${{ secrets.SECRET_NAME_STG }}
  SECRET_NAME_DEV: ${{ secrets.SECRET_NAME_DEV }}
# -------------------------------------
jobs:
  dbdt:
    runs-on: grd-it-sqldumper # Puede funcionar en ubuntu-latest
    env:
      MULTI_ACCOUNT: false # cambia esto a true si origen/destino son cuentas distintas
    steps:
      # -------------------------------------
      # VALIDACION ORIGEN/DESTINO DISTINTOS
      # DESACTIVADO TEMPORALMENTE PARA PRUEBAS
      # -------------------------------------
       - name: Validar origen y destino diferentes
         if: ${{ (github.event.inputs.modo == 'restaurar' || github.event.inputs.modo == 'completo') && github.event.inputs.origen == github.event.inputs.destino }}
         run: |
           echo "❌ Error: El origen y destino no pueden ser el mismo entorno"
           echo "   Origen seleccionado: ${{ github.event.inputs.origen }}"
           echo "   Destino seleccionado: ${{ github.event.inputs.destino }}"
           echo "   Por favor, selecciona entornos diferentes"
           exit 1
      # -------------------------------------
      # SINCRONIZACION DEL REPOSITORIO
      # -------------------------------------
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4
      # -------------------------------------
      # LOGICA DE SELECCION DE ROLES Y SECRETOS
      # Aqui se establece la logica de seleccion
      # de roles y secretos segun los entornos
      # seleccionados en el workflow_dispatch
      # Hay que modificar los cases para que coincidan
      # con las instancias disponibles en el cliente.
      # -------------------------------------
      - name: Establecer variables
        id: vars
        run: |
          case "${{ github.event.inputs.origen }}" in
            pro)
              echo "ORIGEN_ROLE=${IAM_ROLE_PRO}" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_PRO}" >> $GITHUB_ENV
              ;;
            stg)
              echo "ORIGEN_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "ORIGEN_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "ORIGEN_SECRET=${SECRET_NAME_DEV}" >> $GITHUB_ENV
              ;;
          esac

          case "${{ github.event.inputs.destino }}" in
            stg)
              echo "DESTINO_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "DESTINO_SECRET=${SECRET_NAME_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "DESTINO_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "DESTINO_SECRET=${SECRET_NAME_DEV}" >> $GITHUB_ENV
              ;;
            *)
              echo "DESTINO_ROLE=" >> $GITHUB_ENV
              echo "DESTINO_SECRET=" >> $GITHUB_ENV
              ;;
          esac
      # -------------------------------------
      # MODO EXTRAER o COMPLETO MULTI-CUENTA
      # -------------------------------------
      - name: Configurar AWS via OIDC para el Origen
        if: ${{ github.event.inputs.modo == 'extraer' || ( github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true' ) }}
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Volcado RDS
        if: ${{ github.event.inputs.modo == 'extraer' || ( github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true' ) }}
        id: dump
        uses: Griddo-infra/gha-grd-dbdt@v0.3
        with:
          mode: extraer
          secret_origin: ${{ env.ORIGEN_SECRET }}
          ttl: ${{ github.event.inputs.ttl }}
          aws_region: ${{ github.event.inputs.region_aws }}

      - name: Guardar URL Pre-firmada
        if: ${{ github.event.inputs.modo == 'extraer' || ( github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true' ) }}
        run: echo "${{ steps.dump.outputs.presigned_url }}" > url_prefirmada.txt

      - name: Subir URL Pre-firmada como artefacto
        if: ${{ github.event.inputs.modo == 'extraer' || ( github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true' ) }}
        uses: actions/upload-artifact@v4
        with:
          name: url-prefirmada-${{ github.run_number }}
          path: url_prefirmada.txt
      # -------------------------------------
      # MODO RESTAURAR O COMPLETO MULTI-CUENTA
      # -------------------------------------
      - name: Configurar AWS via OIDC para el Destino
        if: ${{ github.event.inputs.modo == 'restaurar' || (github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true') }}
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.DESTINO_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Restauración RDS
        if: ${{ github.event.inputs.modo == 'restaurar' || (github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'true') }}
        uses: Griddo-infra/gha-grd-dbdt@v0.3
        with:
          mode: restaurar
          secret_dest: ${{ env.DESTINO_SECRET }}
          presigned_url: ${{ github.event.inputs.presigned_url || steps.dump.outputs.presigned_url }}
          aws_region: ${{ github.event.inputs.region_aws }}
      # -------------------------------------
      # COMPLETO MONO-CUENTA
      # -------------------------------------
      - name: Configurar AWS via OIDC
        if: ${{ github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'false' }}
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Completo misma cuenta
        if: ${{ github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'false' }}
        id: completo_simple
        uses: Griddo-infra/gha-grd-dbdt@v0.3
        with:
          mode: completo
          secret_origin: ${{ env.ORIGEN_SECRET }}
          secret_dest: ${{ env.DESTINO_SECRET }}
          ttl: ${{ github.event.inputs.ttl }}
          aws_region: ${{ github.event.inputs.region_aws }}

      - name: Guardar URL Pre-firmada (Completo)
        if: ${{ github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'false' }}
        run: echo "${{ steps.completo_simple.outputs.presigned_url }}" > url_prefirmada.txt

      - name: Subir Artefacto URL Pre-firmada (Completo)
        if: ${{ github.event.inputs.modo == 'completo' && env.MULTI_ACCOUNT == 'false' }}
        uses: actions/upload-artifact@v4
        with:
          name: url-prefirmada-${{ github.run_number }}
          path: url_prefirmada.txt
~~~

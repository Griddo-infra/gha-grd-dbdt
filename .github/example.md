# Ejemplo de Workflow #

Los jobs de base de datos se ejecutan en **runners de AWS CodeBuild** asociados a las subnets privadas de la VPC del RDS (las instancias son privadas y no hay reglas dinámicas de security group). Este ejemplo asume un proyecto CodeBuild por entorno con la convención de nombre `grd-dbdt-<entorno>` (ajústala a la de tu cuenta): la etiqueta de `runs-on` es `codebuild-<proyecto>-${{ github.run_id }}-${{ github.run_attempt }}`.

Las VPCs no tienen NAT gateway permanente, así que el workflow envuelve los jobs de CodeBuild con los modos de red de la Action:

- `preparar_red` (runner `ubuntu-latest`, **antes** de los jobs de CodeBuild): crea el NAT efímero del scope y su ruta por defecto, para que el runner de CodeBuild pueda registrarse en GitHub.
- `limpiar_red` (runner `ubuntu-latest`, job final con `if: always()`): destruye el NAT y libera la Elastic IP aunque los jobs anteriores fallen.

En flujos multi-cuenta, el job de extracción corre en el runner de CodeBuild de la cuenta **origen** y el de restauración en el de la cuenta **destino**; cada cuenta tiene su propia pareja `preparar_red`/`limpiar_red` con su `network_scope`. La infraestructura permanente (subnet privada, route table, subnet pública del NAT, proyecto CodeBuild, security group, regla 3306, conexión CodeConnections, tags `dbdt:*`) la crea el terraform del repo `grd-toolbox-dbdumper`; la Action solo gestiona NAT + EIP + ruta.

El `concurrency group` evita ejecuciones simultáneas que compitan por la misma red.

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

# Una sola ejecución a la vez: dos runs simultáneos
# competirían por el mismo NAT efímero y su limpieza.
concurrency:
  group: grd-dbdt-rds
  cancel-in-progress: false

env:
# -------------------------------------
# 👇 AGREGA TANTOS ENTORNOS COMO NECESITES
# Necesitaras IAM_ROLE, SECRET_NAME y NETWORK_SCOPE
# por instancia y entorno especifico; en caso de que
# solo sea una cuenta, los IAM_ROLE apuntan al mismo role.
# NETWORK_SCOPE es el valor de la tag dbdt:scope que el
# terraform de grd-toolbox-dbdumper pone en la route table
# del runner y en la subnet publica del NAT.
# Ademas, cada entorno necesita un proyecto CodeBuild
# configurado como GitHub Actions runner en su VPC
# (aqui: grd-dbdt-pro, grd-dbdt-stg, grd-dbdt-dev).
  IAM_ROLE_PRO: ${{ secrets.IAM_ROLE_PRO }}
  IAM_ROLE_STG: ${{ secrets.IAM_ROLE_STG }}
  IAM_ROLE_DEV: ${{ secrets.IAM_ROLE_DEV }}
  SECRET_NAME_PRO: ${{ secrets.SECRET_NAME_PRO }}
  SECRET_NAME_STG: ${{ secrets.SECRET_NAME_STG }}
  SECRET_NAME_DEV: ${{ secrets.SECRET_NAME_DEV }}
  NETWORK_SCOPE_PRO: ${{ secrets.NETWORK_SCOPE_PRO }}
  NETWORK_SCOPE_STG: ${{ secrets.NETWORK_SCOPE_STG }}
  NETWORK_SCOPE_DEV: ${{ secrets.NETWORK_SCOPE_DEV }}
# -------------------------------------
jobs:
  # -------------------------------------
  # VALIDACION ORIGEN/DESTINO DISTINTOS
  # Job ligero en runner GitHub-hosted: no
  # necesita acceso a la VPC.
  # -------------------------------------
  validar:
    runs-on: ubuntu-latest
    steps:
      - name: Validar origen y destino diferentes
        if: ${{ (github.event.inputs.modo == 'restaurar' || github.event.inputs.modo == 'completo') && github.event.inputs.origen == github.event.inputs.destino }}
        run: |
          echo "❌ Error: El origen y destino no pueden ser el mismo entorno"
          echo "   Origen seleccionado: ${{ github.event.inputs.origen }}"
          echo "   Destino seleccionado: ${{ github.event.inputs.destino }}"
          echo "   Por favor, selecciona entornos diferentes"
          exit 1
  # -------------------------------------
  # PREPARAR RED EN ORIGEN (modo extraer y completo)
  # Runner GitHub-hosted: crea el NAT efimero de la
  # cuenta ORIGEN para que su runner de CodeBuild
  # pueda registrarse en GitHub.
  # -------------------------------------
  preparar-red-origen:
    needs: validar
    if: ${{ github.event.inputs.modo == 'extraer' || github.event.inputs.modo == 'completo' }}
    runs-on: ubuntu-latest
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4

      - name: Establecer variables de origen
        run: |
          case "${{ github.event.inputs.origen }}" in
            pro)
              echo "ORIGEN_ROLE=${IAM_ROLE_PRO}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_PRO}" >> $GITHUB_ENV
              ;;
            stg)
              echo "ORIGEN_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "ORIGEN_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_DEV}" >> $GITHUB_ENV
              ;;
          esac

      - name: Configurar AWS via OIDC para el Origen
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Preparar red del Origen
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: preparar_red
          network_scope: ${{ env.ORIGEN_SCOPE }}
          aws_region: ${{ github.event.inputs.region_aws }}
  # -------------------------------------
  # PREPARAR RED EN DESTINO (modo restaurar y completo)
  # Igual que el anterior, pero para la cuenta DESTINO.
  # -------------------------------------
  preparar-red-destino:
    needs: validar
    if: ${{ github.event.inputs.modo == 'restaurar' || github.event.inputs.modo == 'completo' }}
    runs-on: ubuntu-latest
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4

      - name: Establecer variables de destino
        run: |
          case "${{ github.event.inputs.destino }}" in
            stg)
              echo "DESTINO_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "DESTINO_SCOPE=${NETWORK_SCOPE_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "DESTINO_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "DESTINO_SCOPE=${NETWORK_SCOPE_DEV}" >> $GITHUB_ENV
              ;;
            *)
              echo "❌ Destino no soportado: ${{ github.event.inputs.destino }}"
              exit 1
              ;;
          esac

      - name: Configurar AWS via OIDC para el Destino
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.DESTINO_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Preparar red del Destino
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: preparar_red
          network_scope: ${{ env.DESTINO_SCOPE }}
          aws_region: ${{ github.event.inputs.region_aws }}
  # -------------------------------------
  # FASE DE EXTRACCIÓN (modo extraer y completo)
  # Corre en el runner de CodeBuild de la cuenta
  # ORIGEN, dentro de la VPC del RDS de origen.
  # Necesita la red de origen preparada: sin NAT
  # el runner de CodeBuild ni siquiera arranca.
  # -------------------------------------
  extraer:
    needs: [validar, preparar-red-origen]
    if: ${{ github.event.inputs.modo == 'extraer' || github.event.inputs.modo == 'completo' }}
    runs-on: codebuild-grd-dbdt-${{ github.event.inputs.origen }}-${{ github.run_id }}-${{ github.run_attempt }}
    outputs:
      presigned_url: ${{ steps.dump.outputs.presigned_url }}
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4
      # -------------------------------------
      # LOGICA DE SELECCION DE ROLES Y SECRETOS
      # Hay que modificar los cases para que coincidan
      # con las instancias disponibles en el cliente.
      # -------------------------------------
      - name: Establecer variables de origen
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

      - name: Configurar AWS via OIDC para el Origen
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Volcado RDS
        id: dump
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: extraer
          secret_origin: ${{ env.ORIGEN_SECRET }}
          ttl: ${{ github.event.inputs.ttl }}
          aws_region: ${{ github.event.inputs.region_aws }}

      - name: Guardar URL Pre-firmada
        run: echo "${{ steps.dump.outputs.presigned_url }}" > url_prefirmada.txt

      - name: Subir URL Pre-firmada como artefacto
        uses: actions/upload-artifact@v4
        with:
          name: url-prefirmada-${{ github.run_number }}
          path: url_prefirmada.txt
  # -------------------------------------
  # FASE DE RESTAURACIÓN (modo restaurar y completo)
  # Corre en el runner de CodeBuild de la cuenta
  # DESTINO, dentro de la VPC del RDS de destino.
  # En modo restaurar el job extraer se salta, por
  # eso el if usa !cancelled() + needs.extraer.result.
  # -------------------------------------
  restaurar:
    needs: [validar, preparar-red-destino, extraer]
    if: ${{ !cancelled() && needs.validar.result == 'success' && needs.preparar-red-destino.result == 'success' && (github.event.inputs.modo == 'restaurar' || (github.event.inputs.modo == 'completo' && needs.extraer.result == 'success')) }}
    runs-on: codebuild-grd-dbdt-${{ github.event.inputs.destino }}-${{ github.run_id }}-${{ github.run_attempt }}
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4

      - name: Establecer variables de destino
        run: |
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
              echo "❌ Destino no soportado: ${{ github.event.inputs.destino }}"
              exit 1
              ;;
          esac

      - name: Configurar AWS via OIDC para el Destino
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.DESTINO_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Restauración RDS
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: restaurar
          secret_dest: ${{ env.DESTINO_SECRET }}
          presigned_url: ${{ github.event.inputs.presigned_url || needs.extraer.outputs.presigned_url }}
          aws_region: ${{ github.event.inputs.region_aws }}
  # -------------------------------------
  # LIMPIAR RED EN ORIGEN (job final)
  # if: always() → el NAT efimero de origen se destruye
  # aunque la extraccion falle o se salte algun job.
  # Solo limpia si su preparar-red llego a ejecutarse.
  # -------------------------------------
  limpiar-red-origen:
    needs: [preparar-red-origen, extraer]
    if: ${{ always() && needs.preparar-red-origen.result == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4

      - name: Establecer variables de origen
        run: |
          case "${{ github.event.inputs.origen }}" in
            pro)
              echo "ORIGEN_ROLE=${IAM_ROLE_PRO}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_PRO}" >> $GITHUB_ENV
              ;;
            stg)
              echo "ORIGEN_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "ORIGEN_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "ORIGEN_SCOPE=${NETWORK_SCOPE_DEV}" >> $GITHUB_ENV
              ;;
          esac

      - name: Configurar AWS via OIDC para el Origen
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ORIGEN_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Limpiar red del Origen
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: limpiar_red
          network_scope: ${{ env.ORIGEN_SCOPE }}
          aws_region: ${{ github.event.inputs.region_aws }}
  # -------------------------------------
  # LIMPIAR RED EN DESTINO (job final)
  # Igual que el anterior, para la cuenta DESTINO.
  # -------------------------------------
  limpiar-red-destino:
    needs: [preparar-red-destino, restaurar]
    if: ${{ always() && needs.preparar-red-destino.result == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - name: Sincronizacion del repositorio
        uses: actions/checkout@v4

      - name: Establecer variables de destino
        run: |
          case "${{ github.event.inputs.destino }}" in
            stg)
              echo "DESTINO_ROLE=${IAM_ROLE_STG}" >> $GITHUB_ENV
              echo "DESTINO_SCOPE=${NETWORK_SCOPE_STG}" >> $GITHUB_ENV
              ;;
            dev)
              echo "DESTINO_ROLE=${IAM_ROLE_DEV}" >> $GITHUB_ENV
              echo "DESTINO_SCOPE=${NETWORK_SCOPE_DEV}" >> $GITHUB_ENV
              ;;
            *)
              echo "❌ Destino no soportado: ${{ github.event.inputs.destino }}"
              exit 1
              ;;
          esac

      - name: Configurar AWS via OIDC para el Destino
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.DESTINO_ROLE }}
          aws-region: ${{ github.event.inputs.region_aws }}

      - name: Limpiar red del Destino
        uses: Griddo-infra/gha-grd-dbdt@v0.7
        with:
          mode: limpiar_red
          network_scope: ${{ env.DESTINO_SCOPE }}
          aws_region: ${{ github.event.inputs.region_aws }}
~~~

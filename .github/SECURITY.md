# Security Policy

## 🚨 Reportar Vulnerabilidades

Si encuentras alguna vulnerabilidad en este repositorio, por favor notifícalo de forma **privada** a través del siguiente canal:

- **Correo:** <infra@griddo.io>
- **No abras Issues públicos sobre vulnerabilidades.**

---

## 🔒 Buenas Prácticas Seguidas en este Repositorio

- Uso exclusivo de OIDC para autenticación contra AWS.
- AWS Roles de mínimo privilegio, con políticas dedicadas por entorno.
- Uso de secrets de GitHub correctamente segregados por entorno.
- Protección contra exposición de credenciales y secretos en logs.
- Prohibición de restauraciones sobre entornos `pro`.
- Presigned URLs no se almacenan ni exponen en outputs.
- Auditoría habilitada en AWS CloudTrail para uso de los roles.

---

## 🛡️ Seguridad de GitHub Actions

- Permisos mínimos declarados (`id-token`, `secrets`, `actions`, `contents`).
- Workflows limitados a miembros autorizados.
- `workflow_dispatch` revisado y protegido mediante branch protection.

---

## ✅ Responsabilidades del Equipo Griddo

|  Acción                             | Responsable  |
| ----------------------------------- | ------------ |
|  Validación de cambios en workflows | Griddo Infra |
|  Gestión de secretos                | Griddo Infra |
|  Revisión periódica de IAM policies | Griddo Infra |
|  Auditoría de logs y accesos        | Griddo Infra |

---

## 🔔 Notificación Responsable

Cumplimos con un plazo máximo de **30 días** para evaluar, priorizar y aplicar mitigaciones ante cualquier vulnerabilidad notificada.

# 🚥 Pull Request Checklist

Por favor, revisa y marca cada punto antes de solicitar la revisión de este PR.

## 📋 Cambios Propuestos

- [ ] Describe brevemente el cambio realizado (qué, por qué, para qué).

## 🔍 Seguridad

- [ ] No se han expuesto secrets ni presigned URLs en outputs ni logs.
- [ ] Se han verificado los permisos OIDC necesarios (mínimos y correctos).
- [ ] No afecta a la protección del entorno `pro`.

## 🚨 Workflows

- [ ] Si el PR toca `.github/workflows/`, ha sido revisado en profundidad.
- [ ] Se ha probado el funcionamiento correcto del workflow.

## 💡 Otros

- [ ] No rompe la compatibilidad con los entornos `dev`, `stg` o `pro`.
- [ ] Documentación actualizada si aplica (`README.md`, `SECURITY.md`).

## 👀 Revisión

- [ ] Revisión técnica por otro miembro del equipo.
- [ ] Revisión de seguridad si aplica.

---

### Comentarios adicionales

(Puedes explicar aquí cualquier aclaración para los revisores)

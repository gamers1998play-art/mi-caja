# Mi Caja

App web para gestionar una tienda: ventas, inventario, clientes, pedidos y cuentas.

## Estructura
- `index.html`: la aplicación (versión de prueba, datos guardados en el dispositivo).

## Reglas de seguridad del proyecto
- Nunca subir contraseñas, llaves secretas ni archivos `.env`.
- Cuando se conecte Supabase, solo la llave `anon` (pública) puede ir en el código. La `service_role` jamás.
- Activar verificación en dos pasos en GitHub.
- Cambios solo mediante commits; revisar antes de publicar.

## Publicación
GitHub Pages, rama `main`, carpeta raíz.

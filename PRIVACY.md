# Política de privacidad — eConsumo

**Última actualización: septiembre de 2026**

eConsumo es una app personal y de código abierto
([github.com/txurtxil/econsumo](https://github.com/txurtxil/econsumo)) para consultar
el consumo eléctrico doméstico.

## Datos que maneja la app

- **Credenciales de Datadis** (NIF y contraseña): se almacenan **cifradas** en el
  dispositivo mediante el Keystore de Android (`flutter_secure_storage`). Solo se
  usan para autenticarse en la API oficial de Datadis cuando el usuario pulsa
  "CONECTAR Y ACTUALIZAR". No hay sincronización automática.
- **Datos de consumo eléctrico**: se descargan de Datadis y se guardan **solo en el
  dispositivo** (caché local). El usuario puede exportarlos manualmente a un CSV en
  su carpeta de Descargas.
- **CUPS** (código del punto de suministro): se guarda localmente y solo se incluye
  en el CSV que el usuario exporta voluntariamente.

## A quién se comunican datos

La app se comunica únicamente con:

- `datadis.es` — API oficial de las distribuidoras eléctricas españolas (login y
  descarga de consumos).
- `api.esios.ree.es` — Red Eléctrica de España (precios PVPC públicos).

**No** hay analítica, **no** hay publicidad, **no** se envían datos a terceros y
**no** existe servidor propio. Todo el tratamiento ocurre en el dispositivo.

## Permisos

- **Internet**: para hablar con Datadis y E-SIOS.

No se solicitan más permisos.

## Eliminar tus datos

Borrar la app (o usar "Cerrar sesión" dentro de ella) elimina las credenciales y la
caché local. No queda ninguna copia fuera del dispositivo.

## Contacto

A través del repositorio: https://github.com/txurtxil/econsumo/issues

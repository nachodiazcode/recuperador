# recuperador

Recuperación de archivos borrados para macOS, en Swift, sin dependencias y sin límite de tamaño.

Hace dos cosas, y conviene saber cuál está haciendo:

1. **Lee el índice del disco** y saca los archivos borrados que todavía tienen nombre, carpeta, fecha y posición. Funciona en FAT16, FAT32, exFAT y NTFS. En NTFS el registro de la MFT sigue ahí, con el bit de "en uso" apagado, hasta que ese hueco se reutiliza.
2. **File carving**: recorre el espacio libre sector por sector, reconoce una firma (JPEG, PDF, MOV…) y calcula el tamaño leyendo la estructura del formato. No necesita el sistema de archivos, así que también sirve después de un formateo rápido.

Hay una app (`Recuperador`) y un comando (`recuperar`). Los dos usan el mismo núcleo y solo leen: nunca escriben en el disco que se está recuperando.

## App

```bash
swift run Recuperador
# o el .app
scripts/build-app.sh
```

La pantalla inicial pide el disco, el modo y qué tipos buscar. El modo rápido se queda en los índices. El completo, después, revisa el espacio libre. Los archivos aparecen mientras el escaneo sigue, con una nota de recuperabilidad: si el contenido no coincide con la extensión, si esos sectores ya se reasignaron, o si el tamaño es una estimación.

La ventana se puede achicar hasta el ancho de un teléfono. En ese tamaño las tarjetas se apilan, la galería baja a una o dos columnas y la barra lateral y el inspector pasan a ser paneles (Filtros y Detalles). En un ancho de tablet queda la barra lateral y el inspector se abre aparte. En escritorio no cambia.

La lista (el botón al lado de ordenar, o se queda guardada) sirve para revisar miles de archivos. ⌘R recupera lo seleccionado. ⌘. detiene el escaneo.

Las miniaturas se leen directo del disco escaneado y solo para lo que está en pantalla, así que no hace falta haber extraído nada. Su tamaño se cambia con el deslizador, pellizcando en el trackpad o con ⌘+ / ⌘−. Al pasar el puntero por una tarjeta aparecen dos atajos: vista previa y recuperar. En la galería las flechas mueven la selección.

Doble clic o la barra espaciadora abren el visor sobre la ventana: ← y → (o la tira de miniaturas de abajo) pasan de archivo, el pellizco, el doble clic o + − 0 hacen zoom en las fotos y Esc lo cierra. Los videos MP4 y MOV se reproducen y se analizan directo del disco, sin copiarlos antes: uno de varios GB empieza a verse en menos de un segundo. Los formatos que macOS no abre (MKV, AVI, WebM) no se pueden comprobar; se recuperan igual y se abren con otra app.

En el visor, "Mejorar" procesa la foto en el propio Mac, sin internet: ajuste automático de Core Image y, en macOS 26, ampliación ×4 con el modelo de superresolución de Apple para fotos de hasta 1920 px de lado (macOS baja el modelo la primera vez). Mantener apretado "comparar" muestra la original. La foto recuperada nunca se modifica: "Guardar copia…" escribe un archivo nuevo, con su fecha y su ubicación, y no deja guardarlo en el disco que se está escaneando.

Las animaciones pesadas (cambio de sección, de tema, abrir el visor) son fundidos de Core Animation: no dependen del hilo principal y no se traban aunque la pantalla nueva tarde en armarse. La selección y el visor viven aparte del resto del estado, así que moverse con las flechas redibuja dos tarjetas y no la ventana entera.

Los sonidos son tonos cortos de sintetizador, en la misma escala: un barrido al empezar, un acorde si hubo resultado, una nota aguda si no apareció nada, un tic al detener y un acorde menor si algo falla. El aviso de macOS sale en silencio, también con la ventana detrás, para no tapar el tono. Los dos se apagan en el menú de la paleta. La primera vez el sistema pide permiso para los avisos.

"Buscar también lo que está dentro de otro archivo" recupera, por ejemplo, una foto metida en un Word. Apagado —que es el valor por defecto— el escaneo salta el interior de cada archivo y la lista no se llena de duplicados.

La sección Limpiar no recupera nada: vacía cachés regenerables y la caché de archivos en RAM. La primera vez pide confirmación y un permiso limitado a `purge`.

## Línea de comandos

```bash
swift build -c release
diskutil list

# Clonar primero si el disco falla, y trabajar sobre la imagen
sudo .build/release/recuperar clonar /dev/rdisk4 /Volumes/OtroDisco/disco4.img
.build/release/recuperar escanear /Volumes/OtroDisco/disco4.img -o /Volumes/OtroDisco/recuperados

# O escanear el disco directamente
sudo .build/release/recuperar escanear /dev/rdisk4 -o /Volumes/OtroDisco/recuperados -t jpg,png,mov

# Solo los borrados con nombre, sin carving
sudo .build/release/recuperar escanear /dev/rdisk4 --rapido --solo-listar

# Incluir lo que está dentro de otros archivos
sudo .build/release/recuperar escanear /dev/rdisk4 -o /Volumes/OtroDisco/recuperados --embebidos
```

Lo recuperado queda en `recuperados/<extensión>/` con un `reporte.csv`.

Si macOS no deja abrir el disco, el comando usa el diálogo de administrador (`authopen`). Si aun así falla, dale a la Terminal **Acceso total al disco** en Ajustes del Sistema → Privacidad y seguridad. El SSD interno de un Mac no se puede leer en crudo: lo impide la Protección de Integridad del Sistema.

**Reglas de oro**

1. Deja de usar el disco afectado. Cada escritura puede pisar lo que buscas.
2. Nunca guardes lo recuperado en el mismo disco. El programa se niega a hacerlo, también cuando el volumen es APFS y el disco físico es otro.
3. Usa `/dev/rdiskN`, no `/dev/diskN`.

## Cuándo funciona

| Medio | ¿Recuperable? |
|---|---|
| Disco duro, pendrive o tarjeta SD (FAT, exFAT, NTFS, HFS+), borrado o formateo rápido | Sí, mientras no se haya escrito encima |
| Formateo completo (escribe ceros) | No |
| SSD interno de un Mac con Apple Silicon o T2 | Prácticamente no: TRIM vacía los bloques liberados y FileVault cifra por hardware |
| SSD externo con TRIM activo | Muy poco probable |

## HFS+ dañado

Si macOS no monta un volumen HFS+, el índice B-tree suele estar roto por la raíz y sano en las hojas. `respaldar-hfs` lee esas hojas y copia cada archivo con su carpeta, su nombre y sus fechas. `nube-hfs` hace lo mismo hacia un remoto de rclone, sin pasar la copia por el disco local. Ese camino asume `rclone` en `/opt/homebrew/bin/rclone` y está pensado para un respaldo grande, no como función general de la app.

```bash
sudo .build/release/recuperar respaldar-hfs /dev/rdisk4s2 -o /Volumes/OtroDisco/respaldo
```

## Tipos del carving

`recuperar tipos` imprime la lista real. Entran JPEG, PNG, GIF, BMP, TIFF y RAW (CR2, NEF, ARW, DNG…), PSD, MP4/MOV/HEIC/AVIF, WAV/AVI/WebP, MKV/WebM, WMV, FLV, MPEG, MTS, MP3, Ogg, FLAC, AIFF, MIDI, PDF, ZIP y Office (doc, docx, xls, xlsx, ppt, pptx, odt, epub, páginas de iWork), 7z, RAR, gzip, ISO y SQLite.

FLAC, RAR y gzip no declaran su tamaño: el corte es una estimación y la app lo marca.

## Arquitectura

- `DiskReader`: lectura de solo lectura, alineada a sector, con caché y tolerancia a sectores dañados.
- `FileSystems` y `NTFS`: entradas borradas de FAT, exFAT y NTFS. Devuelven también los rangos ocupados, para que el carving no vuelva a leer archivos que siguen vivos.
- `HFSPlus`: catálogo de un volumen HFS+, leyendo nodos hoja aunque el árbol esté roto.
- `Signatures`: un parser por formato. Valida la estructura y calcula la longitud.
- `Carver`: recorre el espacio libre. Por defecto salta el interior de un archivo cuya longitud es exacta.
- `Extractor`: copia un archivo del disco en tramos de 4 MB, o lo lee a memoria, sin pasar por la caché de páginas. Lo usan la recuperación, las miniaturas y la reproducción de video.
- `DiskSafety`: impide escribir en el mismo disco físico.
- `Rescue`: clonado en dos pasadas, al estilo `ddrescue`, para un disco que se está muriendo.

## Límites conocidos

- El carving supone sectores contiguos. Un video fragmentado en un disco muy usado puede salir corrupto. NTFS y exFAT sí reconstruyen los fragmentos que el índice todavía describe; FAT, al borrar, pone la cadena a cero y ahí se asume que el archivo era contiguo.
- Un PDF con actualizaciones incrementales puede quedar cortado en el primer `%%EOF`, salvo que esté linealizado.
- APFS no guarda las entradas borradas como FAT o NTFS. En un volumen APFS solo queda el carving, y con FileVault o TRIM suele no quedar nada.
- Los archivos NTFS comprimidos o cifrados por el propio NTFS se omiten: los bytes del disco no son el archivo.
- Un archivo residente de NTFS cuyo contenido cae justo en los dos bytes de control de un sector no se copia, para no devolver datos cambiados.

## Pruebas

```bash
swift test
```

Cubren el carving de JPEG, PNG y GIF sobre una imagen con basura, el salto del interior de un archivo, y un volumen NTFS sintético: un borrado con sus datos en otro clúster, un archivo residente dentro de una carpeta borrada, y un archivo que sigue vivo y no debe aparecer. También la lectura directa: tramos alineados y desalineados, archivos fragmentados y el avance de la copia.

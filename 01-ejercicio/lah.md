# Permisos de archivos y directorios — `~/laboratorio-cli`

## Tabla de permisos

| Ruta del archivo | Nombre del archivo | Permisos | Secuencia r-w-x (dueño / grupo / otros) | Permisos transformados |
|---|---|---|---|---|
| `~/laboratorio-cli/` | README.txt | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/` | docs | `drwxrwxr-x` | 421 / 421 / 401 | 775 |
| `~/laboratorio-cli/` | docs{guia,notas}.md | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/` | logs | `drwxrwxr-x` | 421 / 421 / 401 | 775 |
| `~/laboratorio-cli/` | src | `drwxrwxr-x` | 421 / 421 / 401 | 775 |
| `~/laboratorio-cli/docs/` | guia.md | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/docs/` | notas.md | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/logs/` | README.txt | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/logs/` | app.log | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/logs/` | app.logREADME.txt | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/src/` | main.py | `-rw-rw-r--` | 420 / 420 / 400 | 664 |
| `~/laboratorio-cli/src/` | test.py | `-rw-rw-r--` | 420 / 420 / 400 | 664 |

> **Nota sobre la transformación:** cada bloque de permisos (`rwx`) se representa como una secuencia de tres dígitos fijos —4 (lectura), 2 (escritura), 1 (ejecución)— colocando un 0 cuando el permiso no está activo. Así, `rw-` se escribe como `420` (el 1 de ejecución se apaga a 0) y `rwx` como `421`. Sumando cada secuencia se obtiene el dígito octal final: `420 → 6` y `421 → 7`. Por eso `rw-rw-r--` = 664 y `rwxrwxr-x` = 775.

---

## Evidencia (capturas de pantalla)

### 1. Directorio raíz `~/laboratorio-cli`
![Listado del directorio raíz](imagenes/img1_raiz.png)

### 2. Directorio `~/laboratorio-cli/docs`
![Listado del directorio docs](imagenes/img2_docs.png)

### 3. Directorio `~/laboratorio-cli/logs`
![Listado del directorio logs](imagenes/img3_logs.png)

### 4. Directorio `~/laboratorio-cli/src`
![Listado del directorio src](imagenes/img4_src.png)

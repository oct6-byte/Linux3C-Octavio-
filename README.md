# Linux3C-Octavio-

Repositorio de prácticas de Linux. Todo el contenido está dentro de la carpeta `UNIDAD1`.

## Estructura

```
UNIDAD1/
├── markdown/    documentos .md
├── txt/         archivos .txt
└── imagenes/    capturas de pantalla (NN_comando_fecha)
```

## Documentos

| Archivo | Contenido |
|---|---|
| [markdown/lah.md](UNIDAD1/markdown/lah.md) | Permisos de archivos y directorios en `~/laboratorio-cli` |
| [markdown/practica_laboratorio-cli.md](UNIDAD1/markdown/practica_laboratorio-cli.md) | Navegación, historial y alias en la terminal |
| [markdown/comando_alias.md](UNIDAD1/markdown/comando_alias.md) | El comando `alias` |
| [txt/lah.txt](UNIDAD1/txt/lah.txt) | Salida en texto de `ls -lah` |

## Capturas

Las capturas se nombran `NN_comando_fecha`, donde `NN` es el orden cronológico,
`comando` es el primer comando que aparece en la captura y `fecha` es la fecha en
que se tomó.

| # | Captura | Comando |
|---|---|---|
| 01 | 2026-08-17 | `nano app.log` |
| 02 | 2026-08-17 | `cd` (creación de la estructura `laboratorio-cli`) |
| 03 | 2026-08-17 | `ls -lah` y variantes |
| 04 | 2026-08-23 | `ls -lah` en `~/laboratorio-cli` |
| 05 | 2026-08-23 | `ls -lah` en `docs` |
| 06 | 2026-08-23 | `ls -lah` en `logs` |
| 07 | 2026-08-23 | `ls -lah` en `src` |
| 08 | 2026-08-26 | `cd` entre directorios |
| 09 | 2026-08-26 | `cd -` |
| 10 | 2026-08-26 | `history 10 \| grep 'cd'` |
| 11 | 2026-08-26 | `alias ll='ls -lah --color=auto'` |
| 12 | 2026-08-26 | `type ll` |
| 13 | 2026-08-26 | `ll docs` |
| 14 | 2026-08-26 | `unalias ll` |
| 15 | 2026-08-26 | `alias` |
| 16 | 2026-08-31 | `mkdir -p carpetaProyectos/{web,movil}` |
| 17 | 2026-08-31 | `nano notas.txt` |

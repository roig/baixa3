# SX3Downloader

Eina de terminal escrita amb la biblioteca estàndard de Python. Detecta automàticament si una URL de 3Cat correspon a un episodi o a una sèrie, mostra tot el material descarregable i descarrega els vídeos.

## Requisits

- Python 3.11 o superior.
- No cal instal·lar cap paquet de Python.
- [FFmpeg](https://ffmpeg.org/) és opcional. Quan està disponible permet escollir les versions DASH, les pistes d'àudio i els subtítols, i ho combina tot en un MP4. Sense FFmpeg només es mostren fitxers directes que ja contenen vídeo i àudio, com l'MP4 de 720p.

## Ús

```powershell
python main.py URL
```

Exemple amb un episodi:

```powershell
python main.py "https://www.3cat.cat/tv3/sx3/t1xc1-la-patrulla-fa-un-rescat-passat-per-aigua/video/6314970/"
```

Mostra l’ID i totes les dades retornades per l’API de 3Cat. Si detecta FFmpeg, el selector mostra els vídeos, els àudios i els subtítols disponibles. El vídeo de més qualitat queda seleccionat per defecte, i totes les pistes d'àudio i subtítols queden incloses per defecte. En els episodis comprovats hi ha 1080p, 720p i 576p dins del manifest DASH, a més de l’MP4 directe de 720p.

Si no detecta FFmpeg, no mostra les representacions DASH ni les pistes separades: només ofereix formats directes complets com MP4, M4V, MOV, MKV o WebM.

Exemple amb una sèrie:

```powershell
python main.py "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/"
```

Mostra les temporades i, dins de cadascuna, l’ID, número, títol, durada, miniatura i URL de cada episodi. Després permet seleccionar una sola vegada el vídeo, els àudios i els subtítols; aquesta selecció s'aplica a tota la sèrie.

Els vídeos es desen dins de `videos/Temporada N/`. Si un fitxer ja existeix, el programa no el torna a descarregar. Una descàrrega incompleta utilitza temporalment l’extensió `.part` i s’elimina si es produeix un error.

Si la URL no és vàlida o no correspon a cap d’aquests tipus, el programa mostra un error i exemples d’ús.

## Proves

```powershell
python -m unittest discover -s tests -v
```

El programa només consulta informació pública de 3Cat i no intenta saltar DRM, autenticació ni cap protecció de la plataforma.

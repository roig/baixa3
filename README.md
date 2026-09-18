# SX3Downloader

Eina de terminal escrita només amb la biblioteca estàndard de Python. Detecta automàticament si una URL de 3Cat correspon a un episodi o a una sèrie.

En aquesta fase el programa només mostra informació en text; no descarrega cap vídeo.

## Requisits

- Python 3.11 o superior.
- No cal instal·lar cap dependència.

## Ús

```powershell
python main.py URL
```

Exemple amb un episodi:

```powershell
python main.py "https://www.3cat.cat/tv3/sx3/t1xc1-la-patrulla-fa-un-rescat-passat-per-aigua/video/6314970/"
```

Mostra l’ID, tots els formats MP4, la millor qualitat detectada i totes les dades retornades per l’API de 3Cat.

Exemple amb una sèrie:

```powershell
python main.py "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/"
```

Mostra les temporades i, dins de cadascuna, l’ID, número, títol, durada, miniatura i URL de cada episodi.

Si la URL no és vàlida o no correspon a cap d’aquests tipus, el programa mostra un error i exemples d’ús.

## Proves

```powershell
python -m unittest discover -s tests -v
```

El programa només consulta informació pública de 3Cat i no intenta saltar DRM, autenticació ni cap protecció de la plataforma.

# SX3Downloader

Aplicació gràfica multiplataforma escrita amb Zig, Sokol i Dear ImGui per consultar i descarregar el material públic disponible als episodis de 3Cat/SX3.

## Funcionalitat

- Accepta l'URL d'un episodi, d'una sèrie o d'una temporada. Una URL de temporada es resol automàticament a la sèrie sencera.
- Reconeix tant les URL antigues de SX3 (`/tv3/sx3/.../videos/temporada-N/`) com les noves de 3Cat (`/3cat/.../capitols/temporada/N/`).
- En una sèrie, mostra totes les temporades en un arbre plegable i permet seleccionar diversos episodis amb checkboxes. El node arrel i cada temporada tenen un checkbox de selecció conjunta, amb estat parcial quan només hi ha alguns episodis marcats.
- El detall d'un episodi separa **Descàrrega individual** i **Muxing** en dos tabs.
- **Descàrrega individual:** mostra tots els vídeos, àudios i subtítols i baixa exactament els fitxers seleccionats. Aquest camí no detecta, invoca ni necessita FFmpeg.
- **Muxing:** el tab només es mostra quan FFmpeg està instal·lat. Permet seleccionar un vídeo DASH, diversos àudios, l'àudio per defecte i els subtítols, i genera un MP4.
- En una sèrie, les opcions dels tabs s'apliquen seqüencialment a tots els episodis seleccionats. La descàrrega individual permet baixar el vídeo complet, les pistes separades o totes dues coses; el muxing intenta reproduir el perfil de vídeo, àudio i subtítols en cada episodi.
- Durant una descàrrega la interfície queda temporalment en mode de només lectura i mostra el progrés.

La descàrrega individual d'una representació DASH uneix, mitjançant HTTP, el segment d'inicialització i els fragments de la mateixa pista. El resultat continua sent una pista independent; no s'hi barreja cap àudio, vídeo ni subtítol.

## Compilar

Cal Zig 0.16.0. Les versions fixades de Sokol i Dear ImGui ja són a `vendor/`; no cal `build.zig.zon`, Git ni cap gestor de dependències.

```powershell
zig build -Doptimize=ReleaseSafe
```

L'executable queda a `zig-out/bin/sx3downloader.exe` a Windows. A macOS i Linux no porta l'extensió `.exe`.

Per compilar a Linux cal tenir disponibles les biblioteques de desenvolupament d'OpenGL, X11, Xi i Xcursor. A Windows s'utilitza D3D11 i a macOS, Metal.

## Executar

```powershell
zig build run
```

També es pot executar directament el binari compilat. Els fitxers es desen a la carpeta `downloads/` del directori de treball.

FFmpeg és completament opcional. Si no es troba al `PATH`, la secció de muxing no apareix, però tota la descàrrega individual continua disponible.

## Proves

```powershell
zig build test
```

El client de terminal anterior en Python es conserva de moment a `main.py` i `sx3downloader/`.

El programa només consulta material públic exposat per 3Cat i no intenta saltar DRM, autenticació ni cap protecció de la plataforma.

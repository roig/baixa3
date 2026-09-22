# Baixa3

**Baixa vídeos públics de 3Cat amb una interfície senzilla.**

Baixa3 permet cercar programes i sèries de 3Cat, seleccionar episodis i desar-los a l'ordinador. No cal saber programar ni escriure cap ordre.

> Baixa3 és una aplicació no oficial i no està afiliada a 3Cat ni a la CCMA.

## Inici ràpid a Windows

### 1. Descarrega el programa

1. Obre l'apartat **Releases** d'aquest repositori.
2. Entra a la versió més recent.
3. Descarrega `baixa3.exe`.

No cal instal·lar Python, Zig ni cap altra dependència.

### 2. Prepara una carpeta

1. Crea una carpeta anomenada `Baixa3` on vulguis.
2. Mou-hi el fitxer `baixa3.exe`.
3. Fes doble clic a `baixa3.exe`.

Les descàrregues es guardaran automàticament dins d'una carpeta `downloads`, al costat del programa.

> Windows pot mostrar un avís perquè l'aplicació no està signada digitalment. Si l'has descarregat d'aquest repositori, prem **Més informació** i després **Executa igualment**.

## Com es fa servir

### Opció A: cercar al catàleg

Aquesta és la manera més fàcil i apareix seleccionada per defecte.

1. Obre Baixa3 i espera que acabi de carregar la base de dades.
2. Obre el desplegable **Selecciona un títol**.
3. Tria el programa o la sèrie que vols.
4. Marca els episodis que vulguis descarregar.
5. A **Descàrrega individual**, deixa marcada l'opció del vídeo complet.
6. Prem **Descarrega els episodis seleccionats**.

Pots marcar una sèrie sencera, una temporada completa o episodis individuals.

### Opció B: enganxar un enllaç

1. Obre la pestanya **Descàrrega directa**.
2. Copia l'enllaç d'un episodi, programa, sèrie o temporada de 3Cat.
3. Enganxa'l al camp de text.
4. Prem **Cerca**.
5. Selecciona què vols baixar i prem el botó de descàrrega.

Exemples d'enllaços acceptats:

```text
https://www.3cat.cat/3cat/nom-del-programa/
https://www.3cat.cat/3cat/nom-del-programa/capitols/
https://www.3cat.cat/3cat/nom-del-video/video/1234567/
https://www.3cat.cat/tv3/sx3/nom-de-la-serie/
```

## On es guarden els vídeos?

Quan descarregues diversos episodis, Baixa3 els ordena per sèrie i temporada:

```text
Baixa3/
├── baixa3.exe
└── downloads/
    └── Nom de la sèrie/
        ├── Temporada 1/
        └── Temporada 2/
```

Els programes sense temporades es desen dins de `Capítols`:

```text
downloads/Nom del programa/Capítols/
```

Els episodis oberts directament es desen a la carpeta `downloads`.

## Descàrrega individual i muxing

### Descàrrega individual — recomanada

És l'opció més senzilla i no necessita cap programa addicional. Permet baixar:

- El vídeo complet en MP4, MKV o un altre format disponible.
- Les pistes de vídeo i àudio per separat.
- Els subtítols.

Per a la majoria d'usuaris, n'hi ha prou de deixar marcada l'opció del vídeo complet.

### Muxing — opcional i avançat

El muxing permet escollir una qualitat de vídeo, diversos àudios i subtítols, i combinar-ho tot en un únic MP4.

Aquesta pestanya només apareix si tens **FFmpeg** instal·lat i disponible al `PATH`. Si no hi és, Baixa3 continua funcionant normalment amb la descàrrega individual.

Pots obtenir FFmpeg des del seu [web oficial](https://ffmpeg.org/download.html).

## Preguntes freqüents

### Necessito instal·lar Python?

No. `baixa3.exe` és una aplicació independent.

### Necessito FFmpeg?

No. FFmpeg només és necessari per utilitzar la pestanya de muxing.

### Per què no apareix la pestanya de muxing?

Baixa3 no ha trobat FFmpeg al `PATH`. Tanca l'aplicació, instal·la o configura FFmpeg i torna-la a obrir.

### On és la descàrrega?

Busca la carpeta `downloads` al mateix directori on tens `baixa3.exe`.

### Puc descarregar una temporada sencera?

Sí. Marca la casella de la temporada. També pots marcar la casella principal per seleccionar tota la sèrie.

### La base de dades no carrega

Comprova la connexió a Internet i prem **Torna-ho a provar** o **Actualitza**.

## Plataformes

El codi està preparat per funcionar a:

- Windows amb D3D11.
- macOS amb Metal.
- Linux amb OpenGL i X11.

Les instruccions d'inici ràpid d'aquest document corresponen al binari de Windows. A macOS i Linux, de moment, es pot compilar des del codi font.

## Compilar des del codi font

Aquesta secció és només per a desenvolupadors. Els usuaris de Windows poden descarregar directament `baixa3.exe`.

### Requisits

- Zig 0.16.0.
- A Linux: biblioteques de desenvolupament d'OpenGL, X11, Xi i Xcursor.

Sokol i Dear ImGui ja estan inclosos dins de `vendor/`. No cal descarregar dependències Zig addicionals.

### Compilar una versió optimitzada

```powershell
zig build -Doptimize=ReleaseSafe
```

El resultat queda a:

```text
zig-out/bin/baixa3.exe
```

A macOS i Linux, el fitxer s'anomena `baixa3` sense l'extensió `.exe`.

### Executar des del projecte

```powershell
zig build run
```

### Executar les proves

```powershell
zig build test
```

## Privacitat i ús responsable

Baixa3 només consulta contingut públic exposat per 3Cat. No intenta evitar DRM, autenticació ni altres proteccions de la plataforma.

Utilitza'l de manera responsable i respecta els drets, les condicions d'ús i les restriccions aplicables al contingut que descarreguis.

---

Versió actual: **0.2.3**

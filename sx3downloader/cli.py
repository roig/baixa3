from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
import re
import sys
import unicodedata
from urllib.parse import urlparse

from .client import (
    ClientError,
    DownloadCatalog,
    Media,
    Track,
    UnsupportedUrlError,
    download_catalog,
    download_media,
    download_with_ffmpeg,
    discover_series,
    ffmpeg_available,
    fetch_episode_data,
    media_options,
)
from .parser import Episode, Season, clean_text, extract_episode_id


EXAMPLE_SERIES = "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/"
EXAMPLE_EPISODE = (
    "https://www.3cat.cat/tv3/sx3/"
    "t1xc1-la-patrulla-fa-un-rescat-passat-per-aigua/video/6314970/"
)


@dataclass
class DownloadSelection:
    video: Media
    audio: list[Track]
    subtitles: list[Track]
    use_ffmpeg: bool


def _arguments() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python main.py",
        description=(
            "Detecta si una URL de 3Cat és un episodi o una sèrie. "
            "En mostra la informació, pregunta la qualitat i descarrega els vídeos."
        ),
    )
    parser.add_argument("url", metavar="URL", help="URL d'un episodi o d'una sèrie de 3Cat")
    return parser


def _validate_url(url: str) -> None:
    try:
        parsed = urlparse(url)
    except ValueError as error:
        raise UnsupportedUrlError("La URL no és vàlida.") from error

    host = (parsed.hostname or "").lower()
    valid_host = host == "3cat.cat" or host.endswith(".3cat.cat")
    if parsed.scheme not in {"http", "https"} or not valid_host:
        raise UnsupportedUrlError(
            "Cal indicar una URL HTTP o HTTPS del domini 3cat.cat."
        )


def _value_text(value: object) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return clean_text(value)
    return str(value)


def _display_duration(value: str | None) -> str:
    if not value:
        return "desconeguda"
    match = re.fullmatch(r"PT(\d+)H(\d+)M(\d+)S", value, flags=re.IGNORECASE)
    if not match:
        return value
    hours, minutes, seconds = (int(part) for part in match.groups())
    return f"{hours:02d}:{minutes:02d}:{seconds:02d} ({value})"


def _safe_filename(value: str) -> str:
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value)
    value = re.sub(r"\s+", " ", value).strip().rstrip(". ")
    return value or "video"


def _print_tree(value: object, indent: int = 0) -> None:
    prefix = " " * indent
    if isinstance(value, Mapping):
        if not value:
            print(f"{prefix}{{}}")
            return
        for key, child in value.items():
            if isinstance(child, (Mapping, list, tuple)):
                print(f"{prefix}{key}:")
                _print_tree(child, indent + 2)
            else:
                print(f"{prefix}{key}: {_value_text(child)}")
        return

    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        if not value:
            print(f"{prefix}[]")
            return
        for index, child in enumerate(value, start=1):
            if isinstance(child, (Mapping, list, tuple)):
                print(f"{prefix}[{index}]")
                _print_tree(child, indent + 2)
            else:
                print(f"{prefix}[{index}] {_value_text(child)}")
        return

    print(f"{prefix}{_value_text(value)}")


def _print_episode_summary(episode: Episode, indent: str = "  ") -> None:
    number = str(episode.number) if episode.number is not None else "desconegut"
    print(f"{indent}ID: {episode.id}")
    print(f"{indent}Temporada: {episode.season}")
    print(f"{indent}Capítol: {number}")
    print(f"{indent}Títol: {episode.title}")
    print(f"{indent}Durada: {_display_duration(episode.duration)}")
    print(f"{indent}Miniatura: {episode.thumbnail or 'no disponible'}")
    print(f"{indent}URL: {episode.url}")


def _bitrate_text(bandwidth: int | None) -> str | None:
    if not bandwidth:
        return None
    if bandwidth >= 1_000_000:
        return f"{bandwidth / 1_000_000:.1f} Mbit/s"
    return f"{bandwidth / 1000:.0f} kbit/s"


def _codec_text(codec: str | None) -> str | None:
    if not codec:
        return None
    if codec.startswith("avc1"):
        return f"H.264 ({codec})"
    if codec.startswith("mp4a"):
        return f"AAC ({codec})"
    return codec


def _media_description(media: Media) -> str:
    details = [media.label, media.protocol]
    if media.width and media.height:
        details.append(f"{media.width}x{media.height}")
    bitrate = _bitrate_text(media.bandwidth)
    codec = _codec_text(media.codec)
    if bitrate:
        details.append(bitrate)
    if codec:
        details.append(codec)
    return " · ".join(details)


def _show_episode(url: str, episode_id: str) -> tuple[dict, DownloadCatalog]:
    payload = fetch_episode_data(episode_id)
    catalog = download_catalog(payload, include_dash=ffmpeg_available())

    print("Tipus: episodi")
    print(f"URL: {url}")
    print(f"ID: {episode_id}")
    print(f"Formats de vídeo: {len(catalog.videos)}")
    if catalog.videos:
        print(f"Millor qualitat detectada: {_media_description(catalog.videos[0])}")
    else:
        print("Millor qualitat detectada: cap vídeo")
    print("\nDades completes retornades per 3Cat:")
    _print_tree(payload, indent=2)
    return payload, catalog


def _show_series(url: str, seasons: list[Season]) -> None:
    print("Tipus: sèrie")
    print(f"URL: {url}")
    print(f"Temporades: {len(seasons)}")
    print(f"Episodis totals: {sum(len(season.episodes) for season in seasons)}")

    for season in seasons:
        print(f"\nTemporada {season.number} ({len(season.episodes)} episodis)")
        print(f"URL de temporada: {season.url}")
        for episode in season.episodes:
            label = f"Capítol {episode.number}" if episode.number is not None else "Episodi"
            print(f"\n  {label}")
            _print_episode_summary(episode, indent="    ")


def _choose_quality(options: list[Media], *, series: bool = False) -> Media | None:
    if not options:
        print("No hi ha cap fitxer de vídeo complet disponible.")
        return None

    print("\nAvailable videos (la millor qualitat està seleccionada per defecte):")
    for index, option in enumerate(options, start=1):
        checked = "[x]" if index == 1 else "[ ]"
        print(f"  {index}. {checked} {_media_description(option)}")
    print("  0. Cancel·lar")
    if series:
        print("La selecció s'aplicarà a tota la sèrie.")

    while True:
        try:
            answer = input("Selecciona un vídeo [1]: ").strip()
        except EOFError:
            print("Entrada interactiva no disponible; descàrrega cancel·lada.")
            return None
        if not answer:
            return options[0]
        if answer == "0":
            print("Descàrrega cancel·lada.")
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return options[int(answer) - 1]
        print(f"Opció no vàlida. Escriu un número entre 0 i {len(options)}.")


def _track_description(track: Track) -> str:
    language = {
        "ca": "Català",
        "es": "Castellà",
        "en": "Anglès",
        "fr": "Francès",
        "de": "Alemany",
        "it": "Italià",
    }.get((track.language or "").casefold(), track.language)
    details = [track.label]
    if track.kind == "audio" and language:
        details = [language]
    elif language and language.casefold() not in track.label.casefold():
        details.append(language)
    bitrate = _bitrate_text(track.bandwidth)
    codec = _codec_text(track.codec)
    if bitrate:
        details.append(bitrate)
    if codec:
        details.append(codec)
    return " · ".join(details)


def _choose_tracks(title: str, tracks: list[Track]) -> list[Track] | None:
    print(f"\n{title} (tots seleccionats per defecte):")
    if not tracks:
        print("  Cap")
        return []
    for index, track in enumerate(tracks, start=1):
        print(f"  {index}. [x] {_track_description(track)}")
    print("  0. Cap")

    while True:
        try:
            answer = input(
                "Selecciona números separats per comes [tots]: "
            ).strip()
        except EOFError:
            print("Entrada interactiva no disponible; descàrrega cancel·lada.")
            return None
        if not answer:
            return list(tracks)
        if answer == "0":
            return []
        try:
            indexes = [int(value.strip()) for value in answer.split(",")]
        except ValueError:
            indexes = []
        if indexes and all(1 <= index <= len(tracks) for index in indexes):
            unique_indexes = list(dict.fromkeys(indexes))
            return [tracks[index - 1] for index in unique_indexes]
        print(f"Opció no vàlida. Usa números entre 1 i {len(tracks)}, o 0.")


def _choose_download(
    catalog: DownloadCatalog, *, series: bool = False
) -> DownloadSelection | None:
    has_ffmpeg = ffmpeg_available()
    videos = (
        catalog.videos
        if has_ffmpeg
        else [video for video in catalog.videos if video.protocol != "DASH"]
    )
    if not has_ffmpeg:
        print(
            "\nFFMPEG NO DETECTAT: només es mostren fitxers directes "
            "que ja contenen vídeo i àudio."
        )

    video = _choose_quality(videos, series=series)
    if video is None:
        return None
    if not has_ffmpeg:
        return DownloadSelection(video, [], [], False)

    audio = _choose_tracks("Available audios", catalog.audio)
    if audio is None:
        return None
    subtitles = _choose_tracks("Available subtitles", catalog.subtitles)
    if subtitles is None:
        return None
    return DownloadSelection(video, audio, subtitles, True)


def _quality_by_label(
    options: list[Media], label: str, protocol: str | None = None
) -> Media | None:
    for option in options:
        same_protocol = protocol is None or option.protocol == protocol
        if option.label.casefold() == label.casefold() and same_protocol:
            return option
    return options[0] if options else None


def _progress_printer(received: int, total: int) -> None:
    if total:
        percent = min(received * 100 // total, 100)
        print(
            f"\r  {percent:3d}%  {received / 1024 / 1024:.1f}"
            f"/{total / 1024 / 1024:.1f} MiB",
            end="",
            flush=True,
        )
    else:
        print(f"\r  {received / 1024 / 1024:.1f} MiB", end="", flush=True)


def _download_one(selection: DownloadSelection, destination: Path) -> None:
    media = selection.video
    if destination.exists():
        print(f"Ja existeix, s'omet: {destination}")
        return
    print(f"Descarregant [{_media_description(media)}]: {destination}")
    if selection.use_ffmpeg:
        print(
            f"  FFmpeg està combinant 1 vídeo, {len(selection.audio)} àudio(s) "
            f"i {len(selection.subtitles)} subtítol(s)..."
        )
        download_with_ffmpeg(
            media,
            destination,
            selection.audio,
            selection.subtitles,
        )
        print(f"Fet: {destination}")
    else:
        download_media(media, destination, _progress_printer)
        print(f"\nFet: {destination}")


def _episode_destination(payload: dict, episode_id: str) -> Path:
    information = payload.get("informacio", {})
    if not isinstance(information, Mapping):
        information = {}
    title = str(information.get("titol") or f"Episodi {episode_id}")
    chapter_value = information.get("capitol")
    try:
        chapter = int(chapter_value) if chapter_value is not None else None
    except (TypeError, ValueError):
        chapter = None
    season_data = information.get("temporada", {})
    season_id = season_data.get("idName") if isinstance(season_data, Mapping) else None
    season_match = re.search(r"(\d+)$", str(season_id or ""))
    season = int(season_match.group(1)) if season_match else None
    if season is not None and chapter is not None:
        code = f"S{season:02d}E{chapter:02d}"
        folder = Path("videos") / f"Temporada {season}"
    else:
        code = episode_id
        folder = Path("videos")
    return folder / f"{code} - {_safe_filename(title)}.mp4"


def _series_destination(episode: Episode) -> Path:
    code = (
        f"S{episode.season:02d}E{episode.number:02d}"
        if episode.number is not None
        else f"S{episode.season}-{episode.id}"
    )
    return (
        Path("videos")
        / f"Temporada {episode.season}"
        / f"{code} - {_safe_filename(episode.title)}.mp4"
    )


def _selection_destination(path: Path, selection: DownloadSelection) -> Path:
    if selection.use_ffmpeg:
        return path.with_suffix(".mp4")
    extension = selection.video.protocol.casefold()
    if extension in {"mp4", "m4v", "mov", "mkv", "webm"}:
        return path.with_suffix(f".{extension}")
    return path


def _download_episode(
    episode_id: str, payload: dict, catalog: DownloadCatalog | None = None
) -> None:
    catalog = catalog or download_catalog(payload, include_dash=ffmpeg_available())
    selection = _choose_download(catalog)
    if selection:
        destination = _selection_destination(
            _episode_destination(payload, episode_id), selection
        )
        _download_one(selection, destination)


def _matching_tracks(available: list[Track], selected: list[Track]) -> list[Track]:
    matches: list[Track] = []
    used: set[int] = set()
    for wanted in selected:
        match_index = next(
            (
                index
                for index, track in enumerate(available)
                if index not in used
                and track.label.casefold() == wanted.label.casefold()
                and track.language == wanted.language
            ),
            None,
        )
        if match_index is None and wanted.language:
            match_index = next(
                (
                    index
                    for index, track in enumerate(available)
                    if index not in used and track.language == wanted.language
                ),
                None,
            )
        if match_index is not None:
            used.add(match_index)
            matches.append(available[match_index])
    return matches


def _download_series(seasons: list[Season]) -> None:
    episodes = [episode for season in seasons for episode in season.episodes]
    if not episodes:
        raise ClientError("La sèrie no conté episodis descarregables.")

    first = episodes[0]
    first_payload = fetch_episode_data(first.id)
    first_catalog = download_catalog(first_payload, include_dash=ffmpeg_available())
    print("\nSelecció per a tota la sèrie, basada en el primer episodi:")
    selection = _choose_download(first_catalog, series=True)
    if selection is None:
        return

    print(
        f"\nComençant {len(episodes)} descàrregues amb preferència "
        f"{selection.video.label}."
    )
    for index, episode in enumerate(episodes, start=1):
        print(f"\n[{index}/{len(episodes)}] {episode.title}")
        payload = first_payload if episode.id == first.id else fetch_episode_data(episode.id)
        if selection.use_ffmpeg:
            catalog = (
                first_catalog
                if episode.id == first.id
                else download_catalog(payload, include_dash=True)
            )
            options = catalog.videos
        else:
            catalog = None
            options = media_options(payload)
        media = _quality_by_label(
            options,
            selection.video.label,
            selection.video.protocol,
        )
        if media is None:
            print("Sense cap format de vídeo disponible; s'omet aquest episodi.")
            continue
        if (
            media.label.casefold() != selection.video.label.casefold()
            or media.protocol != selection.video.protocol
        ):
            print(
                f"La qualitat {_media_description(selection.video)} no està disponible; "
                f"s'utilitza {_media_description(media)}."
            )
        episode_selection = DownloadSelection(
            video=media,
            audio=(
                _matching_tracks(catalog.audio, selection.audio)
                if catalog is not None
                else []
            ),
            subtitles=(
                _matching_tracks(catalog.subtitles, selection.subtitles)
                if catalog is not None
                else []
            ),
            use_ffmpeg=selection.use_ffmpeg,
        )
        destination = _selection_destination(
            _series_destination(episode), episode_selection
        )
        _download_one(episode_selection, destination)


def _print_examples(parser: argparse.ArgumentParser) -> None:
    parser.print_usage(sys.stderr)
    print("\nExemples:", file=sys.stderr)
    print(f'  python main.py "{EXAMPLE_EPISODE}"', file=sys.stderr)
    print(f'  python main.py "{EXAMPLE_SERIES}"', file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = _arguments()
    args = parser.parse_args(argv)

    try:
        _validate_url(args.url)
        episode_id = extract_episode_id(args.url)
        if episode_id:
            payload, catalog = _show_episode(args.url, episode_id)
            _download_episode(episode_id, payload, catalog)
        else:
            seasons = discover_series(args.url)
            _show_series(args.url, seasons)
            _download_series(seasons)
    except UnsupportedUrlError as error:
        print(f"Error: {error}", file=sys.stderr)
        _print_examples(parser)
        return 2
    except (ClientError, ValueError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nDescàrrega cancel·lada per l'usuari.", file=sys.stderr)
        return 130
    return 0

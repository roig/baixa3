from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
import re
import sys
from urllib.parse import urlparse

from .client import (
    ClientError,
    UnsupportedUrlError,
    best_media,
    discover_series,
    fetch_episode_data,
    media_options,
)
from .parser import Episode, Season, clean_text, extract_episode_id


EXAMPLE_SERIES = "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/"
EXAMPLE_EPISODE = (
    "https://www.3cat.cat/tv3/sx3/"
    "t1xc1-la-patrulla-fa-un-rescat-passat-per-aigua/video/6314970/"
)


def _arguments() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python main.py",
        description=(
            "Detecta si una URL de 3Cat és un episodi o una sèrie. "
            "De moment només en mostra la informació; no descarrega vídeos."
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


def _show_episode(url: str, episode_id: str) -> None:
    payload = fetch_episode_data(episode_id)
    options = media_options(payload)
    selected = best_media(payload)

    print("Tipus: episodi")
    print(f"URL: {url}")
    print(f"ID: {episode_id}")
    print(f"Formats MP4: {len(options)}")
    if selected:
        print(f"Millor qualitat detectada: {selected.label}")
        print(f"Fitxer de millor qualitat: {selected.url}")
    else:
        print("Millor qualitat detectada: cap MP4 directe")
    print("\nDades completes retornades per 3Cat:")
    _print_tree(payload, indent=2)


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
            _show_episode(args.url, episode_id)
        else:
            _show_series(args.url, discover_series(args.url))
    except UnsupportedUrlError as error:
        print(f"Error: {error}", file=sys.stderr)
        _print_examples(parser)
        return 2
    except (ClientError, ValueError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0

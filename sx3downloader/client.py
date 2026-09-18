from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
import shutil
import subprocess
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

from .parser import Season, extract_episodes, extract_seasons


MEDIA_API = "https://api-media.3cat.cat/pvideo/media.jsp"
USER_AGENT = "SX3Downloader/0.1 (personal use)"
DIRECT_MEDIA_EXTENSIONS = {".mp4", ".m4v", ".mov", ".mkv", ".webm"}


class ClientError(RuntimeError):
    pass


class UnsupportedUrlError(ClientError):
    pass


@dataclass
class Media:
    label: str
    url: str
    protocol: str = "MP4"
    stream_index: int | None = None
    width: int | None = None
    height: int | None = None
    bandwidth: int | None = None
    codec: str | None = None


@dataclass
class Track:
    kind: str
    label: str
    url: str
    language: str | None = None
    bandwidth: int | None = None
    codec: str | None = None
    stream_index: int | None = None


@dataclass
class DownloadCatalog:
    videos: list[Media]
    audio: list[Track]
    subtitles: list[Track]
    previews: list[Track]
    manifest_url: str | None = None


def _request(url: str):
    request = Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "ca,en;q=0.8",
        },
    )
    try:
        return urlopen(request, timeout=30)
    except (HTTPError, URLError) as error:
        reason = getattr(error, "reason", str(error))
        raise ClientError(f"No s'ha pogut accedir a {url}: {reason}") from error


def fetch_text(url: str) -> str:
    with _request(url) as response:
        return response.read().decode("utf-8", errors="replace")


def discover_series(series_url: str) -> list[Season]:
    seasons = extract_seasons(fetch_text(series_url), series_url)
    if not seasons:
        raise UnsupportedUrlError(
            "La URL no correspon a un episodi ni a una sèrie amb temporades reconeguda."
        )
    for season in seasons:
        season.episodes = extract_episodes(fetch_text(season.url), season.number, season.url)
    return seasons


def fetch_episode_data(episode_id: str) -> dict:
    query = urlencode(
        {
            "media": "video",
            "versio": "vast",
            "idint": episode_id,
            "profile": "pc_3cat",
            "format": "dm",
        }
    )
    with _request(f"{MEDIA_API}?{query}") as response:
        payload = json.load(response)
    if not isinstance(payload, dict):
        raise ClientError("L'API de 3Cat ha retornat una resposta inesperada.")
    return payload


def media_options(payload: dict) -> list[Media]:
    values = payload.get("media", {}).get("url", [])
    if isinstance(values, str):
        values = [{"label": "media", "file": values}]
    options: list[Media] = []
    for value in values if isinstance(values, list) else []:
        url = value.get("file") if isinstance(value, dict) else None
        extension = Path(urlsplit(url).path).suffix.lower() if isinstance(url, str) else ""
        if isinstance(url, str) and extension in DIRECT_MEDIA_EXTENSIONS:
            label = str(value.get("label", "MP4"))
            height = _height_from_label(label)
            options.append(
                Media(
                    label,
                    url,
                    protocol=extension.removeprefix(".").upper(),
                    height=height or None,
                )
            )
    return sorted(options, key=_quality_score, reverse=True)


def _height_from_label(label: str) -> int:
    progressive = re.search(r"(\d{3,4})p\b", label, flags=re.IGNORECASE)
    dimensions = re.search(r"\d{3,4}x(\d{3,4})", label, flags=re.IGNORECASE)
    if progressive:
        return int(progressive.group(1))
    if dimensions:
        return int(dimensions.group(1))
    return 0


def _quality_score(media: Media) -> tuple[int, int]:
    label = media.label.lower()
    bitrate = re.search(r"(\d+)\s*kbps", label)
    height = media.height or _height_from_label(label)
    rate = int(bitrate.group(1)) if bitrate else 0
    if media.bandwidth:
        rate = media.bandwidth // 1000
    return height, rate


def _media_entries(payload: dict) -> list[dict]:
    values = payload.get("media", {}).get("url", [])
    if isinstance(values, str):
        return [{"label": "media", "file": values}]
    return [value for value in values if isinstance(value, dict)] if isinstance(values, list) else []


def _dash_manifest_url(payload: dict) -> str | None:
    for value in _media_entries(payload):
        url = value.get("file")
        label = str(value.get("label", ""))
        if isinstance(url, str) and (
            url.lower().split("?", 1)[0].endswith(".mpd")
            or "dash" in label.casefold()
        ):
            return url
    return None


def _integer(value: object) -> int | None:
    try:
        return int(str(value)) if value is not None else None
    except (TypeError, ValueError):
        return None


def _stream_kind(adaptation: ET.Element, representation: ET.Element) -> str:
    content_type = str(
        representation.get("contentType")
        or adaptation.get("contentType")
        or representation.get("mimeType")
        or adaptation.get("mimeType")
        or ""
    ).casefold()
    if "video" in content_type or representation.get("height"):
        return "video"
    if "audio" in content_type or adaptation.get("lang"):
        return "audio"
    return "unknown"


def _parse_dash_manifest(manifest_url: str, xml: str) -> tuple[list[Media], list[Track]]:
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        raise ClientError(f"El manifest DASH no és XML vàlid: {error}") from error

    videos: list[Media] = []
    audio: list[Track] = []
    video_index = 0
    audio_index = 0
    for adaptation in root.findall(".//{*}AdaptationSet"):
        for representation in adaptation.findall("{*}Representation"):
            kind = _stream_kind(adaptation, representation)
            bandwidth = _integer(representation.get("bandwidth"))
            codec = representation.get("codecs") or adaptation.get("codecs")
            if kind == "video":
                width = _integer(representation.get("width"))
                height = _integer(representation.get("height"))
                label = f"{height}p" if height else str(representation.get("id") or "vídeo")
                videos.append(
                    Media(
                        label=label,
                        url=manifest_url,
                        protocol="DASH",
                        stream_index=video_index,
                        width=width,
                        height=height,
                        bandwidth=bandwidth,
                        codec=codec,
                    )
                )
                video_index += 1
            elif kind == "audio":
                language = representation.get("lang") or adaptation.get("lang")
                audio.append(
                    Track(
                        kind="audio",
                        label=str(representation.get("id") or "àudio DASH"),
                        url=manifest_url,
                        language=language,
                        bandwidth=bandwidth,
                        codec=codec,
                        stream_index=audio_index,
                    )
                )
                audio_index += 1
    return videos, audio


def _text_tracks(payload: object) -> tuple[list[Track], list[Track]]:
    subtitles: list[Track] = []
    previews: list[Track] = []
    seen: set[str] = set()

    def visit(
        value: object,
        label: str = "subtítols",
        language: str | None = None,
    ) -> None:
        if isinstance(value, dict):
            candidate_label = str(
                value.get("label")
                or value.get("text")
                or value.get("idioma")
                or value.get("lang")
                or label
            )
            candidate_language = str(
                value.get("iso") or value.get("language") or value.get("lang") or language or ""
            ) or None
            for key, child in value.items():
                visit(
                    child,
                    candidate_label if key.casefold() in {"file", "url"} else str(key),
                    candidate_language,
                )
        elif isinstance(value, list):
            for child in value:
                visit(child, label, language)
        elif isinstance(value, str):
            clean_url = value.lower().split("?", 1)[0]
            if clean_url.endswith((".vtt", ".srt", ".ttml", ".dfxp")) and value not in seen:
                seen.add(value)
                kind = "preview" if "sprite" in label.casefold() or "/sprites/" in clean_url else "subtitles"
                track = Track(kind, label, value, language=language)
                (previews if kind == "preview" else subtitles).append(track)

    visit(payload)
    return subtitles, previews


def download_catalog(payload: dict, *, include_dash: bool = True) -> DownloadCatalog:
    videos = media_options(payload)
    audio: list[Track] = []
    manifest_url = _dash_manifest_url(payload)
    if manifest_url and include_dash:
        dash_videos, audio = _parse_dash_manifest(manifest_url, fetch_text(manifest_url))
        videos.extend(dash_videos)
    videos.sort(key=_quality_score, reverse=True)
    subtitles, previews = _text_tracks(payload)
    return DownloadCatalog(videos, audio, subtitles, previews, manifest_url)


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def best_media(payload: dict) -> Media | None:
    options = media_options(payload)
    return max(options, key=_quality_score, default=None)


def resolve_media(episode_id: str) -> Media | None:
    return best_media(fetch_episode_data(episode_id))


def download_media(
    media: Media,
    destination: Path,
    progress: Callable[[int, int], None] | None = None,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(f"{destination.suffix}.part")
    try:
        with _request(media.url) as response, temporary.open("wb") as output:
            total = int(response.headers.get("Content-Length", "0") or 0)
            received = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                received += len(chunk)
                if progress:
                    progress(received, total)
        temporary.replace(destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _ffmpeg_language(language: str | None) -> str | None:
    if not language:
        return None
    return {
        "ca": "cat",
        "es": "spa",
        "en": "eng",
        "fr": "fra",
        "de": "deu",
        "it": "ita",
    }.get(language.casefold(), language)


def download_with_ffmpeg(
    media: Media,
    destination: Path,
    audio_tracks: list[Track],
    subtitle_tracks: list[Track],
) -> None:
    if media.protocol == "DASH" and media.stream_index is None:
        raise ClientError("El format seleccionat no és una representació DASH vàlida.")
    executable = shutil.which("ffmpeg")
    if not executable:
        raise ClientError(
            "Per combinar vídeo, àudios i subtítols cal tenir FFmpeg instal·lat "
            "i disponible al PATH."
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(f"{destination.suffix}.part")
    input_urls: list[str] = []

    def input_index(url: str) -> int:
        if url not in input_urls:
            input_urls.append(url)
        return input_urls.index(url)

    video_input = input_index(media.url)
    audio_inputs = [(input_index(track.url), track) for track in audio_tracks]
    subtitle_inputs = [(input_index(track.url), track) for track in subtitle_tracks]

    command = [
        executable,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
    ]
    for url in input_urls:
        command.extend(["-i", url])

    video_stream = media.stream_index if media.protocol == "DASH" else 0
    command.extend(["-map", f"{video_input}:v:{video_stream}"])
    for source_index, track in audio_inputs:
        command.extend(["-map", f"{source_index}:a:{track.stream_index or 0}"])
    for source_index, _track in subtitle_inputs:
        command.extend(["-map", f"{source_index}:s:0"])

    command.extend([
        "-c:v",
        "copy",
    ])
    if audio_tracks:
        command.extend(["-c:a", "copy"])
    if subtitle_tracks:
        command.extend(["-c:s", "mov_text"])

    for index, track in enumerate(audio_tracks):
        language = _ffmpeg_language(track.language)
        if language:
            command.extend([f"-metadata:s:a:{index}", f"language={language}"])
        command.extend([f"-metadata:s:a:{index}", f"title={track.label}"])
    for index, track in enumerate(subtitle_tracks):
        language = _ffmpeg_language(track.language)
        if language:
            command.extend([f"-metadata:s:s:{index}", f"language={language}"])
        command.extend([f"-metadata:s:s:{index}", f"title={track.label}"])

    command.extend(
        ["-movflags", "+faststart", "-f", "mp4", str(temporary)]
    )
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode:
            detail = result.stderr.strip().splitlines()
            message = detail[-1] if detail else f"codi de sortida {result.returncode}"
            raise ClientError(f"FFmpeg no ha pogut descarregar el vídeo: {message}")
        temporary.replace(destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def download_dash(media: Media, destination: Path) -> None:
    if media.protocol != "DASH" or media.stream_index is None:
        raise ClientError("El format seleccionat no és una representació DASH vàlida.")
    audio = Track(
        kind="audio",
        label="àudio principal",
        url=media.url,
        stream_index=0,
    )
    download_with_ffmpeg(media, destination, [audio], [])

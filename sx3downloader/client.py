from __future__ import annotations

from dataclasses import dataclass
import json
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .parser import Season, extract_episodes, extract_seasons


MEDIA_API = "https://api-media.3cat.cat/pvideo/media.jsp"
USER_AGENT = "SX3Downloader/0.1 (personal use)"


class ClientError(RuntimeError):
    pass


class UnsupportedUrlError(ClientError):
    pass


@dataclass
class Media:
    label: str
    url: str


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
        if isinstance(url, str) and url.lower().split("?", 1)[0].endswith(".mp4"):
            options.append(Media(str(value.get("label", "MP4")), url))
    return options


def _quality_score(media: Media) -> tuple[int, int]:
    label = media.label.lower()
    progressive = re.search(r"(\d{3,4})p\b", label)
    dimensions = re.search(r"\d{3,4}x(\d{3,4})", label)
    bitrate = re.search(r"(\d+)\s*kbps", label)
    height = int(progressive.group(1)) if progressive else 0
    if not height and dimensions:
        height = int(dimensions.group(1))
    rate = int(bitrate.group(1)) if bitrate else 0
    return height, rate


def best_media(payload: dict) -> Media | None:
    options = media_options(payload)
    return max(options, key=_quality_score, default=None)


def resolve_media(episode_id: str) -> Media | None:
    return best_media(fetch_episode_data(episode_id))

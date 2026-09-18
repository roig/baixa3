from __future__ import annotations

from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
import re
from urllib.parse import urljoin, urlparse


DEFAULT_URL = "https://www.3cat.cat/tv3/sx3/la-patrulla-peluda/"
SEASON_PATH = re.compile(r"/videos/temporada-(\d+)/?$", re.IGNORECASE)
VIDEO_PATH = re.compile(r"/video/(\d+)/?$", re.IGNORECASE)
EPISODE_CODE = re.compile(r"\bT(\d+)xC(\d+)\b", re.IGNORECASE)


@dataclass
class Link:
    href: str
    attrs: dict[str, str]
    text: str
    duration: str | None = None
    thumbnail: str | None = None


@dataclass
class Episode:
    id: str
    season: int
    number: int | None
    title: str
    url: str
    duration: str | None = None
    thumbnail: str | None = None


@dataclass
class Season:
    number: int
    url: str
    episodes: list[Episode] = field(default_factory=list)


def clean_text(value: str) -> str:
    return re.sub(r"\s+", " ", unescape(value)).strip()


def clean_title(value: str) -> str:
    return re.sub(r"^vídeo\s*:\s*", "", clean_text(value), flags=re.IGNORECASE)


class _PageParser(HTMLParser):
    """Parser petit per als enllaços de temporades i vídeos de 3Cat."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[Link] = []
        self.options: list[Link] = []
        self._link: dict[str, object] | None = None
        self._option: dict[str, object] | None = None

    @staticmethod
    def _attrs(raw_attrs: list[tuple[str, str | None]]) -> dict[str, str]:
        return {key.lower(): value or "" for key, value in raw_attrs}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        parsed_attrs = self._attrs(attrs)
        if tag.lower() == "a":
            self._link = {
                "attrs": parsed_attrs,
                "text": [],
                "duration": None,
                "thumbnail": None,
            }
        elif tag.lower() == "option":
            self._option = {"attrs": parsed_attrs, "text": []}
        elif self._link is not None and tag.lower() == "img":
            alt = parsed_attrs.get("alt")
            if alt:
                self._link["text"].append(alt)
            self._link["thumbnail"] = (
                parsed_attrs.get("src")
                or parsed_attrs.get("data-src")
                or self._link["thumbnail"]
            )
        elif self._link is not None and tag.lower() == "time":
            self._link["duration"] = (
                parsed_attrs.get("datetime") or self._link["duration"]
            )

    def handle_data(self, data: str) -> None:
        if self._link is not None:
            self._link["text"].append(data)
        if self._option is not None:
            self._option["text"].append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "a" and self._link is not None:
            attrs = self._link["attrs"]
            href = attrs.get("href", "")
            if href:
                self.links.append(
                    Link(
                        href,
                        attrs,
                        "".join(self._link["text"]),
                        self._link["duration"],
                        self._link["thumbnail"],
                    )
                )
            self._link = None
        elif tag.lower() == "option" and self._option is not None:
            attrs = self._option["attrs"]
            value = attrs.get("value", "")
            if value:
                self.options.append(Link(value, attrs, "".join(self._option["text"])))
            self._option = None


def _parse(html: str) -> _PageParser:
    parser = _PageParser()
    parser.feed(html)
    parser.close()
    return parser


def _absolute(href: str, base_url: str) -> str | None:
    try:
        return urljoin(base_url, href)
    except ValueError:
        return None


def extract_seasons(html: str, base_url: str = DEFAULT_URL) -> list[Season]:
    seasons: dict[int, Season] = {}
    parsed = _parse(html)
    for item in [*parsed.links, *parsed.options]:
        absolute = _absolute(item.href, base_url)
        if not absolute:
            continue
        match = SEASON_PATH.search(urlparse(absolute).path)
        if match:
            number = int(match.group(1))
            seasons.setdefault(number, Season(number=number, url=absolute))
    return sorted(seasons.values(), key=lambda season: season.number)


def extract_episode_id(url: str) -> str | None:
    try:
        match = VIDEO_PATH.search(urlparse(url).path)
    except ValueError:
        return None
    return match.group(1) if match else None


def extract_episodes(html: str, season_number: int, base_url: str) -> list[Episode]:
    episodes: dict[str, Episode] = {}
    for item in _parse(html).links:
        absolute = _absolute(item.href, base_url)
        if not absolute:
            continue
        video_match = VIDEO_PATH.search(urlparse(absolute).path)
        if not video_match:
            continue

        title = clean_title(
            item.attrs.get("title")
            or item.attrs.get("aria-label")
            or item.text
            or item.attrs.get("alt")
            or f"Vídeo {video_match.group(1)}"
        )
        code_match = EPISODE_CODE.search(title)
        number = int(code_match.group(2)) if code_match else None
        if code_match and int(code_match.group(1)) != season_number:
            continue

        episode_id = video_match.group(1)
        candidate = Episode(
            episode_id,
            season_number,
            number,
            title,
            absolute,
            item.duration,
            _absolute(item.thumbnail, base_url) if item.thumbnail else None,
        )
        previous = episodes.get(episode_id)
        if previous is None or len(candidate.title) > len(previous.title):
            episodes[episode_id] = candidate

    return sorted(
        episodes.values(),
        key=lambda episode: (episode.number is None, episode.number or 0, episode.title),
    )

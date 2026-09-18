import tempfile
import unittest
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from sx3downloader.cli import (
    _choose_download,
    _choose_quality,
    _episode_destination,
    _quality_by_label,
    _series_destination,
)
from sx3downloader.client import (
    ClientError,
    DownloadCatalog,
    Media,
    Track,
    download_dash,
    download_media,
    download_with_ffmpeg,
)
from sx3downloader.parser import Episode


class _FakeResponse:
    def __init__(self, content: bytes):
        self._content = content
        self._position = 0
        self.headers = {"Content-Length": str(len(content))}

    def read(self, size: int = -1) -> bytes:
        if self._position >= len(self._content):
            return b""
        end = len(self._content) if size < 0 else self._position + size
        chunk = self._content[self._position:end]
        self._position += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class CliTests(unittest.TestCase):
    def test_quality_prompt_uses_selected_option(self):
        options = [
            Media("1080p", "https://example.test/1080.mp4"),
            Media("720p", "https://example.test/720.mp4"),
        ]
        with patch("builtins.input", return_value="2"):
            self.assertEqual(_choose_quality(options).label, "720p")

    def test_without_ffmpeg_only_complete_files_are_shown(self):
        catalog = DownloadCatalog(
            videos=[
                Media(
                    "1080p",
                    "https://example.test/stream.mpd",
                    protocol="DASH",
                    stream_index=0,
                ),
                Media("720p", "https://example.test/video.mp4"),
            ],
            audio=[Track("audio", "Català", "https://example.test/stream.mpd")],
            subtitles=[Track("subtitles", "Català", "https://example.test/ca.vtt")],
            previews=[],
        )
        with (
            patch("sx3downloader.cli.ffmpeg_available", return_value=False),
            patch("builtins.input", return_value=""),
            patch("sys.stdout", new_callable=StringIO) as output,
        ):
            selection = _choose_download(catalog)

        self.assertEqual(selection.video.protocol, "MP4")
        self.assertFalse(selection.use_ffmpeg)
        self.assertNotIn("1080p", output.getvalue())
        self.assertNotIn("Available audios", output.getvalue())

    def test_with_ffmpeg_all_audio_and_subtitles_are_selected_by_default(self):
        catalog = DownloadCatalog(
            videos=[Media("1080p", "https://example.test/stream.mpd", "DASH", 0)],
            audio=[Track("audio", "Català", "https://example.test/stream.mpd", "ca", stream_index=0)],
            subtitles=[Track("subtitles", "Català", "https://example.test/ca.vtt", "ca")],
            previews=[],
        )
        with (
            patch("sx3downloader.cli.ffmpeg_available", return_value=True),
            patch("builtins.input", side_effect=["", "", ""]),
        ):
            selection = _choose_download(catalog)

        self.assertTrue(selection.use_ffmpeg)
        self.assertEqual(len(selection.audio), 1)
        self.assertEqual(len(selection.subtitles), 1)

    def test_series_quality_falls_back_to_best_available(self):
        options = [Media("720p", "https://example.test/720.mp4")]
        self.assertEqual(_quality_by_label(options, "1080p").label, "720p")

    def test_episode_destination_uses_season_and_chapter(self):
        payload = {
            "informacio": {
                "titol": "T1xC2 - Prova",
                "capitol": 2,
                "temporada": {"idName": "PUTEMP_1"},
            }
        }
        self.assertEqual(
            _episode_destination(payload, "123"),
            Path("videos") / "Temporada 1" / "S01E02 - T1xC2 - Prova.mp4",
        )

    def test_series_destination_uses_season_and_chapter(self):
        episode = Episode("123", 2, 3, "Títol", "https://example.test/video/123/")
        self.assertEqual(
            _series_destination(episode),
            Path("videos") / "Temporada 2" / "S02E03 - Títol.mp4",
        )

    def test_download_writes_atomically(self):
        media = Media("720p", "https://example.test/video.mp4")
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "video.mp4"
            with patch(
                "sx3downloader.client._request",
                return_value=_FakeResponse(b"video-data"),
            ):
                download_media(media, destination)
            self.assertEqual(destination.read_bytes(), b"video-data")
            self.assertFalse(destination.with_suffix(".mp4.part").exists())

    def test_dash_download_selects_video_and_first_audio(self):
        media = Media(
            "1080p",
            "https://example.test/stream.mpd",
            protocol="DASH",
            stream_index=0,
        )

        def fake_run(command, **kwargs):
            Path(command[-1]).write_bytes(b"muxed-video")
            self.assertIn("0:v:0", command)
            self.assertIn("0:a:0", command)
            return SimpleNamespace(returncode=0, stderr="")

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "video.mp4"
            with (
                patch("sx3downloader.client.shutil.which", return_value="ffmpeg"),
                patch("sx3downloader.client.subprocess.run", side_effect=fake_run),
            ):
                download_dash(media, destination)
            self.assertEqual(destination.read_bytes(), b"muxed-video")
            self.assertFalse(destination.with_suffix(".mp4.part").exists())

    def test_dash_download_fails_cleanly_without_ffmpeg(self):
        media = Media(
            "1080p",
            "https://example.test/stream.mpd",
            protocol="DASH",
            stream_index=0,
        )
        with patch("sx3downloader.client.shutil.which", return_value=None):
            with self.assertRaisesRegex(ClientError, "FFmpeg"):
                download_dash(media, Path("video.mp4"))

    def test_ffmpeg_combines_selected_video_audio_and_subtitles(self):
        media = Media("1080p", "https://example.test/stream.mpd", "DASH", 0)
        audio = [
            Track(
                "audio",
                "Català",
                "https://example.test/stream.mpd",
                "ca",
                stream_index=0,
            )
        ]
        subtitles = [
            Track("subtitles", "Català", "https://example.test/ca.vtt", "ca")
        ]

        def fake_run(command, **kwargs):
            Path(command[-1]).write_bytes(b"muxed-video")
            self.assertIn("0:v:0", command)
            self.assertIn("0:a:0", command)
            self.assertIn("1:s:0", command)
            self.assertIn("mov_text", command)
            self.assertIn("language=cat", command)
            return SimpleNamespace(returncode=0, stderr="")

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "video.mp4"
            with (
                patch("sx3downloader.client.shutil.which", return_value="ffmpeg"),
                patch("sx3downloader.client.subprocess.run", side_effect=fake_run),
            ):
                download_with_ffmpeg(media, destination, audio, subtitles)
            self.assertEqual(destination.read_bytes(), b"muxed-video")


if __name__ == "__main__":
    unittest.main()

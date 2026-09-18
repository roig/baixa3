import unittest
from unittest.mock import patch

from sx3downloader.client import best_media, download_catalog, media_options


DASH_MANIFEST = """\
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="1080" bandwidth="4000000" width="1920" height="1080" codecs="avc1.640028" />
      <Representation id="720" bandwidth="2000000" width="1280" height="720" codecs="avc1.4D401F" />
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" lang="ca">
      <Representation id="audio" bandwidth="128000" codecs="mp4a.40.2" />
    </AdaptationSet>
  </Period>
</MPD>
"""


class ClientTests(unittest.TestCase):
    def test_selects_highest_mp4_quality(self):
        payload = {
            "media": {
                "url": [
                    {"label": "DASH", "file": "https://example.test/video.mpd"},
                    {"label": "720p", "file": "https://example.test/video-720.mp4"},
                    {"label": "1080p", "file": "https://example.test/video-1080.mp4"},
                ]
            }
        }
        self.assertEqual(len(media_options(payload)), 2)
        self.assertEqual(best_media(payload).label, "1080p")

    def test_catalog_lists_dash_audio_subtitles_and_previews(self):
        payload = {
            "media": {
                "url": [
                    {"label": "DASH", "file": "https://example.test/stream.mpd"},
                    {"label": "720p", "file": "https://example.test/video.mp4"},
                ]
            },
            "subtitols": [
                {"text": "Català", "iso": "ca", "url": "https://example.test/ca.vtt"}
            ],
            "sprites": {"file": "https://example.test/sprites/sprite.vtt"},
        }
        with patch("sx3downloader.client.fetch_text", return_value=DASH_MANIFEST):
            catalog = download_catalog(payload)

        self.assertEqual(
            [(item.label, item.protocol) for item in catalog.videos],
            [("1080p", "DASH"), ("720p", "DASH"), ("720p", "MP4")],
        )
        self.assertEqual(catalog.audio[0].language, "ca")
        self.assertEqual(catalog.audio[0].bandwidth, 128000)
        self.assertEqual(catalog.subtitles[0].label, "Català")
        self.assertEqual(catalog.subtitles[0].language, "ca")
        self.assertEqual(len(catalog.previews), 1)

    def test_catalog_skips_dash_manifest_when_disabled(self):
        payload = {
            "media": {
                "url": [
                    {"label": "DASH", "file": "https://example.test/stream.mpd"},
                    {"label": "720p", "file": "https://example.test/video.mp4"},
                ]
            }
        }
        with patch("sx3downloader.client.fetch_text") as fetch_text:
            catalog = download_catalog(payload, include_dash=False)

        fetch_text.assert_not_called()
        self.assertEqual([(video.label, video.protocol) for video in catalog.videos], [("720p", "MP4")])
        self.assertEqual(catalog.audio, [])


if __name__ == "__main__":
    unittest.main()

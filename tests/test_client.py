import unittest

from sx3downloader.client import best_media, media_options


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


if __name__ == "__main__":
    unittest.main()

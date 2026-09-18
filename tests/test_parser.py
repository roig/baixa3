import unittest

from sx3downloader.parser import extract_episode_id, extract_episodes, extract_seasons


class ParserTests(unittest.TestCase):
    def test_extracts_seasons_from_links_and_options(self):
        html = """
        <a href="/tv3/sx3/la-patrulla-peluda/videos/temporada-2/">Temporada 2</a>
        <select><option value="/tv3/sx3/la-patrulla-peluda/videos/temporada-1/">Temporada 1</option></select>
        """
        self.assertEqual([item.number for item in extract_seasons(html)], [1, 2])

    def test_extracts_episodes_and_deduplicates_links(self):
        html = """
        <a title="T1xC2 - Segon episodi" href="/tv3/sx3/segon/video/123/">
          <time datetime="PT00H11M40S">00:11:40</time>
          <img alt="Segon" src="/imatges/123.jpg">
        </a>
        <a title="Vídeo: T1xC2 - Segon episodi" href="/tv3/sx3/segon/video/123/">Segon</a>
        <a title="T2xC1 - Altra temporada" href="/tv3/sx3/altre/video/999/"></a>
        """
        episodes = extract_episodes(html, 1, "https://www.3cat.cat/")
        self.assertEqual(len(episodes), 1)
        self.assertEqual(episodes[0].id, "123")
        self.assertEqual(episodes[0].number, 2)
        self.assertEqual(episodes[0].title, "T1xC2 - Segon episodi")
        self.assertEqual(episodes[0].duration, "PT00H11M40S")
        self.assertEqual(episodes[0].thumbnail, "https://www.3cat.cat/imatges/123.jpg")

    def test_detects_episode_id_from_url(self):
        url = "https://www.3cat.cat/tv3/sx3/episodi/video/6314970/"
        self.assertEqual(extract_episode_id(url), "6314970")
        self.assertIsNone(extract_episode_id("https://www.3cat.cat/tv3/sx3/serie/"))


if __name__ == "__main__":
    unittest.main()

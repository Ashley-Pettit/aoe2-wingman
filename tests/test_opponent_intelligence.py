import unittest
from opponent_intelligence import predict_opening, format_brief


class PredictionsTest(unittest.TestCase):
    def test_minimum_sample(self):
        self.assertIsNone(predict_opening([{"opening": "Scouts"}]))

    def test_frequency_and_medians(self):
        games = [
            {"opening": "Scouts", "civ": "Franks", "map": "Arabia", "feudal_seconds": 600},
            {"opening": "Scouts", "civ": "Franks", "map": "Arabia", "feudal_seconds": 620},
            {"opening": "Archers", "civ": "Franks", "map": "Arabia", "feudal_seconds": 640},
        ]
        result = predict_opening(games, civ="Franks", map_name="Arabia")
        self.assertEqual((result.opening, result.observed, result.matches),
                         ("Scouts", 2, 3))
        self.assertEqual(result.feudal_seconds, 620)
        self.assertIn("2/3", format_brief(result))

    def test_ignores_unlabelled_and_boolean_time(self):
        result = predict_opening([
            {"opening": "Scouts", "feudal_seconds": True},
            {"opening": "Scouts", "feudal_seconds": 500},
            {"opening": "Archers"},
            {"opening": ""},
        ])
        self.assertEqual(result.feudal_seconds, 500)


if __name__ == "__main__":
    unittest.main()

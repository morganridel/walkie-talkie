"""Small configuration tests that do not import MLX or warm the model."""
import ast
import os
from pathlib import Path
import unittest


SOURCE = Path(__file__).with_name("whisper_helper.py").read_text()
TREE = ast.parse(SOURCE)


def _config_namespace():
    nodes = [node for node in TREE.body
             if isinstance(node, ast.FunctionDef) and node.name == "parse_languages"]
    module = ast.Module(body=nodes, type_ignores=[])
    namespace = {}
    exec(compile(module, str(Path(__file__).with_name("whisper_helper.py")), "exec"),
         {"os": os}, namespace)
    return namespace


class WhisperLanguageConfigTests(unittest.TestCase):
    def test_empty_setting_means_whisper_detects_any_language(self):
        namespace = _config_namespace()
        self.assertEqual(namespace["parse_languages"](""), ())

    def test_explicit_language_allowlist_is_still_available(self):
        namespace = _config_namespace()
        self.assertEqual(namespace["parse_languages"]("en, fr, ,de"), ("en", "fr", "de"))

    def test_default_does_not_embed_a_language_preset(self):
        assignment = next(node for node in TREE.body
                          if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == "LANGUAGES"
                                  for target in node.targets))
        self.assertTrue(any(isinstance(node, ast.Constant) and node.value == ""
                            for node in ast.walk(assignment.value)))
        self.assertTrue(any(isinstance(node, ast.Name) and node.id == "parse_languages"
                            for node in ast.walk(assignment.value)))


if __name__ == "__main__":
    unittest.main()

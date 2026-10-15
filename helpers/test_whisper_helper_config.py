"""Language configuration and per-request decoding tests; no MLX import/warm-up."""
import ast
import contextlib
import json
import math
import os
from pathlib import Path
import time
import unittest


SOURCE_PATH = Path(__file__).with_name("whisper_helper.py")
TREE = ast.parse(SOURCE_PATH.read_text())


def _functions(*names, **globals_):
    wanted = set(names)
    nodes = [node for node in TREE.body
             if isinstance(node, ast.FunctionDef) and node.name in wanted]
    if {node.name for node in nodes} != wanted:
        raise AssertionError("missing function in helper source")
    namespace = dict(globals_)
    module = ast.Module(body=nodes, type_ignores=[])
    exec(compile(module, str(SOURCE_PATH), "exec"), namespace)
    return namespace


def _decode_namespace(pick_language=None):
    calls = []

    def fake_decode(samples, **options):
        calls.append(options)
        return {
            "text": "synthetic result",
            "language": options["language"] or "en",
            "segments": [{"compression_ratio": 0.2}],
        }

    class FakeMLX:
        transcribe = staticmethod(fake_decode)

    if pick_language is None:
        pick_language = lambda _samples: None
    namespace = _functions(
        "validate_language_hint", "resolve_language", "decode_samples", "transcribe",
        WHISPER_LANGUAGE_CODES=frozenset({"en", "fr", "ro", "de"}),
        pick_language=pick_language,
        quiet=contextlib.nullcontext,
        mlx_whisper=FakeMLX,
        MODEL="test-model",
        LOOP_CEILING=2.4,
        VOCABULARY="english vocab",
        VOCABULARY_RO="romanian vocab",
        WORDS=False,
        A=type("Audio", (), {"SAMPLE_RATE": 16000,
                              "load_audio": staticmethod(lambda _path: [0.0])}),
        _worst_ratio=lambda _res: 0.2,
        cut_loops=lambda _res: None,
    )
    return namespace, calls


class WhisperLanguageConfigTests(unittest.TestCase):
    def test_empty_setting_means_whisper_detects_any_language(self):
        namespace = _functions("parse_languages", os=os)
        self.assertEqual(namespace["parse_languages"](""), ())

    def test_explicit_language_allowlist_is_still_available(self):
        namespace = _functions("parse_languages", os=os)
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

    def test_explicit_supported_code_is_passed_to_mlx_transcribe_task(self):
        namespace, calls = _decode_namespace()
        res = namespace["transcribe"]("synthetic.wav", samples=[0.0] * 16000,
                                       language_hint="EN")
        self.assertEqual(res["text"], "synthetic result")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["language"], "en")
        self.assertEqual(calls[0]["task"], "transcribe")

    def test_missing_null_and_auto_keep_existing_language_detection(self):
        for hint in (None, "auto"):
            namespace, calls = _decode_namespace(pick_language=lambda _samples: None)
            namespace["transcribe"]("synthetic.wav", samples=[0.0], language_hint=hint)
            self.assertIsNone(calls[0]["language"])
            self.assertEqual(calls[0]["task"], "transcribe")

    def test_auto_still_uses_existing_optional_allowlist(self):
        namespace, calls = _decode_namespace(pick_language=lambda _samples: "fr")
        namespace["transcribe"]("synthetic.wav", samples=[0.0], language_hint="auto")
        self.assertEqual(calls[0]["language"], "fr")

    def test_explicit_hint_overrides_allowlist_for_this_request(self):
        namespace, calls = _decode_namespace(pick_language=lambda _samples: "fr")
        namespace["transcribe"]("synthetic.wav", samples=[0.0], language_hint="en")
        self.assertEqual(calls[0]["language"], "en")

    def test_invalid_code_is_a_clean_per_request_error_and_next_request_works(self):
        calls = []

        def fake_process(req, language_hint):
            calls.append((req, language_hint))
            return {"ok": True, "language": language_hint}

        namespace = _functions(
            "validate_language_hint", "handle_line",
            WHISPER_LANGUAGE_CODES=frozenset({"en", "fr", "ro"}),
            process_request=fake_process,
            json=json,
        )
        bad = namespace["handle_line"]('{"wav":"bad.wav","language":"xx"}')
        good = namespace["handle_line"]('{"wav":"ok.wav","language":"en"}')
        self.assertFalse(bad["ok"])
        self.assertIn("supported Whisper language code", bad["error"])
        self.assertTrue(good["ok"])
        self.assertEqual(good["language"], "en")
        self.assertEqual(len(calls), 1)

    def test_both_wav_and_caption_pcm_requests_forward_the_hint(self):
        calls = []

        def fake_transcribe(path, *, words, samples, language_hint):
            calls.append((path, language_hint, samples))
            return {"text": "synthetic", "language": language_hint, "segments": []}

        namespace = _functions(
            "process_request",
            os=os,
            time=time,
            math=math,
            WORDS=False,
            load_pcm=lambda _path: [1, 2, 3],
            transcribe=fake_transcribe,
            coverage=lambda _res: {},
            timed_words=lambda *_args: [],
            timed_segments=lambda _res: [],
            memory_stats=lambda: {},
        )
        # Existing local scratch paths stand in for a WAV and raw caption PCM.
        namespace["process_request"]({"wav": str(SOURCE_PATH)}, "en")
        namespace["process_request"]({"pcm": str(SOURCE_PATH), "segments": True}, "fr")
        self.assertEqual([row[1] for row in calls], ["en", "fr"])
        self.assertIsNone(calls[0][2])
        self.assertEqual(calls[1][2], [1, 2, 3])


if __name__ == "__main__":
    unittest.main()

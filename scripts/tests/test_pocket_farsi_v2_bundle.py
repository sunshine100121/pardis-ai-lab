"""Offline package-builder regression tests, using dummy weights only."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import wave
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "pocket_packer", ROOT / "prepare_pocket_farsi_v2_bundle.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class TestPocketBundle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.onnx = self.root / "onnx"
        self.onnx.mkdir()
        for name in MODULE.CORE:
            file = self.onnx / name
            if name == "manifest.json":
                file.write_text(json.dumps({"constants": {
                    "sample_rate": 24000, "ldim": 32, "dim": 1024,
                    "layers": 6, "cache_capacity": 256}}))
            else:
                file.write_bytes(b"dummy ONNX/NPZ only")
        self.tokenizer = self.root / "tokenizer_ph.model"
        self.tokenizer.write_bytes(b"protobuf placeholder" * 20)
        self.voice = self.root / "voice_reference.wav"
        with wave.open(str(self.voice), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(24000)
            wav.writeframes(b"\0\0" * 24000)
        self.output = self.root / "pocket-test.zip"

    def test_valid_complete_pack(self):
        packed = MODULE.build(self.onnx, self.tokenizer, self.voice, self.output)
        self.assertTrue(packed.is_file())
        with zipfile.ZipFile(packed) as archive:
            self.assertEqual(set(archive.namelist()), set(MODULE.CORE + MODULE.EXTRAS))
            self.assertIsNone(archive.testzip())

    def test_missing_external_onnx_weights_rejected(self):
        (self.onnx / "flow_lm_step.onnx.data").unlink()
        with self.assertRaises(ValueError):
            MODULE.build(self.onnx, self.tokenizer, self.voice, self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_preserved(self):
        self.output.write_bytes(b"owner document")
        with self.assertRaises(FileExistsError):
            MODULE.build(self.onnx, self.tokenizer, self.voice, self.output)
        self.assertEqual(self.output.read_bytes(), b"owner document")

    def test_voice_wrong_rate_fails_without_zip(self):
        with wave.open(str(self.voice), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\0\0" * 16000)
        with self.assertRaises(ValueError):
            MODULE.build(self.onnx, self.tokenizer, self.voice, self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

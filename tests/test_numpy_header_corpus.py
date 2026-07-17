import io
import json
import struct
import unittest
from pathlib import Path

import numpy as np


CORPUS_PATH = Path(__file__).parent / "fixtures" / "npy_header_corpus.json"


def corpus_bytes(case):
    header = case["header"].encode("ascii")
    target = case["header_length"]
    if len(header) + 1 > target:
        raise ValueError("corpus header does not fit target length")
    header += b" " * (target - len(header) - 1) + b"\n"
    version = case["version"]
    if version == 1:
        prefix = b"\x93NUMPY\x01\x00" + struct.pack("<H", len(header))
    elif version == 2:
        prefix = b"\x93NUMPY\x02\x00" + struct.pack("<I", len(header))
    else:
        raise ValueError(f"unsupported corpus version: {version}")
    payload = b"\0" * (case["payload_rows"] * 9216 * 4)
    return prefix + header + payload


class NumpyHeaderCorpusTests(unittest.TestCase):
    def test_pinned_numpy_matches_shared_header_corpus(self):
        self.assertEqual(np.__version__, "1.26.4")
        cases = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
        for case in cases:
            with self.subTest(case=case["name"]):
                accepted = True
                try:
                    value = np.load(
                        io.BytesIO(corpus_bytes(case)),
                        allow_pickle=False,
                    )
                    accepted = (
                        value.dtype == np.dtype("<f4")
                        and value.shape == (case["payload_rows"], 9216)
                    )
                except (EOFError, OSError, TypeError, ValueError):
                    accepted = False
                self.assertEqual(accepted, case["expected"])


if __name__ == "__main__":
    unittest.main()

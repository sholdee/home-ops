import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


SCRIPT_PATH = Path(__file__).with_name("extract_image_info.py")
SPEC = importlib.util.spec_from_file_location("extract_image_info", SCRIPT_PATH)
extract_image_info = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(extract_image_info)


def extract_line(line):
    output = io.StringIO()
    with redirect_stdout(output):
        return extract_image_info.extract_image_from_helm_diff_line(line)


class HelmDiffImageExtractionTest(unittest.TestCase):
    def test_extracts_added_image_key_lines(self):
        self.assertEqual(
            extract_line("+        image: docker.io/envoyproxy/gateway:v1.8.0"),
            ("docker.io/envoyproxy/gateway", "v1.8.0", ""),
        )

    def test_extracts_quoted_added_image_key_lines(self):
        self.assertEqual(
            extract_line('+        image: "ghcr.io/example/app:v1.2.3"'),
            ("ghcr.io/example/app", "v1.2.3", ""),
        )

    def test_ignores_crd_schema_description_image_references(self):
        self.assertIsNone(
            extract_line(
                "+                                URL can be in the format of `registry/image:tag` or `registry/image@sha256:digest`."
            )
        )

    def test_extracts_non_image_key_config_values(self):
        self.assertEqual(
            extract_line("+        value: ghcr.io/example/app:v1.2.3"),
            ("ghcr.io/example/app", "v1.2.3", ""),
        )

    def test_ignores_crd_schema_default_image_references(self):
        self.assertIsNone(
            extract_line("+                                default: registry/image:tag")
        )

    def test_helm_diff_file_extraction_ignores_crd_schema_references(self):
        diff_text = """
+        image: docker.io/envoyproxy/gateway:v1.8.0
+                                URL can be in the format of `registry/image:tag` or `registry/image@sha256:digest`.
+                                default: registry/image:tag
        """
        previous_path = os.environ.get("DIFF_TXT_PATH")
        diff_file_path = None
        try:
            with tempfile.NamedTemporaryFile("w", delete=False) as diff_file:
                diff_file.write(diff_text)
                diff_file_path = diff_file.name

            os.environ["DIFF_TXT_PATH"] = diff_file_path
            output = io.StringIO()
            with redirect_stdout(output):
                images = extract_image_info.extract_images_from_helm_diff()
            self.assertEqual(
                set(images),
                {("docker.io/envoyproxy/gateway", "v1.8.0", "")},
            )
        finally:
            if previous_path is None:
                os.environ.pop("DIFF_TXT_PATH", None)
            else:
                os.environ["DIFF_TXT_PATH"] = previous_path
            if diff_file_path:
                Path(diff_file_path).unlink(missing_ok=True)


class PrDiffImageExtractionTest(unittest.TestCase):
    def test_extracts_pr_diff_images_with_stdlib_http_client(self):
        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, traceback):
                return False

            def read(self):
                return json.dumps(
                    [
                        {
                            "filename": "apps/example/manifests/deployment.yaml",
                            "patch": "+        image: caddy:2.11.0@sha256:ec18ee54aab3315c22e25f3b2babda73ff8007d39b13b3bd1bfffa2f0444c7d9\n",
                        }
                    ]
                ).encode("utf-8")

        previous_env = {
            key: os.environ.get(key)
            for key in ("PR_NUMBER", "GITHUB_REPOSITORY", "GITHUB_TOKEN")
        }
        try:
            os.environ["PR_NUMBER"] = "2932"
            os.environ["GITHUB_REPOSITORY"] = "sholdee/home-ops"
            os.environ["GITHUB_TOKEN"] = ""
            output = io.StringIO()
            with patch.object(extract_image_info.request, "urlopen", return_value=FakeResponse()) as urlopen:
                with redirect_stdout(output):
                    images = extract_image_info.extract_images_from_pr_diff()

            self.assertEqual(
                images,
                [
                    (
                        "caddy",
                        "2.11.0",
                        "sha256:ec18ee54aab3315c22e25f3b2babda73ff8007d39b13b3bd1bfffa2f0444c7d9",
                    )
                ],
            )
            request_arg = urlopen.call_args.args[0]
            self.assertNotIn("Authorization", request_arg.headers)
        finally:
            for key, value in previous_env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()

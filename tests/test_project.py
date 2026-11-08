"""Offline infrastructure contracts, not compiler or real installation tests."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
OPAM = """#!/bin/sh
set -eu
printf '%s\n' "opam $*" >> "$MOCK_LOG"
case "$1" in
    --version) echo 2.6.1 ;;
    init) touch "$OPAMROOT/config" ;;
    switch) mkdir -p _opam ;;
    install)
        mkdir -p _opam/bin
        cp "$MOCK_ASSETS/dune" "$PWD/_opam/bin/dune"
        cp "$MOCK_ASSETS/ocamlc" "$PWD/_opam/bin/ocamlc"
        ;;
    exec)
        shift
        while [ "$1" != -- ]; do shift; done
        shift
        PATH="$PWD/_opam/bin:$PATH" exec "$@"
        ;;
    *) exit 90 ;;
esac
"""
DUNE = """#!/bin/sh
set -eu
printf '%s\n' "dune $*" >> "$MOCK_LOG"
if [ "${MOCK_DUNE_FAIL-}" = "$1" ]; then exit 17; fi
"""
CURL = """#!/bin/sh
set -eu
url=
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift ;;
        https:*) url=$1 ;;
    esac
    shift
done
printf '%s\n' "curl $url" >> "$MOCK_LOG"
if [ "${MOCK_DOWNLOAD_FAIL-}" = yes ]; then exit 6; fi
cp "$MOCK_ASSETS/${url##*/}" "$out"
"""


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class ScriptTests(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / ".agent-local" / "tmp"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="tern-contract-", dir=temporary_root
        )
        self.addCleanup(self.temporary.cleanup)
        # Exercise quoting with spaces in the checkout path.
        self.root = Path(self.temporary.name) / "test project"
        self.root.mkdir()
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        self.bin = self.root / ".tools" / "bin"
        self.bin.mkdir(parents=True)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.log = self.root / "calls"
        self.env = os.environ.copy()
        for key, suffix in {
            "HOME": "home",
            "TMPDIR": "tmp",
            "OPAMROOT": "opam",
            "XDG_CACHE_HOME": "cache",
            "XDG_CONFIG_HOME": "config",
            "XDG_DATA_HOME": "data",
        }.items():
            self.env[key] = str(self.root / ".agent-local" / suffix)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            MOCK_LOG=str(self.log),
            MOCK_ASSETS=str(self.assets),
        )
        self.env.pop("MOCK_DUNE_FAIL", None)
        self.env.pop("MOCK_DOWNLOAD_FAIL", None)
        executable(self.assets / "dune", DUNE)
        executable(self.assets / "ocamlc", "#!/bin/sh\necho 5.5.2\n")
        executable(self.bin / "curl", CURL)
        self.prepare_assets("Darwin", "arm64")

    def prepare_assets(self, os_name, cpu):
        os_tag = "macos" if os_name == "Darwin" else "linux"
        opam_arch = "arm64" if cpu in ("arm64", "aarch64") else cpu
        wasm_arch = "aarch64" if opam_arch == "arm64" else cpu
        executable(
            self.bin / "uname",
            f'#!/bin/sh\ncase "$1" in -s) echo {os_name};; -m) echo {cpu};; esac\n',
        )
        opam_name = f"opam-2.6.1-{opam_arch}-{os_tag}"
        executable(self.assets / opam_name, OPAM)
        wasm_dir = f"wasm-tools-1.263.0-{wasm_arch}-{os_tag}"
        wasm_source = self.assets / "wasm-tools"
        executable(wasm_source, "#!/bin/sh\necho 'wasm-tools 1.263.0'\n")
        archive = self.assets / (wasm_dir + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            output.add(wasm_source, arcname=wasm_dir + "/wasm-tools")
        # Fixture digests apply ONLY to mock assets, never production downloads.
        checksums = []
        for asset in (self.assets / opam_name, archive):
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            checksums.append(f"{digest}  {asset.name}\n")
        (self.root / "scripts" / "tool-checksums.sha256").write_text(
            "".join(checksums)
        )

    def run_script(self, name):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / name)],
            cwd=self.root / "assets",
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_scratch_clean(self):
        self.assertEqual(
            list((self.root / ".agent-local" / "tmp").glob("tern-setup.*")), []
        )

    def test_mocked_setup_all_supported_platforms(self):
        for os_name, cpu in (
            ("Darwin", "arm64"),
            ("Darwin", "x86_64"),
            ("Linux", "aarch64"),
            ("Linux", "x86_64"),
        ):
            with self.subTest(os=os_name, cpu=cpu):
                for name in ("opam", "wasm-tools"):
                    (self.bin / name).unlink(missing_ok=True)
                self.prepare_assets(os_name, cpu)
                result = self.run_script("setup.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Setup complete", result.stdout)
                self.assertTrue((self.bin / "wasm-tools").is_file())
                self.assert_scratch_clean()
        calls = self.calls()
        self.assertIn("opam init --bare --no-setup --yes", calls)
        self.assertEqual(calls.count("opam switch create . --empty --yes"), 1)
        self.assertIn(
            f"opam install --switch={self.root} --yes --no-depexts "
            "ocaml-base-compiler.5.5.2 dune",
            calls,
        )
        self.assertIn(
            f"opam install . --switch={self.root} --deps-only --with-test "
            "--yes --no-depexts",
            calls,
        )
        self.assertIn("dune build @opam -j 2", calls)

    def test_mocked_setup_is_repeatable(self):
        self.assertEqual(self.run_script("setup.sh").returncode, 0)
        self.log.unlink()
        result = self.run_script("setup.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c.startswith("curl ") for c in self.calls()))
        self.assertFalse(any(c.startswith("opam init ") for c in self.calls()))
        self.assertFalse(any(c.startswith("opam switch ") for c in self.calls()))
        self.assert_scratch_clean()

    def test_checksum_failure_installs_nothing_and_cleans_scratch(self):
        (self.root / "scripts" / "tool-checksums.sha256").write_text(
            "0" * 64 + "  opam-2.6.1-arm64-macos\n"
        )
        result = self.run_script("setup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum mismatch", result.stderr)
        self.assertFalse((self.bin / "opam").exists())
        self.assertFalse((self.root / "_opam").exists())
        self.assert_scratch_clean()

    def test_download_failure_is_not_swallowed(self):
        self.env["MOCK_DOWNLOAD_FAIL"] = "yes"
        result = self.run_script("setup.sh")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertFalse((self.bin / "opam").exists())
        self.assert_scratch_clean()

    def test_unsupported_host_is_rejected(self):
        executable(self.bin / "uname", "#!/bin/sh\necho Unsupported\n")
        result = self.run_script("setup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Supported hosts", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_external_home_is_rejected_before_writing(self):
        self.env["HOME"] = "/non-project-state-must-not-be-created"
        result = self.run_script("setup.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing non-project state path", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_check_requires_real_local_tool_paths(self):
        result = self.run_script("check.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Local toolchain missing", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_mocked_check_order_and_worker_limit(self):
        self.assertEqual(self.run_script("setup.sh").returncode, 0)
        self.log.unlink()
        result = self.run_script("check.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [c for c in self.calls() if c.startswith("dune ")],
            ["dune build -j 2", "dune test -j 2", "dune fmt -j 2"],
        )
        for call in self.calls():
            if call.startswith("opam exec "):
                self.assertIn(f"--switch={self.root}", call)

    def test_mocked_check_stops_on_each_failed_phase(self):
        self.assertEqual(self.run_script("setup.sh").returncode, 0)
        for index, phase in enumerate(("build", "test", "fmt")):
            with self.subTest(phase=phase):
                self.log.unlink(missing_ok=True)
                self.env["MOCK_DUNE_FAIL"] = phase
                result = self.run_script("check.sh")
                self.assertEqual(result.returncode, 17, result.stderr)
                dune_calls = [c for c in self.calls() if c.startswith("dune ")]
                self.assertEqual(len(dune_calls), index + 1)
                self.assertEqual(dune_calls[-1], f"dune {phase} -j 2")

    def test_supplied_environment_is_preserved_and_workers_are_bounded(self):
        executable(
            self.root / "scripts" / "probe.sh",
            '#!/bin/sh\nset -eu\n. "$(dirname -- "$0")/env.sh"\n'
            'printf "%s\\n" "$HOME" "$TMPDIR" "$OPAMROOT" '
            '"$XDG_CACHE_HOME" "$OPAMJOBS" "$OPAMDOWNLOADJOBS" '
            '"$DUNEJOBS" "$MAKEFLAGS" "$OPAMSWITCH"\n',
        )
        self.env["OPAMJOBS"] = "99"
        result = self.run_script("probe.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [self.env[k] for k in ("HOME", "TMPDIR", "OPAMROOT", "XDG_CACHE_HOME")]
            + ["2", "2", "2", "-j2", str(self.root)],
        )


class RepositoryTests(unittest.TestCase):
    def test_shell_syntax(self):
        for script in (ROOT / "scripts").glob("*.sh"):
            with self.subTest(script=script.name):
                subprocess.run(["/bin/bash", "-n", str(script)], check=True)

    def test_dependency_metadata_declares_requested_packages(self):
        project = (ROOT / "dune-project").read_text()
        opam = (ROOT / "ternc.opam").read_text()
        for name in (
            "ocaml", "dune", "menhir", "sedlex", "ppx_deriving", "ppx_expect",
            "qcheck", "js_of_ocaml", "js_of_ocaml-ppx", "ocamlformat",
        ):
            with self.subTest(package=name):
                self.assertIn(name, project)
                self.assertIn(f'"{name}"', opam)
        self.assertIn("(generate_opam_files true)", project)
        self.assertIn("version=0.29.0", (ROOT / ".ocamlformat").read_text())

    def test_release_digest_manifest_has_all_eight_assets(self):
        rows = (ROOT / "scripts" / "tool-checksums.sha256").read_text().splitlines()
        self.assertEqual(len(rows), 8)
        names = set()
        for row in rows:
            digest, name = row.split()
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            names.add(name)
        self.assertEqual(len(names), 8)
        self.assertIn("wasm-tools-1.263.0-aarch64-macos.tar.gz", names)
        self.assertIn("opam-2.6.1-arm64-macos", names)

    def test_fifteen_paired_utf8_examples_and_exact_output_fixtures(self):
        examples = ROOT / "examples"
        sources = sorted(examples.glob("*.tern"))
        outputs = sorted(examples.glob("*.out"))
        self.assertEqual(len(sources), 15)
        self.assertEqual([p.stem for p in sources], [p.stem for p in outputs])
        expected = [
            "Hello, Tern!\n", "14 -3 -2\n", "ready\n",
            'Hello, Tern!\n"quoted"\t\\\n', "start\n42\ndone\n", "22 10\n",
            "720\n", "even\nodd\n1\n", "142\n", "16 42\n", "42\n", "42 7\n",
            "zero pair\nsingle true pair\nmissing\n", "42\nno tree\n",
            "2 4 6 8 10\n6 8 10\n24\nsmall small big big big end\n",
        ]
        for index, (source, output, stdout) in enumerate(
            zip(sources, outputs, expected), start=1
        ):
            with self.subTest(program=source.name):
                self.assertTrue(source.name.startswith(f"{index:02}_"))
                self.assertTrue(source.read_text(encoding="utf-8").endswith(";;\n"))
                self.assertEqual(output.read_bytes(), stdout.encode("utf-8"))
        library = sources[-1].read_text()
        for function in ("map", "filter", "fold"):
            self.assertIn(f"let rec {function} ", library)


if __name__ == "__main__":
    unittest.main(verbosity=2)

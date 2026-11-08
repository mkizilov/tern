"""Offline infrastructure contracts, not compiler or real installation tests."""

import hashlib
import os
from pathlib import Path
import re
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
        # Dune source copies are read-only; only the owned mock manifest is rewritten.
        (self.root / "scripts").chmod(0o755)
        (self.root / "scripts" / "tool-checksums.sha256").chmod(0o644)
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
        executable(self.assets / "ocamlc", "#!/bin/sh\necho 5.4.1\n")
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
            "ocaml-base-compiler.5.4.1 dune",
            calls,
        )
        self.assertIn(
            f"opam install . --switch={self.root} --deps-only --with-test "
            "--yes --no-depexts",
            calls,
        )
        self.assertIn("dune build @opam --root . -j 2", calls)

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
            ["dune build --root . -j 2", "dune test --root . -j 2", "dune fmt --root . -j 2"],
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
                self.assertEqual(dune_calls[-1], f"dune {phase} --root . -j 2")

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
            "ocaml", "dune", "menhir", "menhirLib", "uucp", "sedlex",
            "ppx_deriving", "ppx_expect",
            "qcheck", "js_of_ocaml", "js_of_ocaml-ppx", "ocamlformat",
        ):
            with self.subTest(package=name):
                self.assertIn(name, project)
                self.assertIn(f'"{name}"', opam)
        self.assertIn("(generate_opam_files true)", project)
        self.assertIn("version=0.29.0", (ROOT / ".ocamlformat").read_text())

    def test_diagnostic_message_generation_is_part_of_the_native_build(self):
        dune = (ROOT / "lib" / "dune").read_text()
        messages = (ROOT / "lib" / "grammar.messages").read_text()
        parser = (ROOT / "lib" / "parse.ml").read_text()
        self.assertIn("--strict --table", dune)
        self.assertIn("--compile-errors grammar.messages grammar.mly", " ".join(dune.split()))
        self.assertIn("(target grammar_messages.ml)", dune)
        self.assertEqual(messages.count("program: "), 18)
        self.assertIn("expected `in` after let binding", messages)
        self.assertIn("Grammar_messages.message", parser)
        self.assertIn("I.HandlingError", parser)
        self.assertNotIn('"syntax error"', parser)

    def test_resolver_covers_surface_forms_and_uses_defined_core_constructors(self):
        ast = (ROOT / "lib" / "ast.ml").read_text()
        core = (ROOT / "lib" / "core.ml").read_text()
        resolver = (ROOT / "lib" / "resolve.ml").read_text()
        surface = ast.split("and expr_desc =", 1)[1].split("and binding =", 1)[0]
        variants = set(re.findall(r"\|\s*(E_\w+)", surface))
        handled = set(re.findall(r"\|\s*(?:Ast\.)?(E_\w+)", resolver))
        self.assertEqual(handled, variants)
        defined = set(re.findall(r"(?:=|\|)\s*([A-Z]\w*)", core))
        used = set(re.findall(r"Core\.([A-Z]\w*)", resolver))
        self.assertLessEqual(used, defined)
        expressions = core.split("and expr_desc =", 1)[1].split("and recursive_binding =", 1)[0]
        self.assertIn("Lambda of name * expr", expressions)
        self.assertIn("Let of pattern * expr * expr", expressions)
        self.assertNotRegex(expressions, r"\|\s*(Sequence|Unary|Binary)\b")

    def test_inference_covers_every_core_form(self):
        core = (ROOT / "lib" / "core.ml").read_text()
        inference = (ROOT / "lib" / "infer.ml").read_text()
        forms = core.split("and expr_desc =", 1)[1].split("and recursive_binding =", 1)[0]
        variants = set(re.findall(r"\|\s*(\w+)", forms))
        expression = inference.split("let rec expression ", 1)[1].split("let constructor_schemes ", 1)[0]
        handled = set(re.findall(r"\|\s*(?:Core\.)?(\w+)", expression))
        self.assertLessEqual(variants, handled)
        ty = (ROOT / "lib" / "ty.ml").read_text()
        self.assertIn("occurs_and_lower", ty)
        self.assertIn("owner > level", ty)
        self.assertIn("Generic id", ty)

    def test_check_cli_and_program_expectations_are_declared(self):
        executable = (ROOT / "bin" / "dune").read_text()
        main = (ROOT / "bin" / "ternc.ml").read_text()
        pipeline = (ROOT / "lib" / "check.ml").read_text()
        tests = (ROOT / "test" / "infer_tests.ml").read_text()
        self.assertIn("(public_name ternc)", executable)
        self.assertIn("Check.prepare", main)
        self.assertIn("Infer.format_bindings", main)
        for phase in ("Parse.program", "Resolve.program", "Infer.program"):
            self.assertIn(phase, pipeline)
        self.assertGreaterEqual(len(re.findall(r'let%expect_test "\d\d ', tests)), 30)
        self.assertIn("%{bin:ternc}", (ROOT / "test" / "dune").read_text())
        self.assertIn("ternc check polymorphic.tern --types", (ROOT / "test" / "cli.t").read_text())

    def test_match_coverage_is_typed_read_only_and_wired_to_cli_warnings(self):
        core = (ROOT / "lib" / "core.ml").read_text()
        coverage = (ROOT / "lib" / "coverage.ml").read_text()
        inference = (ROOT / "lib" / "infer.ml").read_text()
        main = (ROOT / "bin" / "ternc.ml").read_text()
        forms = core.split("and pattern_desc =", 1)[1].split("type expr =", 1)[0]
        variants = set(re.findall(r"\|\s*(\w+)", forms))
        normalize = coverage.split("let rec normalize ", 1)[1].split("let signature ", 1)[0]
        handled = set(re.findall(r"\|\s*(?:Core\.)?(\w+)", normalize))
        self.assertLessEqual(variants, handled)
        self.assertNotRegex(coverage, r"Ty\.(unify|fresh|generic|generalize|instantiate)\b")
        self.assertLess(inference.index("let body_type = expression"), inference.index("Coverage.check"))
        self.assertIn("checked.inferred.warnings", main)
        self.assertIn("Diagnostic.emit ~channel:stderr", main)
        self.assertIn("4608 usefulness queries", (ROOT / "test" / "coverage_tests.ml").read_text())

    def test_interpreter_covers_core_forms_and_requires_a_checked_program(self):
        core = (ROOT / "lib" / "core.ml").read_text()
        interpreter = (ROOT / "lib" / "interp.ml").read_text()
        interface = (ROOT / "lib" / "interp.mli").read_text()
        checked = (ROOT / "lib" / "check.mli").read_text()
        forms = core.split("and expr_desc =", 1)[1].split("and recursive_binding =", 1)[0]
        variants = set(re.findall(r"\|\s*(\w+)", forms))
        evaluator = interpreter.split("let rec evaluate ", 1)[1].split("and evaluate_fields ", 1)[0]
        handled = set(re.findall(r"\|\s*(?:Core\.)?(\w+)", evaluator))
        self.assertLessEqual(variants, handled)
        self.assertIn("Check.checked", interface)
        self.assertNotIn("val evaluate", interface)
        self.assertIn("type checked = private", checked)
        self.assertIn("shared := recursive_environment", interpreter)
        runtime = (ROOT / "lib" / "runtime.ml").read_text()
        self.assertIn("Int32.div", runtime)
        self.assertIn("Int32.min_int", runtime)
        self.assertIn("open Runtime", interpreter)

    def test_native_interpreter_corpus_tests_use_out_files_without_trimming(self):
        tests = (ROOT / "test" / "interp_tests.ml").read_text()
        cli = (ROOT / "test" / "interp_cli.t").read_text()
        dune = (ROOT / "test" / "dune").read_text()
        self.assertIn("(glob_files ../examples/*.out)", dune)
        self.assertIn("actual <> expected", tests)
        self.assertNotIn("String.trim", tests)
        self.assertIn("Interp.program", tests)
        self.assertIn("ternc run --interp", cli)
        self.assertIn('cmp "$expected" actual.out', cli)
        self.assertIn('test "$count" -eq 15', cli)

    def test_anf_uses_atoms_and_lowers_every_core_expression(self):
        core = (ROOT / "lib" / "core.ml").read_text()
        anf = (ROOT / "lib" / "anf.ml").read_text()
        lower = (ROOT / "lib" / "lower.ml").read_text()
        forms = core.split("and expr_desc =", 1)[1].split("and recursive_binding =", 1)[0]
        variants = set(re.findall(r"\|\s*(\w+)", forms))
        normalization = lower.split("let rec normalize ", 1)[1].split("and atoms ", 1)[0]
        handled = set(re.findall(r"\|\s*(?:Core\.)?(\w+)", normalization))
        self.assertLessEqual(variants, handled)
        self.assertIn("Apply of atom * atom", anf)
        self.assertIn("Jump of Core.name * atom list", anf)
        self.assertIn("Switch of atom", anf)
        self.assertIn("Anf.Payload subject", lower)
        self.assertIn("core.value.next_id", lower)

    def test_ir_interpreter_and_differential_corpus_are_real_native_targets(self):
        interpreter = (ROOT / "lib" / "ir_interp.ml").read_text()
        tests = (ROOT / "test" / "anf_tests.ml").read_text()
        cli = (ROOT / "test" / "ir_cli.t").read_text()
        main = (ROOT / "bin" / "ternc.ml").read_text()
        self.assertNotIn("Core.Match", interpreter)
        self.assertNotIn("Interp.program", interpreter)
        self.assertIn("Keys.find_opt", interpreter)
        self.assertIn("Runtime.primitive", interpreter)
        self.assertIn("Interp.program", tests)
        self.assertIn("Ir_interp.program", tests)
        self.assertIn("ast_output = expected && ir_output = expected", tests)
        self.assertIn("ternc run --ir", cli)
        self.assertIn("ternc dump-ir", cli)
        self.assertIn("Lower.program checked", main)

    def test_free_variable_analysis_covers_anf_and_closed_ir_has_no_lexical_functions(self):
        anf = (ROOT / "lib" / "anf.ml").read_text()
        free = (ROOT / "lib" / "free_vars.ml").read_text()
        closed = (ROOT / "lib" / "closed.ml").read_text()
        forms = anf.split("and expr_desc =", 1)[1].split("and rhs =", 1)[0]
        variants = set(re.findall(r"\|\s*(\w+)", forms))
        handled = set(re.findall(r"\|\s*(?:Anf\.)?(\w+)", free))
        self.assertLessEqual(variants, handled)
        self.assertIn("remove_all join.value.parameters", free)
        executable_forms = closed.split("type function_definition", 1)[0]
        self.assertNotRegex(executable_forms, r"\|\s*(Lambda|Let_rec)\b")
        self.assertIn("Direct_call of int * atom * atom", closed)
        self.assertIn("environment : Core.name", closed)

    def test_converted_interpreter_uses_only_explicit_environment_records(self):
        interpreter = (ROOT / "lib" / "closed_interp.ml").read_text()
        conversion = (ROOT / "lib" / "closure_convert.ml").read_text()
        runtime = (ROOT / "lib" / "runtime.ml").read_text()
        main = (ROOT / "bin" / "ternc.ml").read_text()
        tests = (ROOT / "test" / "closure_tests.ml").read_text()
        self.assertIn("Closure_record of int", runtime)
        self.assertIn("Array.make size None", interpreter)
        self.assertIn("let values = Ids.empty", " ".join(interpreter.split()))
        self.assertIn("Free_vars.function_body", conversion)
        self.assertIn("Closed.Environment_set", conversion)
        self.assertIn("Closed.Direct_call", conversion)
        self.assertIn("Ir_interp.closed ~write (Closure_convert.program", " ".join(main.split()))
        self.assertIn("AST = ANF = closed IR = golden bytes", tests)

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

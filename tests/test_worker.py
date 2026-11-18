"""Offline tests; no Capture, Ghostscript, drivers, or user designs are run."""
import csv
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

from pypdf import PdfReader, PdfWriter

SOURCE = Path(__file__).resolve().parents[1] / "src" / "worker.py"
spec = importlib.util.spec_from_file_location("worker", SOURCE)
w = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = w
spec.loader.exec_module(w)

CHIP = """FILE_TYPE=LIBRARY_PARTS;
{ synthetic test data, not a vendor library }
primitive 'DEVICE';
 pin 'IN': PIN_NUMBER='(1,2)'; end_pin;
 body JEDEC_TYPE='DIP14'; POWER_PINS='(VCC:14)'; POWER_PINS='(GND:7)'; end_body;
end_primitive;
END.
"""
PARTS = """FILE_TYPE=EXPANDEDPARTLIST;
PART_NAME U1 'DEVICE':;
SECTION_NUMBER 1 '@ROOT.ONE': C_PATH='C:\\demo\\design', SECTION='A';
SECTION_NUMBER 2 '@ROOT.TWO': SECTION='B';
PART_NAME U2 'DEVICE':;
SECTION_NUMBER 1 '@ROOT.THREE': SECTION='A';
END.
"""
NETS = """FILE_TYPE=EXPANDEDNETLIST;
NET_NAME 'DATA' '@ROOT':;
NODE_NAME U1 1 '@ROOT.ONE': 'IN':;
NODE_NAME U2 2 '@ROOT.THREE': 'IN':;
NET_NAME 'VCC' '@ROOT':;
NODE_NAME U1 14 '@ROOT.ONE': 'VCC':;
END.
"""


class WorkspaceCase(unittest.TestCase):
    def setUp(self):
        # Test and build scratch files remain under the workspace.
        base = SOURCE.parents[1] / ".work" / "tests"
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.dir = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def fixtures(self, chip=CHIP, parts=PARTS, nets=NETS):
        for name, text in [("pstchip.dat", chip), ("pstxprt.dat", parts), ("pstxnet.dat", nets)]:
            (self.dir / name).write_text(text, encoding="utf-8")
        return self.dir


class AllegroTests(WorkspaceCase):
    def test_native_files_preserved_byte_for_byte(self):
        self.fixtures()
        (self.dir / "extra.log").write_text("must not ship")
        before = {name: (self.dir / name).read_bytes() for name in w.ALLEGRO_FILES}
        output = self.dir / "demo_allegro.zip"
        footprints = w.package_allegro(self.dir, output, self.dir / "diagnostic.log")
        self.assertEqual(footprints, {"U1": "DIP14", "U2": "DIP14"})
        with zipfile.ZipFile(output) as z:
            self.assertEqual(z.namelist(), list(w.ALLEGRO_FILES))
            self.assertIsNone(z.testzip())
            for name, data in before.items():
                self.assertEqual(z.read(name), data)
        self.assertEqual(len(list(self.dir.glob("*.asc"))), 0)

    def test_native_power_group_is_preserved_without_inference(self):
        chip = CHIP.replace("end_body;", "POWER_GROUP='GROUP1'; end_body;")
        parts = PARTS.replace("SECTION='A'", "POWER_GROUP='SUPPLY1', SECTION='A'")
        self.fixtures(chip=chip, parts=parts)
        w.package_allegro(self.dir, self.dir / "native.zip")
        with zipfile.ZipFile(self.dir / "native.zip") as z:
            self.assertEqual(z.read("pstchip.dat"), (self.dir / "pstchip.dat").read_bytes())
            self.assertEqual(z.read("pstxprt.dat"), (self.dir / "pstxprt.dat").read_bytes())
            # Hidden power remains in the primitive, never synthesized as nodes.
            self.assertEqual(z.read("pstxnet.dat"), (self.dir / "pstxnet.dat").read_bytes())

    def test_pads_limits_are_not_applied(self):
        self.fixtures(chip=CHIP.replace("DIP14", "QFN48? 6X6MM"),
                      nets=NETS.replace("'DATA'", repr("DATA" * 20)))
        w.package_allegro(self.dir, self.dir / "native.zip")
        with zipfile.ZipFile(self.dir / "native.zip") as z:
            self.assertIn(b"QFN48? 6X6MM", z.read("pstchip.dat"))
            self.assertIn(("DATA" * 20).encode(), z.read("pstxnet.dat"))
        # These are archive pass-through checks, not an Allegro library-validity claim.

    def test_legacy_encoding_and_crlf_preserved(self):
        self.fixtures()
        data = CHIP.replace("DIP14", "封装").replace("\n", "\r\n").encode("gb18030")
        (self.dir / "pstchip.dat").write_bytes(data)
        w.package_allegro(self.dir, self.dir / "native.zip")
        with zipfile.ZipFile(self.dir / "native.zip") as z:
            self.assertEqual(z.read("pstchip.dat"), data)

    def test_long_reference_is_not_limited_to_pads(self):
        ref = "U" + "1" * 30
        self.fixtures(parts=PARTS.replace("U1", ref), nets=NETS.replace("U1", ref))
        footprints = w.package_allegro(self.dir, self.dir / "native.zip")
        self.assertIn(ref, footprints)

    def test_conflicting_pin_fails(self):
        with self.assertRaisesRegex(w.ExportError, "appears on both"):
            w.package_allegro(self.fixtures(nets=NETS.replace("NODE_NAME U1 14", "NODE_NAME U1 1")), self.dir / "bad.zip")

    def test_truncated_input_fails(self):
        with self.assertRaisesRegex(w.ExportError, "END"):
            w.package_allegro(self.fixtures(nets=NETS.replace("END.", "")), self.dir / "bad.zip")
        self.assertFalse((self.dir / "bad.zip").exists())

    def test_missing_or_empty_native_file_fails(self):
        self.fixtures()
        (self.dir / "pstxnet.dat").unlink()
        with self.assertRaisesRegex(w.ExportError, "pstxnet.dat"):
            w.package_allegro(self.dir, self.dir / "bad.zip")
        (self.dir / "pstxnet.dat").touch()
        with self.assertRaisesRegex(w.ExportError, "pstxnet.dat"):
            w.package_allegro(self.dir, self.dir / "bad.zip")

    def test_wrong_native_file_type_fails(self):
        with self.assertRaisesRegex(w.ExportError, "FILE_TYPE"):
            w.package_allegro(self.fixtures(nets=NETS.replace("EXPANDEDNETLIST", "OTHER")), self.dir / "bad.zip")

    def test_missing_footprint_fails(self):
        with self.assertRaisesRegex(w.ExportError, "PCB Footprint"):
            w.package_allegro(self.fixtures(chip=CHIP.replace("JEDEC_TYPE='DIP14';", "")), self.dir / "bad.zip")

    def test_unknown_part_and_primitive_fail(self):
        with self.assertRaisesRegex(w.ExportError, "unknown component"):
            w.package_allegro(self.fixtures(nets=NETS.replace("U1 1", "U9 1")), self.dir / "bad.zip")
        with self.assertRaisesRegex(w.ExportError, "missing primitive"):
            w.package_allegro(self.fixtures(parts=PARTS.replace("'DEVICE'", "'MISSING'")), self.dir / "bad.zip")

    def test_lexer_quotes_and_literal_backslashes(self):
        tokens = w.lex_pst("{comment} X='C:\\new\\a'; Y='Bob''s';")
        self.assertEqual(tokens[2].value, "C:\\new\\a")
        self.assertEqual(tokens[6].value, "Bob's")
        for text in ["X='truncated", "{truncated"]:
            with self.assertRaises(w.ExportError):
                w.lex_pst(text)

    def test_complete_job_commits_native_zip_pdf_and_csv(self):
        self.fixtures()
        root = self.dir / "output"
        root.mkdir()
        design = self.dir / "source.dsn"
        design.write_bytes(b"saved design")
        job = {"netlist_format": "allegro-pst", "design": str(design), "design_hash": w.file_hash(design), "root": str(root),
               "bom_rows": [{"ref": "U1"}, {"ref": "U2"}],
               "selected_pages": [{"schematic": "MAIN", "name": "PAGE1"}]}
        def fake_pdf(job, stage, output, log):
            writer = PdfWriter()
            writer.add_blank_page(width=300, height=400)
            writer.write(output)
            writer.close()
        for format_id, filename in [("allegro-pst", "source_allegro.zip"), ("pads-v3", "source.asc")]:
            with self.subTest(format=format_id):
                job["netlist_format"] = format_id
                with patch.object(w, "native_netlist", return_value=self.dir), patch.object(w, "make_pdf", side_effect=fake_pdf):
                    result = w.execute_job(job, self.dir)
                out = Path(result["output"])
                self.assertTrue(result["ok"])
                self.assertEqual(result["netlist_format"], format_id)
                self.assertEqual(result["parts"], 2)
                self.assertEqual({p.name for p in out.iterdir()}, {filename, "source.pdf", "source.csv"})
                if format_id == "allegro-pst":
                    with zipfile.ZipFile(out / filename) as z:
                        for name in w.ALLEGRO_FILES:
                            self.assertEqual(z.read(name), (self.dir / name).read_bytes())
                else:
                    self.assertTrue((out / filename).read_text().startswith("!PADS-POWERPCB-V3.0-MILS!"))
                    self.assertIn("U2.14", (out / filename).read_text())

    def test_failed_pads_export_commits_nothing_and_does_not_fall_back(self):
        self.fixtures(chip=CHIP.replace("DIP14", "INVALID FOOTPRINT"))
        root = self.dir / "output"
        root.mkdir()
        job = {"netlist_format": "pads-v3", "design": "source.dsn", "root": str(root)}
        with patch.object(w, "native_netlist", return_value=self.dir), patch.object(w, "make_pdf") as pdf:
            with self.assertRaisesRegex(w.ExportError, "Invalid PADS"):
                w.execute_job(job, self.dir)
        pdf.assert_not_called()
        self.assertEqual(list(root.iterdir()), [])


class PadsTests(WorkspaceCase):
    def test_full_connectivity_and_hidden_power(self):
        footprints = w.convert_pads(self.fixtures(), self.dir / "demo.asc")
        self.assertEqual(footprints, {"U1": "DIP14", "U2": "DIP14"})
        text = (self.dir / "demo.asc").read_text()
        self.assertEqual(text.count("U1.14"), 1)
        self.assertIn("*SIGNAL* GND\nU1.7 U2.7", text)
        self.assertIn("*SIGNAL* VCC\nU1.14 U2.14", text)
        self.assertIn("*SIGNAL* DATA\nU1.1 U2.2", text)
        self.assertTrue(text.startswith("!PADS-POWERPCB-V3.0-MILS!"))
        self.assertTrue(text.endswith("*END*\n"))

    def test_explicit_power_connection_wins(self):
        nets = NETS.replace("NET_NAME 'VCC'", "NET_NAME '+3V3'")
        w.convert_pads(self.fixtures(nets=nets), self.dir / "demo.asc")
        text = (self.dir / "demo.asc").read_text()
        self.assertIn("*SIGNAL* +3V3\nU1.14", text)
        self.assertIn("*SIGNAL* VCC\nU2.14", text)

    def test_conflicting_pin_fails(self):
        nets = NETS.replace("NODE_NAME U1 14", "NODE_NAME U1 1")
        with self.assertRaisesRegex(w.ExportError, "appears on both"):
            w.convert_pads(self.fixtures(nets=nets), self.dir / "bad.asc")

    def test_truncated_input_fails(self):
        with self.assertRaisesRegex(w.ExportError, "END"):
            w.convert_pads(self.fixtures(nets=NETS.replace("END.", "")), self.dir / "bad.asc")

    def test_missing_footprint_fails(self):
        with self.assertRaisesRegex(w.ExportError, "PCB Footprint"):
            w.convert_pads(self.fixtures(chip=CHIP.replace("JEDEC_TYPE='DIP14';", "")), self.dir / "bad.asc")

    def test_unsupported_name_fails_without_renaming(self):
        with self.assertRaisesRegex(w.ExportError, "Invalid PADS"):
            w.convert_pads(self.fixtures(nets=NETS.replace("'DATA'", "'数据信号'")), self.dir / "bad.asc")

    def test_net_length_and_case_conflicts(self):
        for name in ("D" * 48, "vcc"):
            with self.subTest(name=name), self.assertRaises(w.ExportError):
                w.convert_pads(self.fixtures(nets=NETS.replace("'DATA'", repr(name))), self.dir / "bad.asc")

    def test_unknown_part_and_primitive_fail(self):
        with self.assertRaisesRegex(w.ExportError, "unknown component"):
            w.convert_pads(self.fixtures(nets=NETS.replace("U1 1", "U9 1")), self.dir / "bad.asc")
        with self.assertRaisesRegex(w.ExportError, "missing primitive"):
            w.convert_pads(self.fixtures(parts=PARTS.replace("'DEVICE'", "'MISSING'")), self.dir / "bad.asc")

    def test_power_group_not_guessed(self):
        chip = CHIP.replace("end_body;", "POWER_GROUP='GROUP1'; end_body;")
        with self.assertRaisesRegex(w.ExportError, "POWER_GROUP"):
            w.convert_pads(self.fixtures(chip=chip), self.dir / "bad.asc")

    def test_lexer_quotes_and_literal_backslashes(self):
        tokens = w.lex_pst("{comment} X='C:\\new\\a'; Y='Bob''s';")
        self.assertEqual(tokens[2].value, "C:\\new\\a")
        self.assertEqual(tokens[6].value, "Bob's")
        for text in ["X='truncated", "{truncated"]:
            with self.assertRaises(w.ExportError):
                w.lex_pst(text)

    def test_multi_pin_power_expression(self):
        chip = CHIP.replace("(VCC:14)", "(VCC:14,28)(AUX:30)")
        w.convert_pads(self.fixtures(chip=chip), self.dir / "demo.asc")
        text = (self.dir / "demo.asc").read_text()
        self.assertIn("U1.28", text)
        self.assertIn("*SIGNAL* AUX\nU1.30 U2.30", text)


class BomTests(WorkspaceCase):
    def test_multisection_dedup_and_group(self):
        row = {"ref": "U1", "value": "74LS", "part_number": "=1+1", "description": "中文,含逗号\n第二行"}
        rows = [row, row.copy(), {**row, "ref": "U2"}, {"ref": "BLOCK1"}]
        path = self.dir / "bom.csv"
        count = w.write_bom(rows, {"U1": "DIP14", "U2": "DIP14"}, path)
        self.assertEqual(count, 2)
        self.assertTrue(path.read_bytes().startswith(b"\xef\xbb\xbf"))
        with path.open(encoding="utf-8-sig", newline="") as stream:
            result = list(csv.reader(stream))
        self.assertEqual(len(result), 2)
        self.assertEqual(result[1][1:3], ["U1, U2", "2"])
        self.assertEqual(result[1][5], "'=1+1")
        self.assertEqual(result[1][7], row["description"])

    def test_mismatched_units_fail(self):
        with self.assertRaisesRegex(w.ExportError, "Inconsistent BOM"):
            w.write_bom([{"ref": "U1", "value": "A"}, {"ref": "U1", "value": "B"}], {"U1": "DIP14"}, self.dir / "bad.csv")

    def test_missing_component_fails(self):
        with self.assertRaisesRegex(w.ExportError, "missing netlist components"):
            w.write_bom([], {"U1": "DIP14"}, self.dir / "bad.csv")


class PdfTests(WorkspaceCase):
    def setUp(self):
        super().setUp()
        self.printed = [{"schematic": "MAIN", "name": name} for name in ["P3", "P1", "P2"]]

    def test_noncontiguous_selection_uses_actual_print_sequence(self):
        selected = [self.printed[1], self.printed[0]]
        self.assertEqual(w.choose_page_indices(self.printed, selected, 3), [1, 0])

    def test_ambiguous_or_missing_pages_fail(self):
        for printed, selected, count in [
            (self.printed, [], 3),
            (self.printed, self.printed, 2),
            ([self.printed[0]] * 2, [self.printed[0]], 2),
            (self.printed, [{"schematic": "OTHER", "name": "P1"}], 3),
            (self.printed, [self.printed[0]] * 2, 3),
        ]:
            with self.subTest(printed=printed, selected=selected), self.assertRaises(w.ExportError):
                w.choose_page_indices(printed, selected, count)

    def test_pdf_written_with_selected_pages_only(self):
        gs = self.dir / "gswin64c.exe"
        gs.write_bytes(b"offline mock only")
        ps = self.dir / "pages.ps"
        ps.write_bytes(b"%!PS-Adobe-3.0\n%%Page: 1 1\n%%Page: 2 2\n%%Page: 3 3\n")
        def fake_conversion(argv, log, **kwargs):
            path = Path(next(arg.split("=", 1)[1] for arg in argv if arg.startswith("-sOutputFile=")))
            writer = PdfWriter()
            for width in [300, 400, 500]:
                writer.add_blank_page(width=width, height=600)
            writer.write(path)
            writer.close()
        job = {"ghostscript": str(gs), "postscript": str(ps), "printed_pages": self.printed,
               "selected_pages": [self.printed[1], self.printed[0]], "design": "中文设计.dsn"}
        output = self.dir / "selection.pdf"
        with patch.object(w, "run_tool", side_effect=fake_conversion):
            w.make_pdf(job, self.dir, output, self.dir / "log.txt")
        with PdfReader(output) as reader:
            self.assertEqual([int(p.mediabox.width) for p in reader.pages], [400, 300])
            self.assertEqual([entry.title for entry in reader.outline], ["MAIN / P1", "MAIN / P3"])

    def test_dsc_mismatch_fails_before_converter(self):
        gs, ps = self.dir / "gswin64c.exe", self.dir / "empty.ps"
        gs.write_bytes(b"fake")
        ps.write_bytes(b"%!PS\n")
        with patch.object(w, "run_tool") as converter, self.assertRaisesRegex(w.ExportError, "PostScript"):
            w.make_pdf({"ghostscript": str(gs), "postscript": str(ps), "printed_pages": self.printed}, self.dir, self.dir / "bad.pdf", self.dir / "log")
        converter.assert_not_called()


class CommitTests(WorkspaceCase):
    def files(self):
        paths = [self.dir / ("设计" + ext) for ext in (".zip", ".pdf", ".csv")]
        for p in paths:
            p.write_bytes(b"test payload")
        return paths

    def test_exact_three_and_no_overwrite(self):
        root = self.dir / "中文 根目录"
        root.mkdir()
        (root / "existing.txt").write_text("keep")
        files = self.files()
        with patch.object(w.time, "strftime", return_value="fixed"):
            first = w.commit_three(files, root, "设计")
            second = w.commit_three(files, root, "设计")
        self.assertNotEqual(first, second)
        self.assertEqual({p.suffix for p in first.iterdir()}, {".zip", ".pdf", ".csv"})
        self.assertEqual(len(list(first.iterdir())), 3)
        self.assertEqual((root / "existing.txt").read_text(), "keep")

    def test_failed_copy_rolls_back_only_pending_directory(self):
        root = self.dir / "out"
        root.mkdir()
        (root / "keep.txt").write_text("unchanged")
        def fail_copy(src, dst):
            if src.suffix == ".pdf":
                raise OSError("simulated disk full")
            return shutil.copy2(src, dst)
        with self.assertRaises(OSError):
            w.commit_three(self.files(), root, "design", copier=fail_copy)
        self.assertEqual([p.name for p in root.iterdir()], ["keep.txt"])

    def test_corrupt_copy_rejected(self):
        root = self.dir / "out"
        root.mkdir()
        def corrupt(src, dst):
            dst.write_bytes(b"corrupted")
        with self.assertRaisesRegex(w.ExportError, "verification failed"):
            w.commit_three(self.files(), root, "design", copier=corrupt)
        self.assertEqual(list(root.iterdir()), [])

    def test_pads_commit_and_mixed_formats(self):
        files = self.files()
        files[0] = files[0].with_suffix(".asc")
        files[0].write_bytes(b"PADS")
        output = w.commit_three(files, self.dir, "pads")
        self.assertEqual({p.suffix for p in output.iterdir()}, {".asc", ".pdf", ".csv"})
        with self.assertRaises(w.ExportError):
            w.commit_three([files[0], self.files()[0], files[1]], self.dir, "mixed")

    def test_incomplete_set_rejected(self):
        with self.assertRaises(w.ExportError):
            w.commit_three(self.files()[:2], self.dir, "design")

    def test_safe_reserved_names(self):
        self.assertEqual(w.safe_basename("CON"), "_CON")
        self.assertEqual(w.safe_basename('a/b:c?'), "a_b_c_")


class ProcessTests(WorkspaceCase):
    def test_old_panel_cannot_silently_change_netlist_format(self):
        with patch.object(w, "native_netlist") as native, self.assertRaisesRegex(w.ExportError, "Restart Capture"):
            w.execute_job({}, self.dir)
        native.assert_not_called()

    def test_unsupported_format_fails_before_native_command(self):
        for value in ["unknown", "", [], 3]:
            with self.subTest(value=value), patch.object(w, "native_netlist") as native:
                with self.assertRaisesRegex(w.ExportError, "Unsupported netlist format"):
                    w.execute_job({"netlist_format": value}, self.dir)
                native.assert_not_called()

    def native_fixture(self):
        root = self.dir / "cadence"
        (root / "tools/bin").mkdir(parents=True)
        (root / "tools/capture").mkdir()
        (root / "tools/bin/pstswp.exe").write_bytes(b"mock")
        (root / "tools/capture/allegro.cfg").write_bytes(b"mock")
        source = self.dir / "source"
        source.mkdir()
        design = source / "设计 with spaces.DSN"
        design.write_bytes(b"saved design revision")
        job = {"cadence_root": str(root), "design": str(design), "design_hash": w.file_hash(design)}
        return job, design

    def test_packaging_rewrites_only_private_snapshot(self):
        job, design = self.native_fixture()
        original = design.read_bytes()
        def packaging(argv, log, **kwargs):
            snapshot = Path(argv[argv.index("-d") + 1])
            self.assertNotEqual(snapshot.resolve(), design.resolve())
            self.assertEqual(snapshot.name, design.name)
            self.assertEqual(snapshot.read_bytes(), original)
            snapshot.write_bytes(original + b"\nCadence packaging metadata")
        with patch.object(w, "run_tool", side_effect=packaging):
            out = w.native_netlist(job, self.dir, self.dir / "diagnostic.log")
        self.assertTrue(out.is_dir())
        self.assertEqual(design.read_bytes(), original)
        self.assertEqual(w.file_hash(design), job["design_hash"])
        self.assertIn("Snapshot SHA256 after netlisting:", (self.dir / "diagnostic.log").read_text(encoding="utf-8"))

    def test_user_save_during_netlisting_still_blocks_output(self):
        job, design = self.native_fixture()
        with patch.object(w, "run_tool", side_effect=lambda *a, **k: design.write_bytes(b"new user revision")):
            with self.assertRaisesRegex(w.ExportError, "source DSN changed"):
                w.native_netlist(job, self.dir, self.dir / "diagnostic.log")
        self.assertEqual(design.read_bytes(), b"new user revision")

    def test_user_save_during_snapshot_blocks_netlister(self):
        job, design = self.native_fixture()
        copy = shutil.copyfile
        def save_during_copy(source, destination):
            copy(source, destination)
            design.write_bytes(b"new user revision")
        with patch.object(w.shutil, "copyfile", side_effect=save_during_copy), patch.object(w, "run_tool") as native:
            with self.assertRaisesRegex(w.ExportError, "export snapshot"):
                w.native_netlist(job, self.dir, self.dir / "diagnostic.log")
        native.assert_not_called()

    def test_corrupt_snapshot_blocks_netlister(self):
        job, design = self.native_fixture()
        with patch.object(w.shutil, "copyfile", side_effect=lambda src, dst: dst.write_bytes(b"corrupt")), patch.object(w, "run_tool") as native:
            with self.assertRaisesRegex(w.ExportError, "export snapshot"):
                w.native_netlist(job, self.dir, self.dir / "diagnostic.log")
        native.assert_not_called()
        self.assertEqual(w.file_hash(design), job["design_hash"])

    def test_native_failure_keeps_source_unchanged(self):
        job, design = self.native_fixture()
        def failed_packaging(argv, log, **kwargs):
            Path(argv[argv.index("-d") + 1]).write_bytes(b"partial packaging write")
            raise w.ExportError("pstswp failed")
        with patch.object(w, "run_tool", side_effect=failed_packaging):
            with self.assertRaisesRegex(w.ExportError, "pstswp failed"):
                w.native_netlist(job, self.dir, self.dir / "diagnostic.log")
        self.assertEqual(w.file_hash(design), job["design_hash"])

    def test_hash_writes_only_explicit_output(self):
        design = self.dir / "demo.dsn"
        design.write_bytes(b"fixture")
        result = self.dir / "job.hash"
        self.assertEqual(w.main(["hash", str(design), "--output", str(result)]), 0)
        self.assertEqual(result.read_text(), w.file_hash(design))
        self.assertFalse(Path(str(design) + ".sha256").exists())

    def test_failed_job_reports_error_without_output(self):
        manifest = self.dir / "job.json"
        manifest.write_text("{}")
        with patch.object(w, "execute_job", side_effect=w.ExportError("expected failure")):
            self.assertEqual(w.main(["run", str(manifest)]), 1)
        result = json.loads((self.dir / "result.json").read_text(encoding="utf-8"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "expected failure")

    def test_changed_design_blocks_native_command(self):
        root = self.dir / "cadence"
        (root / "tools/bin").mkdir(parents=True)
        (root / "tools/capture").mkdir()
        (root / "tools/bin/pstswp.exe").write_bytes(b"mock")
        (root / "tools/capture/allegro.cfg").write_bytes(b"mock")
        design = self.dir / "demo.dsn"
        design.write_bytes(b"modified")
        job = {"cadence_root": str(root), "design": str(design), "design_hash": "original"}
        with patch.object(w, "run_tool") as native, self.assertRaisesRegex(w.ExportError, "changed"):
            w.native_netlist(job, self.dir, self.dir / "log")
        native.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""BOM selection keeps netlists complete and filters physical components."""
import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_worker import w, CHIP, PARTS, NETS, SOURCE


def rule(field="ref", value="R*", action="exclude", op="glob", property=""):
    return dict(action=action, field=field, property=property, op=op, value=value)


def config(*rules, mode="any", enabled=True):
    return dict(enabled=enabled, include_match=mode, rules=list(rules))


class BomFilterTests(unittest.TestCase):
    def setUp(self):
        base = SOURCE.parents[1] / '.work/tests'
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.rows = [
            dict(ref="R1", value="10k", color="48", dnp="YES", manufacturer="Maker A", filter_values={"Assembly": "No", "备注": "不装"}),
            dict(ref="R2", value="10k", color="12", dnp="", manufacturer="Maker A", filter_values={"Assembly": "", "备注": ""}),
            dict(ref="C1", value="100n", color="48", dnp="", manufacturer="Maker B", filter_values={"Assembly": "Yes", "备注": "装配"}),
            dict(ref="U1", value="Logic", color="7", dnp="", manufacturer="Maker C", filter_values={"Assembly": "Yes", "备注": ""}),
        ]
        self.footprints = dict(R1="R0402", R2="R0402", C1="C0402", U1="QFN")

    def export(self, settings, rows=None):
        audit = {}
        output = self.directory / 'bom.csv'
        count = w.write_bom(self.rows if rows is None else rows, self.footprints, output, settings, audit=audit)
        with output.open(encoding='utf-8-sig', newline='') as stream:
            result = list(csv.DictReader(stream))
        refs = {ref for row in result for ref in row['Reference'].split(', ')}
        self.assertEqual(count, len(refs))
        self.assertEqual(audit['included'] + audit['excluded'], audit['total'])
        for row in result:
            self.assertEqual(int(row['Quantity']), len(row['Reference'].split(', ')))
        return refs, result, audit

    def test_legacy_and_disabled_export_every_component(self):
        for settings in (None, config(rule(), enabled=False), config()):
            with self.subTest(settings=settings):
                self.assertEqual(self.export(settings)[0], set(self.footprints))

    def test_reference_exclusion_and_full_netlist_coverage(self):
        refs, _, audit = self.export(config(rule()))
        self.assertEqual(refs, {"C1", "U1"})
        self.assertEqual(audit['excluded_refs'], ["R1", "R2"])
        self.assertEqual(len(self.footprints), 4)

    def test_include_any_all_and_exclusion_precedence(self):
        a = rule(action="include")
        b = rule("value", "100n", "include", "equals")
        self.assertEqual(self.export(config(a, b))[0], {"R1", "R2", "C1"})
        self.assertEqual(self.export(config(a, b, mode="all"))[0], set())
        self.assertEqual(self.export(config(a, rule("dnp", " yes ", op="equals")))[0], {"R2"})

    def test_color_is_distinct_from_custom_color_property(self):
        refs = self.export(config(rule("color", "048", op="equals")))[0]
        self.assertEqual(refs, {"R2", "U1"})
        for row in self.rows:
            row['filter_values']['Color'] = "blue"
        self.assertEqual(self.export(config(rule("property", "blue", property="Color", op="equals")))[0], set())

    def test_custom_property_unicode_and_empty_values(self):
        self.assertEqual(self.export(config(rule("property", "不装", property="备注", op="equals")))[0], {"R2", "C1", "U1"})
        self.assertEqual(self.export(config(rule("property", "", property="Assembly", op="is_empty")))[0], {"R1", "C1", "U1"})

    def test_text_operators_and_footprints(self):
        cases = [('equals', ' maker a ', {'R1', 'R2'}), ('not_equals', 'Maker A', {'C1', 'U1'}),
                 ('contains', 'ER A', {'R1', 'R2'}), ('not_contains', 'ER A', {'C1', 'U1'}),
                 ('glob', 'maker [AB]', {'R1', 'R2', 'C1'}), ('not_empty', '', set(self.footprints))]
        for op, value, expected in cases:
            self.assertEqual(self.export(config(rule('manufacturer', value, 'include', op)))[0], expected)
        self.assertEqual(self.export(config(rule('footprint', '*0402', 'include')))[0], {'R1', 'R2', 'C1'})

    def test_multiunit_exclude_removes_whole_component(self):
        second = dict(self.rows[-1], color='48')
        self.assertEqual(self.export(config(rule('color', '48', op='equals')), self.rows + [second])[0], {'R2'})

    def test_no_matches_and_all_excluded(self):
        self.assertEqual(self.export(config(rule('ref', 'X*')))[0], set(self.footprints))
        refs, rows, audit = self.export(config(rule('ref', '*')))
        self.assertEqual(refs, set())
        self.assertEqual(rows, [])
        self.assertEqual(audit['excluded'], 4)
        self.assertTrue((self.directory / 'bom.csv').read_bytes().startswith(b'\xef\xbb\xbfItem,'))

    def test_missing_capture_data_and_unreadable_color_stop_export(self):
        for target, settings in [('color', config(rule('color', '48', op='equals'))),
                                  ('filter_values', config(rule('property', 'Yes', property='Assembly', op='equals')))]:
            rows = [dict(r) for r in self.rows]
            del rows[-1][target]
            with self.subTest(target=target), self.assertRaises(w.ExportError):
                self.export(settings, rows)

    def test_filtered_ref_missing_from_capture_still_fails(self):
        with self.assertRaisesRegex(w.ExportError, 'missing netlist components'):
            self.export(config(rule('ref', '*')), self.rows[:-1])

    def test_inconsistent_units_not_hidden_by_exclusion(self):
        with self.assertRaisesRegex(w.ExportError, 'Inconsistent BOM'):
            self.export(config(rule('ref', '*')), self.rows + [dict(self.rows[0], value='different')])

    def test_invalid_filters_stop_before_native_netlist(self):
        bad = [True, {}, config(rule('unknown')), config(rule(op='eval')),
               config(rule('property', '1')), config(rule('color', 'red', op='equals')),
               config(rule('color', '48', op='contains')), config(rule(value='')),
               config(*[rule()] * 101), config(rule(), mode='bad')]
        for settings in bad:
            with self.subTest(settings=settings), patch.object(w, 'native_netlist') as native:
                with self.assertRaises(w.ExportError):
                    w.execute_job({'netlist_format': 'allegro-pst', 'bom_filter': settings}, self.directory)
                native.assert_not_called()

    def test_filtered_jobs_keep_complete_netlists_and_three_files(self):
        for name, data in [('pstchip.dat', CHIP), ('pstxprt.dat', PARTS), ('pstxnet.dat', NETS)]:
            (self.directory / name).write_text(data)
        design = self.directory / 'source.dsn'
        design.write_bytes(b'synthetic revision')
        root = self.directory / 'output'
        root.mkdir()
        job = dict(design=str(design), design_hash=w.file_hash(design), root=str(root),
                   selected_pages=[dict(schematic='MAIN', name='PAGE1')],
                   bom_rows=[dict(ref='U1'), dict(ref='U2')], bom_filter=config(rule('ref', 'U1', op='equals')))
        for format_id in w.NETLIST_FORMATS:
            with self.subTest(format=format_id), patch.object(w, 'native_netlist', return_value=self.directory), \
                    patch.object(w, 'make_pdf', side_effect=lambda j, s, out, log: out.write_bytes(b'PDF fixture')):
                result = w.execute_job(dict(job, netlist_format=format_id), self.directory)
            out = Path(result['output'])
            self.assertEqual(len(list(out.iterdir())), 3)
            self.assertEqual((result['parts'], result['netlist_parts'], result['bom_excluded']), (1, 2, 1))
            if format_id == 'pads-v3':
                self.assertIn('U1 DIP14', next(out.glob('*.asc')).read_text())
                self.assertIn('U2 DIP14', next(out.glob('*.asc')).read_text())
            else:
                import zipfile
                with zipfile.ZipFile(next(out.glob('*.zip'))) as archive:
                    self.assertEqual(archive.read('pstxprt.dat'), (self.directory / 'pstxprt.dat').read_bytes())
            with next(out.glob('*.csv')).open(encoding='utf-8-sig') as f:
                self.assertEqual([r['Reference'] for r in csv.DictReader(f)], ['U2'])


if __name__ == '__main__':
    unittest.main()

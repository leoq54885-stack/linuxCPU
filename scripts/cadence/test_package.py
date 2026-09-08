#!/usr/bin/env python3
"""Small offline tests of the Cadence-specific source transformations."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cadence_package', str(HERE / 'package.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_tb(self):
        source = '''module tb();
wire a;
assign #1 a = 1;
reg [31:0] cycle_count;
reg [31:0] retire_inst_in_period;
`ifndef NO_DUMP
initial begin
`ifdef NC_SIM
$dumpvars;
`else
$fsdbDumpvars();
`endif
end
`endif
endmodule
'''
        result = package.adapt_tb(source)
        self.assertNotIn('$dump', result)
        self.assertNotIn('$fsdb', result)
        self.assertIn('assign #1 a = 1;', result)
        self.assertLess(result.index('reg [31:0] cycle_count;'), result.index('wire a;'))
        with self.assertRaises(RuntimeError):
            package.adapt_tb(source.replace('reg [31:0] cycle_count;', ''))
        with self.assertRaises(RuntimeError):
            package.adapt_tb(source.replace('`ifndef NO_DUMP', '`ifdef SOMETHING_ELSE'))

    def test_filelist(self):
        with tempfile.TemporaryDirectory(prefix='cadence-package-test-') as tmp:
            b = Path(tmp)
            for d in ['cpu/rtl', 'idu/rtl', 'dtu/rtl', 'lsu/rtl', 'mmu/rtl', 'tdt/rtl/top', 'filelists']:
                (b / 'rtl/gen_rtl' / d).mkdir(parents=True, exist_ok=True)
            for d in ['filelists', 'tb', 'mem']:
                (b / 'rtl/logical' / d).mkdir(parents=True)
            (b / 'sim').mkdir()
            (b / 'sim/tb-linux.v').touch()
            (b / 'rtl/gen_rtl/cpu/rtl/cpu_cfig.h').touch()
            (b / 'rtl/gen_rtl/filelists/C906_asic_rtl.fl').write_text('/* comment */\n${CODE_BASE_PATH}/gen_rtl/cpu/rtl/cpu_cfig.h\n')
            (b / 'rtl/gen_rtl/filelists/tdt_dmi_top_rtl.fl').write_text('// comment\n')
            (b / 'rtl/logical/filelists/smart.fl').write_text('+libext+.v+.h+\n-y ../logical/mem\n')
            text = package.make_filelist(b)
            self.assertTrue(text.startswith('+incdir+../rtl/gen_rtl/cpu/rtl\n'))
            self.assertIn('../rtl/gen_rtl/cpu/rtl/cpu_cfig.h\n', text)
            self.assertNotIn('comment', text)
            self.assertNotIn('${', text)
            (b / 'rtl/gen_rtl/cpu/rtl/cpu_cfig.h').unlink()
            with self.assertRaises(RuntimeError):
                package.make_filelist(b)


if __name__ == '__main__':
    unittest.main()

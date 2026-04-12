import unittest
import sys
import os
import tempfile
import io
from unittest.mock import patch, MagicMock

# Add scripts directory to sys.path to import bpf_helpers_doc
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import bpf_helpers_doc
from bpf_helpers_doc import Helper, HeaderParser, ParsingError, Printer, PrinterRST

class TestBpfHelpersDoc(unittest.TestCase):
    def test_helper_proto_break_down(self):
        # Test basic prototype
        proto = 'void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)'
        helper = Helper(proto=proto)
        res = helper.proto_break_down()

        self.assertEqual(res['ret_type'], 'void')
        self.assertEqual(res['ret_star'], '*')
        self.assertEqual(res['name'], 'bpf_map_lookup_elem')
        self.assertEqual(len(res['args']), 2)

        self.assertEqual(res['args'][0]['type'], 'struct bpf_map')
        self.assertEqual(res['args'][0]['star'], '*')
        self.assertEqual(res['args'][0]['name'], 'map')

        self.assertEqual(res['args'][1]['type'], 'const void')
        self.assertEqual(res['args'][1]['star'], '*')
        self.assertEqual(res['args'][1]['name'], 'key')

    def test_helper_proto_break_down_no_args(self):
        # Test prototype with void args
        proto = 'u64 bpf_ktime_get_ns(void)'
        helper = Helper(proto=proto)
        res = helper.proto_break_down()

        self.assertEqual(res['ret_type'], 'u64')
        self.assertEqual(res['ret_star'], '')
        self.assertEqual(res['name'], 'bpf_ktime_get_ns')
        self.assertEqual(len(res['args']), 1)

        self.assertEqual(res['args'][0]['type'], 'void')
        self.assertEqual(res['args'][0]['star'], None)
        self.assertEqual(res['args'][0]['name'], None)

    def test_helper_proto_break_down_varargs(self):
        # Test prototype with ...
        proto = 'int bpf_trace_printk(const char *fmt, u32 fmt_size, ...)'
        helper = Helper(proto=proto)
        res = helper.proto_break_down()

        self.assertEqual(res['ret_type'], 'int')
        self.assertEqual(res['ret_star'], '')
        self.assertEqual(res['name'], 'bpf_trace_printk')
        self.assertEqual(len(res['args']), 3)

        self.assertEqual(res['args'][2]['type'], '...')
        self.assertEqual(res['args'][2]['star'], None)
        self.assertEqual(res['args'][2]['name'], None)

    def test_header_parser(self):
        # Mocking a valid bpf.h file content
        bpf_h_content = """
/*
 * Start of BPF helper function descriptions:
 *
 * void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)
 * 	Description
 * 		Perform a lookup in *map* for an entry associated to *key*.
 * 	Return
 * 		Map value associated to *key*, or **NULL** if no entry was
 * 		found.
 *
 * int bpf_map_update_elem(struct bpf_map *map, const void *key, const void *value, u64 flags)
 * 	Description
 * 		Add or update the value of the entry associated to *key* in
 * 		*map* with *value*. *flags* is one of:
 *
 * 		**BPF_NOEXIST**
 * 			The entry for *key* must not exist in the map.
 * 		**BPF_EXIST**
 * 			The entry for *key* must already exist in the map.
 * 		**BPF_ANY**
 * 			No condition on the existence of the entry for *key*.
 * 	Return
 * 		0 on success, or a negative error in case of failure.
 */
"""
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
            f.write(bpf_h_content)
            temp_name = f.name

        try:
            parser = HeaderParser(temp_name)
            parser.run()

            self.assertEqual(len(parser.helpers), 2)

            # Check first helper
            h1 = parser.helpers[0]
            self.assertEqual(h1.proto, 'void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)')
            self.assertEqual(h1.desc, 'Perform a lookup in *map* for an entry associated to *key*.\n')
            self.assertEqual(h1.ret, 'Map value associated to *key*, or **NULL** if no entry was\nfound.\n\n')

            # Check second helper
            h2 = parser.helpers[1]
            self.assertEqual(h2.proto, 'int bpf_map_update_elem(struct bpf_map *map, const void *key, const void *value, u64 flags)')
            self.assertTrue('Add or update the value of the entry associated to *key* in' in h2.desc)
            self.assertTrue('0 on success, or a negative error in case of failure.' in h2.ret)

        finally:
            os.remove(temp_name)

    def test_header_parser_no_description_or_return(self):
        # Mocking a bpf.h file content without Description or Return
        bpf_h_content = """
/*
 * Start of BPF helper function descriptions:
 *
 * u64 bpf_ktime_get_ns(void)
 */
"""
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
            f.write(bpf_h_content)
            temp_name = f.name

        try:
            parser = HeaderParser(temp_name)
            parser.run()

            self.assertEqual(len(parser.helpers), 1)

            h1 = parser.helpers[0]
            self.assertEqual(h1.proto, 'u64 bpf_ktime_get_ns(void)')
            self.assertEqual(h1.desc, '')
            self.assertEqual(h1.ret, '')
        finally:
            os.remove(temp_name)

    def test_header_parser_no_start_marker(self):
        bpf_h_content = """
/*
 * Some other documentation
 */
"""
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
            f.write(bpf_h_content)
            temp_name = f.name

        try:
            parser = HeaderParser(temp_name)
            with self.assertRaises(Exception) as context:
                parser.run()
            self.assertTrue('Could not find start of eBPF helper descriptions list' in str(context.exception))
        finally:
            os.remove(temp_name)

    def test_parsing_error(self):
        err1 = ParsingError("bad line")
        self.assertEqual(str(err1), 'Error parsing line: bad line')

        mock_reader = MagicMock()
        mock_reader.tell.return_value = 123
        err2 = ParsingError("bad line", reader=mock_reader)
        self.assertEqual(str(err2), 'Error at file offset 123, parsing line: bad line')

    def test_printer_base(self):
        helpers = [Helper("proto", "desc", "ret")]
        printer = Printer(helpers)

        # Test base methods don't crash
        printer.print_header()
        printer.print_footer()
        printer.print_one(helpers[0])
        printer.print_all()

    def test_printer_rst(self):
        helper1 = Helper(
            proto="int bpf_trace_printk(const char *fmt, u32 fmt_size, ...)",
            desc="Print a message.\n",
            ret="The number of bytes written.\n"
        )
        helper2 = Helper(
            proto="u64 bpf_ktime_get_ns(void)",
            desc="",
            ret=""
        )
        helpers = [helper1, helper2]

        printer = PrinterRST(helpers)

        with patch('sys.stdout', new=io.StringIO()) as fake_out:
            printer.print_all()
            output = fake_out.getvalue()

        self.assertIn("===========\nBPF-HELPERS\n===========", output)
        self.assertIn("**int bpf_trace_printk(const char \\***\\ *fmt*\\ **, u32** *fmt_size*\\ **, ...)**", output)
        self.assertIn("\tDescription\n\t\tPrint a message.", output)
        self.assertIn("\tReturn\n\t\tThe number of bytes written.", output)

        self.assertIn("**u64 bpf_ktime_get_ns(void)**", output)

        self.assertIn("EXAMPLES\n========", output)

    @patch('sys.argv', ['bpf_helpers_doc.py'])
    @patch('bpf_helpers_doc.HeaderParser')
    @patch('bpf_helpers_doc.PrinterRST')
    def test_main_default(self, mock_printer, mock_parser):
        # Mock HeaderParser
        mock_parser_instance = mock_parser.return_value
        mock_parser_instance.helpers = [Helper()]

        # Mock sys.stderr to avoid printing during tests
        with patch('sys.stderr', new=io.StringIO()):
            # We must use patch with args if the file wasn't found in system.
            # We'll patch `os.path.isfile` so it always uses the default path instead.
            with patch('os.path.isfile', return_value=True):
                bpf_helpers_doc.main()

        mock_parser.assert_called_once()
        mock_parser_instance.run.assert_called_once()
        mock_printer.assert_called_once_with(mock_parser_instance.helpers)
        mock_printer.return_value.print_all.assert_called_once()

    @patch('sys.argv', ['bpf_helpers_doc.py', '--filename', 'custom.h'])
    @patch('bpf_helpers_doc.HeaderParser')
    @patch('bpf_helpers_doc.PrinterRST')
    def test_main_with_filename(self, mock_printer, mock_parser):
        # Mock HeaderParser
        mock_parser_instance = mock_parser.return_value
        mock_parser_instance.helpers = [Helper()]

        # Mock sys.stderr
        with patch('sys.stderr', new=io.StringIO()):
            bpf_helpers_doc.main()

        mock_parser.assert_called_once_with('custom.h')

if __name__ == '__main__':
    unittest.main()

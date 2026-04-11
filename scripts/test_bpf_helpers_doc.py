import unittest
import sys
import os
import tempfile

# Add scripts directory to sys.path to import bpf_helpers_doc
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import bpf_helpers_doc
from bpf_helpers_doc import Helper, HeaderParser

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


if __name__ == '__main__':
    unittest.main()

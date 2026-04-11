import unittest
import os
import tempfile
import kernel_headers

class TestKernelHeaders(unittest.TestCase):
    def test_headers_diff_no_diff(self):
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f1:
            f1.write('gen_headers_out_arm = [\n"foo.h",\n"bar.h",\n]\n')
            f1_name = f1.name
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f2:
            f2.write('gen_headers_out_arm = [\n"foo.h",\n"bar.h",\n]\n')
            f2_name = f2.name

        try:
            self.assertFalse(kernel_headers.headers_diff(f1_name, f2_name))
        finally:
            os.remove(f1_name)
            os.remove(f2_name)

    def test_headers_diff_with_diff(self):
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f1:
            f1.write('gen_headers_out_arm = [\n"foo.h",\n"bar.h",\n]\n')
            f1_name = f1.name
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f2:
            f2.write('gen_headers_out_arm = [\n"foo.h",\n]\n')
            f2_name = f2.name

        try:
            self.assertTrue(kernel_headers.headers_diff(f1_name, f2_name))
        finally:
            os.remove(f1_name)
            os.remove(f2_name)

    def test_parse_bp_for_headers(self):
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
            f.write('gen_headers_out_arm = [\n')
            f.write('    "foo.h",\n')
            f.write('    "bar.h",\n')
            f.write(']\n')
            f_name = f.name

        try:
            headers = set()
            kernel_headers.parse_bp_for_headers(f_name, headers)
            self.assertEqual(headers, {"foo.h", "bar.h"})
        finally:
            os.remove(f_name)

    def test_gen_version_h(self):
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as makefile:
            makefile.write("VERSION = 4\nPATCHLEVEL = 14\nSUBLEVEL = 117\n")
            makefile_name = makefile.name

        with tempfile.TemporaryDirectory() as gen_dir:
            os.makedirs(os.path.join(gen_dir, 'linux'))
            result = kernel_headers.gen_version_h(False, gen_dir, makefile_name)
            self.assertTrue(result)

            with open(os.path.join(gen_dir, 'linux', 'version.h'), 'r') as f:
                content = f.read()
                self.assertIn("#define LINUX_VERSION_CODE", content)
                self.assertIn("#define KERNEL_VERSION(a,b,c)", content)

        os.remove(makefile_name)

    def test_scan_arch_kbuild(self):
        with tempfile.NamedTemporaryFile(mode='w', delete=False) as arch_kbuild:
            arch_kbuild.write("generated-y += generated1.h\n")
            arch_kbuild.write("generic-y += generic1.h\n")
            arch_kbuild_name = arch_kbuild.name

        with tempfile.NamedTemporaryFile(mode='w', delete=False) as asm_generic_kbuild:
            asm_generic_kbuild.write("mandatory-y += mandatory1.h\n")
            asm_generic_kbuild.write("mandatory-y += generated1.h\n") # overlap, should be filtered out from mandatory
            asm_generic_kbuild_name = asm_generic_kbuild.name

        try:
            generated, generic, mandatory = kernel_headers.scan_arch_kbuild(
                False, arch_kbuild_name, asm_generic_kbuild_name, ["path/to/uapi1.h"]
            )
            self.assertEqual(generated, ["generated1.h"])
            self.assertEqual(generic, ["generic1.h"])
            self.assertEqual(mandatory, ["mandatory1.h"])
        finally:
            os.remove(arch_kbuild_name)
            os.remove(asm_generic_kbuild_name)

if __name__ == '__main__':
    unittest.main()

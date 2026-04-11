import unittest
import os
import sys
import tempfile

# Add scripts directory to path to import checkkconfigsymbols
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import checkkconfigsymbols


class TestCheckKconfigSymbols(unittest.TestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def create_temp_file(self, filename, content):
        filepath = os.path.join(self.temp_dir.name, filename)
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        return filepath

    def test_partition(self):
        # Test partitioning an empty list
        self.assertEqual(checkkconfigsymbols.partition([], 3), [[], [], []])

        # Test partitioning a list with length less than size
        self.assertEqual(checkkconfigsymbols.partition([1, 2], 3), [[1], [2], []])

        # Test partitioning a list with length equal to size
        self.assertEqual(checkkconfigsymbols.partition([1, 2, 3], 3), [[1], [2], [3]])

        # Test partitioning a list with length greater than size
        self.assertEqual(checkkconfigsymbols.partition([1, 2, 3, 4, 5], 2), [[1, 3, 5], [2, 4]])
        self.assertEqual(checkkconfigsymbols.partition([1, 2, 3, 4, 5], 3), [[1, 4], [2, 5], [3]])

    def test_get_symbols_in_line(self):
        # Test empty line
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line(""), [])

        # Test line without symbols
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line("if A == B"), [])

        # Test line with single symbol
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line("if CONFIG_FOO_BAR"), ["CONFIG_FOO_BAR"])

        # Test line with multiple symbols
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line("if CONFIG_FOO && CONFIG_BAR"), ["CONFIG_FOO", "CONFIG_BAR"])
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line("select SYM_A if SYM_B"), ["SYM_A", "SYM_B"])

        # Test lowercase ignored
        self.assertEqual(checkkconfigsymbols.get_symbols_in_line("if abc && SYM_A"), ["SYM_A"])

    def test_yel(self):
        # Save original color setting
        orig_color = getattr(checkkconfigsymbols, 'COLOR', False)

        try:
            # Test without color
            checkkconfigsymbols.COLOR = False
            self.assertEqual(checkkconfigsymbols.yel("test string"), "test string")

            # Test with color
            checkkconfigsymbols.COLOR = True
            self.assertEqual(checkkconfigsymbols.yel("test string"), "\033[33mtest string\033[0m")
        finally:
            checkkconfigsymbols.COLOR = orig_color

    def test_red(self):
        # Save original color setting
        orig_color = getattr(checkkconfigsymbols, 'COLOR', False)

        try:
            # Test without color
            checkkconfigsymbols.COLOR = False
            self.assertEqual(checkkconfigsymbols.red("test string"), "test string")

            # Test with color
            checkkconfigsymbols.COLOR = True
            self.assertEqual(checkkconfigsymbols.red("test string"), "\033[31mtest string\033[0m")
        finally:
            checkkconfigsymbols.COLOR = orig_color

    def test_parse_source_file(self):
        content = '''
        int main() {
            #ifdef CONFIG_VALID_SYMBOL
            // some code
            #endif

            int x = CONFIG_ANOTHER_SYMBOL;
        }
        '''
        filepath = self.create_temp_file("test.c", content)

        references = checkkconfigsymbols.parse_source_file(filepath)
        self.assertIn("VALID_SYMBOL", references)
        self.assertIn("ANOTHER_SYMBOL", references)

        # Missing file should return empty list
        self.assertEqual(checkkconfigsymbols.parse_source_file("nonexistent.c"), [])

    def test_parse_kconfig_file(self):
        content = '''
config FOO
    bool "Foo support"
    depends on BAR
    select BAZ if QUX
    help
      This is a help text mentioning CONFIG_IGNORED.

config ANOTHER
    int "Another"
    default 5
'''
        filepath = self.create_temp_file("Kconfig", content)

        defined, references = checkkconfigsymbols.parse_kconfig_file(filepath)

        self.assertIn("FOO", defined)
        self.assertIn("ANOTHER", defined)

        self.assertIn("BAR", references)
        self.assertIn("BAZ", references)
        self.assertIn("QUX", references)
        self.assertNotIn("IGNORED", references)

if __name__ == '__main__':
    unittest.main()

from pathlib import Path
import runpy
import unittest

SELECT = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'check-linux-objects.py'))['select_targets']


class LinuxObjectsTests(unittest.TestCase):
    def test_selects_only_changed_app_objects_including_new_files(self):
        changed = ['Telegram/SourceFiles/core/new.cpp', 'Telegram/SourceFiles/apiwrap.cpp',
                   'Telegram/SourceFiles/core/new.h', 'Telegram/SourceFiles/tests/xxxgram_policy_tests.cpp']
        objects = ['Telegram/CMakeFiles/Telegram.dir/Debug/SourceFiles/core/new.cpp.o',
                   'Telegram/CMakeFiles/Telegram.dir/Debug/SourceFiles/apiwrap.cpp.o']
        listing = '\n'.join(x + ': CXX_COMPILER' for x in objects + [
            'Telegram/CMakeFiles/Telegram.dir/Debug/SourceFiles/unrelated.cpp.o'])
        self.assertEqual(SELECT(changed, listing), sorted(objects))

    def test_missing_or_ambiguous_target_is_not_a_green_check(self):
        changed = ['Telegram/SourceFiles/core/new.cpp']
        with self.assertRaises(ValueError):
            SELECT(changed, '')
        with self.assertRaises(ValueError):
            SELECT(changed, 'a/SourceFiles/core/new.cpp.o: CXX\nb/SourceFiles/core/new.cpp.o: CXX')
        with self.assertRaises(ValueError):
            SELECT(['Telegram/SourceFiles/core/new.h'], '')


if __name__ == '__main__':
    unittest.main()

"""Regression tests for NixOS host path patching."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'nix'))
from importlib.machinery import SourceFileLoader
import importlib.util
spec = importlib.util.spec_from_loader('patch_host', SourceFileLoader('patch_host', str(Path(__file__).resolve().parents[1] / 'nix' / 'patch-host.py')))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

NIX_PATHS = {
    'DL_OUT': '/nix/store/host',
    'DL_ANDROID': '/nix/store/android/usr/lib/droidloom',
    'DL_RUNTIME': '/nix/store/runtime/usr/share/droidloom',
    'DL_RUNTIME_LIB': '/nix/store/runtime/usr/lib/droidloom',
    'DL_SYSTEMCTL': '/run/current-system/sw/bin/systemctl',
    'DL_SYSTEMD_RUN': '/run/current-system/sw/bin/systemd-run',
    'DL_GETENT': '/run/current-system/sw/bin/getent',
    'DL_RUNUSER': '/run/current-system/sw/bin/runuser',
    'DL_ENV': '/run/current-system/sw/bin/env',
    'DL_ADB': '/run/current-system/sw/bin/adb',
    'DL_PKEXEC': '/run/current-system/sw/bin/pkexec',
    'DL_TIMEOUT': '/run/current-system/sw/bin/timeout',
    'DL_IP': '/run/current-system/sw/bin/ip',
}

class TestPatch(unittest.TestCase):
    def test_wayland_protocol_code_is_unchanged(self):
        source = '''
let output_power_manager: ZwlrOutputPowerManagerV1 = globals.bind(&qh, 1..=1, ())?;
'''
        self.assertEqual(
            mod.patch_paths(source, mod.path_replacements(NIX_PATHS)),
            source,
        )

    def test_runtime_package_helper_uses_runtime_payload(self):
        source = (
            'const HELPER: &str = "/usr/lib/droidloom/droidloom-package-helper";\n'
            'const IMAGE: &str = "/usr/lib/droidloom/images/images/system.img";\n'
        )
        patched = mod.patch_paths(source, mod.path_replacements(NIX_PATHS))
        self.assertIn(NIX_PATHS['DL_RUNTIME_LIB'] + '/droidloom-package-helper', patched)
        self.assertIn(NIX_PATHS['DL_ANDROID'] + '/images/images/system.img', patched)

    def test_systemd_run_uses_nix_path(self):
        source = 'Command::new("/usr/bin/systemd-run");'
        patched = mod.patch_paths(source, mod.path_replacements(NIX_PATHS))
        self.assertIn(NIX_PATHS['DL_SYSTEMD_RUN'], patched)
        self.assertNotIn('/usr/bin/systemd-run', patched)

if __name__ == '__main__':
    unittest.main()

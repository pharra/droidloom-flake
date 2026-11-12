"""Regression tests for the checked upstream Wayland protocol rewrite."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'nix'))
from importlib.machinery import SourceFileLoader
import importlib.util
spec = importlib.util.spec_from_loader('patch_host', SourceFileLoader('patch_host', str(Path(__file__).resolve().parents[1] / 'nix' / 'patch-host.py')))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

FIXTURE = '''
struct App {
    output_power_manager: ZwlrOutputPowerManagerV1,
}
    fn new_output(&mut self) {
        let control = self
            .output_power_manager
            .get_output_power(&output, qh, output.clone());
        self.output_power.push(OutputPowerState {
            output,
            control: Some(control),
            powered: None,
        });
    }
let viewporter: WpViewporter = globals.bind(&qh, 1..=1, ())?;
let fractional_scale_manager: WpFractionalScaleManagerV1 = globals.bind(&qh, 1..=1, ())?;
let sync_manager: WpLinuxDrmSyncobjManagerV1 = globals.bind(&qh, 1..=1, ())?;
let output_power_manager: ZwlrOutputPowerManagerV1 = globals.bind(&qh, 1..=1, ())?;
'''

class TestPatch(unittest.TestCase):
    def test_optional_output_power(self):
        patched = mod.patch_presenter(FIXTURE)
        self.assertIn('Option<ZwlrOutputPowerManagerV1>', patched)
        self.assertIn('Some(true)', patched)
        self.assertIn('missing required wp_fractional_scale_manager_v1', patched)
        self.assertIn('missing required wp_linux_drm_syncobj_manager_v1', patched)

    def test_fail_closed_on_upstream_change(self):
        with self.assertRaisesRegex(RuntimeError, 'expected exactly one upstream match'):
            mod.patch_presenter(FIXTURE.replace('output_power_manager: ZwlrOutputPowerManagerV1,', 'output_power_manager: bool,'))

    def test_runtime_package_helper_uses_runtime_payload(self):
        paths = {
            'DL_OUT': '/nix/store/host',
            'DL_ANDROID': '/nix/store/android/usr/lib/droidloom',
            'DL_RUNTIME': '/nix/store/runtime/usr/share/droidloom',
            'DL_RUNTIME_LIB': '/nix/store/runtime/usr/lib/droidloom',
            'DL_SYSTEMCTL': '/run/current-system/sw/bin/systemctl',
            'DL_GETENT': '/run/current-system/sw/bin/getent',
            'DL_RUNUSER': '/run/current-system/sw/bin/runuser',
            'DL_ENV': '/run/current-system/sw/bin/env',
            'DL_ADB': '/run/current-system/sw/bin/adb',
            'DL_PKEXEC': '/run/current-system/sw/bin/pkexec',
            'DL_TIMEOUT': '/run/current-system/sw/bin/timeout',
            'DL_IP': '/run/current-system/sw/bin/ip',
        }
        source = (
            'const HELPER: &str = "/usr/lib/droidloom/droidloom-package-helper";\n'
            'const IMAGE: &str = "/usr/lib/droidloom/images/images/system.img";\n'
        )
        patched = mod.patch_paths(source, mod.path_replacements(paths))
        self.assertIn(paths['DL_RUNTIME_LIB'] + '/droidloom-package-helper', patched)
        self.assertIn(paths['DL_ANDROID'] + '/images/images/system.img', patched)

if __name__ == '__main__':
    unittest.main()

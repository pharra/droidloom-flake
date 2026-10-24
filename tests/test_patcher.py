"""Regression tests for the checked upstream Wayland protocol rewrite."""
import os
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

if __name__ == '__main__':
    unittest.main()

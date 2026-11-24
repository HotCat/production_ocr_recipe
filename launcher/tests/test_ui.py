import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from PySide6.QtWidgets import QApplication, QCheckBox, QComboBox, QLineEdit, QMessageBox, QPushButton, QSpinBox

from launcher.config import ConfigStore
from launcher.processes import ProcessManager
from launcher.ui import LauncherWindow


class LauncherUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.production_env = patch.dict(os.environ, OCR_PRODUCTION_LOG_DIR=str(self.root / 'production'))
        self.production_env.start()
        self.addCleanup(self.production_env.stop)
        self.store = ConfigStore(self.root / 'config.json')
        self.store.load()
        self.manager = ProcessManager(self.root / 'state')
        self.window = LauncherWindow(self.store, self.manager)
        self.window.show()
        self.app.processEvents()

    def tearDown(self):
        (self.root / 'stop').touch()
        deadline = time.monotonic() + 8
        while any(self.manager.status(p.get('instance_key', p['id']))['running'] for p in self.window.config['programs']):
            self.app.processEvents()
            if time.monotonic() > deadline:
                self.fail('Test process did not stop')
            time.sleep(.02)
        with patch.object(QMessageBox, 'question', return_value=QMessageBox.StandardButton.Discard):
            self.window.close()
        self.window.deleteLater()
        self.app.processEvents()
        self.temporary.cleanup()

    def test_five_programs_inspector_and_independent_saved_settings(self):
        self.assertEqual(self.window.program_list.topLevelItemCount(), 5)
        self.assertIsInstance(self.window.editors['camera'], QComboBox)
        self.assertIsInstance(self.window.editors['modbus_host'], QLineEdit)
        self.window.editors['modbus_host'].setText('10.0.0.10')
        second = self.window.program_list.topLevelItem(1)
        self.window.program_list.setCurrentItem(second)
        self.assertEqual(self.window.editors['modbus_host'].text(), '192.168.0.68')
        self.window.program_list.setCurrentItem(self.window.program_list.topLevelItem(0))
        self.assertEqual(self.window.editors['modbus_host'].text(), '10.0.0.10')
        self.window.save_button.click()
        self.assertEqual(ConfigStore(self.store.path).load()['programs'][0]['values']['modbus_host'], '10.0.0.10')
        texts = {button.text() for button in self.window.findChildren(QPushButton)}
        self.assertFalse(any(word in text for word in ['添加', '删除', '移除'] for text in texts))

    def test_reload_program_list_and_new_parameter_types_from_configuration_only(self):
        config = copy.deepcopy(self.store.data)
        config['programs'] = config['programs'][:1]
        config['cameras'].append('Hikvision 2')
        config['parameters']['guard'] = {'label': '印字保护', 'type': 'boolean', 'default': True}
        config['parameters']['attempts'] = {'label': '重试次数', 'type': 'integer', 'default': 3, 'minimum': 0, 'maximum': 10}
        config['programs'][0]['parameters'].update(guard='GUARD', attempts='ATTEMPTS')
        self.store.path.write_text(json.dumps(config, ensure_ascii=False))
        self.window.reload_button.click()
        self.assertEqual(self.window.program_list.topLevelItemCount(), 1)
        self.assertEqual([self.window.editors['camera'].itemText(i)
                          for i in range(self.window.editors['camera'].count())], config['cameras'])
        self.assertIsInstance(self.window.editors['guard'], QCheckBox)
        self.assertIsInstance(self.window.editors['attempts'], QSpinBox)
        self.window.editors['camera'].setCurrentText('Hikvision 2')
        self.window.editors['guard'].setChecked(False)
        self.window.save_button.click()
        values = ConfigStore(self.store.path).load()['programs'][0]['values']
        self.assertEqual(values['camera'], 'Hikvision 2')
        self.assertFalse(values['guard'])
        config['programs'] = []
        self.store.path.write_text(json.dumps(config))
        self.window.reload_button.click()
        self.assertFalse(self.window.launch_button.isEnabled())
        self.assertFalse(self.window.save_button.isEnabled())

    def test_debug_config_reload_and_save_preserve_flag(self):
        self.assertNotIn('调试模式', self.window.identity_label.text())
        config = copy.deepcopy(self.store.data)
        config['debug_mode'] = True
        self.store.path.write_text(json.dumps(config, ensure_ascii=False))
        self.window.reload_button.click()
        self.assertIn('调试模式', self.window.identity_label.text())
        self.assertNotIn('debug_mode', self.window.editors)
        self.window.editors['modbus_host'].setText('10.0.0.20')
        self.window.save_button.click()
        self.assertIs(ConfigStore(self.store.path).load()['debug_mode'], True)

    def test_invalid_ip_blocks_launch_and_preserves_file(self):
        original = self.store.path.read_bytes()
        self.window.editors['modbus_host'].setText('300.0.0.1')
        with patch.object(QMessageBox, 'warning') as warning, patch.object(self.manager, 'launch') as launch:
            self.window.launch_button.click()
            warning.assert_called_once()
            launch.assert_not_called()
        self.assertEqual(self.store.path.read_bytes(), original)

    def test_angle_classifier_stays_out_of_inspector_and_survives_save(self):
        config = copy.deepcopy(self.store.data)
        config['programs'][0]['use_angle_cls'] = True
        self.store.path.write_text(json.dumps(config, ensure_ascii=False))
        self.window.reload_button.click()
        self.assertNotIn('use_angle_cls', self.window.editors)
        self.window.editors['modbus_host'].setText('10.0.0.20')
        self.window.save_button.click()
        self.assertIs(ConfigStore(self.store.path).load()['programs'][0]['use_angle_cls'], True)

    def test_running_program_disables_launch_and_reenables_after_close(self):
        program = self.window.config['programs'][0]
        stop = self.root / 'stop'
        script = self.root / 'worker.py'
        script.write_text('import time,sys,os\nfrom pathlib import Path\nprint(os.environ["BARCODE_SEQUENCE_MODBUS_HOST"],flush=True)\nwhile not Path(sys.argv[1]).exists():time.sleep(.02)\n')
        program.update(command=[sys.executable, '-u', str(script), str(stop)], cwd=str(self.root))
        self.window.editors['modbus_host'].setText('10.4.5.6')
        self.window.launch_button.click()
        self.assertFalse(self.window.launch_button.isEnabled())
        self.assertFalse(self.window.editors['camera'].isEnabled())
        self.assertFalse(self.window.save_button.isEnabled())
        deadline = time.monotonic() + 8
        while '10.4.5.6' not in self.manager.log_tail(program['instance_key']):
            self.app.processEvents()
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.02)
        stop.touch()
        while self.manager.status(program['instance_key'])['running']:
            self.app.processEvents()
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.02)
        self.window.refresh_status()
        self.assertTrue(self.window.launch_button.isEnabled())
        self.assertTrue(self.window.editors['camera'].isEnabled())
        self.assertIn('10.4.5.6', self.window.log_view.toPlainText())


if __name__ == '__main__':
    unittest.main()

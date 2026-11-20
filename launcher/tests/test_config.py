import copy
import json
from pathlib import Path
import tempfile
import unittest

from launcher.config import ConfigStore, launch_spec, validate_config


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'settings/config.json'
        self.store = ConfigStore(self.path)
        self.config = self.store.load()

    def test_defaults_and_independent_per_program_values(self):
        self.assertEqual(len(self.config['programs']), 5)
        first, second = self.config['programs'][:2]
        first['values']['modbus_host'] = '10.20.30.40'
        self.store.update(self.config)
        restored = ConfigStore(self.path).load()
        self.assertEqual(restored['programs'][0]['values']['modbus_host'], '10.20.30.40')
        self.assertEqual(restored['programs'][1]['values']['modbus_host'], '192.168.0.68')
        for program in restored['programs']:
            spec = launch_spec(restored, program, Path('/a repo with spaces'))
            self.assertEqual(spec['command'], ['/a repo with spaces/scripts/run-app.sh', program['id']])
            for key, variable in program['parameters'].items():
                self.assertEqual(spec['environment'][variable], str(program['values'][key]))

    def test_new_parameters_and_camera_names_are_data_not_shell_code(self):
        config = copy.deepcopy(self.config)
        camera = 'Hikvision A; $(touch NEVER) {braces}'
        config['cameras'].append(camera)
        program = config['programs'][0]
        program['values']['camera'] = camera
        config['parameters']['endpoint'] = {'label': 'OCR endpoint', 'type': 'string', 'default': 'tcp://127.0.0.1:5555'}
        config['parameters']['enabled'] = {'label': 'Guard', 'type': 'boolean', 'default': False}
        config['parameters']['mode'] = {'label': 'Mode', 'type': 'choice', 'choices': ['A', 'B'], 'default': 'B'}
        program['parameters'].update(endpoint='PADDLEOCR_ENDPOINT', enabled='GUARD', mode='MODE')
        program['command'] += ['--camera', '{camera}', '--guard={enabled}']
        validate_config(config)
        spec = launch_spec(config, program)
        self.assertEqual(spec['command'][-2:], [camera, '--guard=0'])
        self.assertEqual(spec['environment']['SEQUENCE_OCR_CAMERA'], camera)
        self.assertEqual(spec['environment']['GUARD'], '0')
        self.assertEqual(spec['environment']['MODE'], 'B')

    def test_debug_flag_is_config_only_strict_and_authoritative(self):
        self.assertIs(self.config['debug_mode'], False)
        for enabled in (False, True):
            config = copy.deepcopy(self.config)
            config['debug_mode'] = enabled
            for program in config['programs']:
                program['environment'] = {'OCR_DEBUG_MODE': '0' if enabled else '1'}
                self.assertEqual(launch_spec(config, program)['environment']['OCR_DEBUG_MODE'], '1' if enabled else '0')
            self.store.update(config)
            self.assertIs(ConfigStore(self.path).load()['debug_mode'], enabled)
        legacy = copy.deepcopy(self.config)
        legacy.pop('debug_mode')
        validate_config(legacy)
        self.assertEqual(launch_spec(legacy, legacy['programs'][0])['environment']['OCR_DEBUG_MODE'], '0')
        for invalid in ('true', 'false', 0, 1, None, []):
            config = copy.deepcopy(self.config)
            config['debug_mode'] = invalid
            with self.assertRaisesRegex(ValueError, 'debug_mode'):
                validate_config(config)
            with self.assertRaisesRegex(ValueError, 'debug_mode'):
                launch_spec(config, config['programs'][0])

    def test_invalid_addresses_do_not_replace_saved_configuration(self):
        before = self.path.read_bytes()
        for address in ['', '192.168.1.999', '127.0.0.1;echo invalid', 'localhost']:
            config = copy.deepcopy(self.config)
            config['programs'][0]['values']['modbus_host'] = address
            with self.assertRaises(ValueError):
                self.store.update(config)
            self.assertEqual(self.path.read_bytes(), before)

    def test_external_program_list_edits_are_not_overwritten(self):
        config = copy.deepcopy(self.config)
        config['programs'].pop()
        self.path.write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError, '外部修改'):
            self.store.update(self.config)
        self.assertEqual(len(ConfigStore(self.path).load()['programs']), 4)

    def test_empty_program_list_valid_and_malformed_file_preserved(self):
        config = copy.deepcopy(self.config)
        config['programs'] = []
        self.store.update(config)
        self.assertEqual(ConfigStore(self.path).load()['programs'], [])
        self.path.write_text('{broken JSON')
        with self.assertRaises(ValueError):
            ConfigStore(self.path).load()
        self.assertEqual(self.path.read_text(), '{broken JSON')

    def test_bad_templates_and_duplicate_environment_bindings_fail(self):
        program = copy.deepcopy(self.config['programs'][0])
        program['command'].append('{missing}')
        with self.assertRaisesRegex(ValueError, '模板'):
            launch_spec(self.config, program)
        config = copy.deepcopy(self.config)
        config['programs'][0]['parameters']['camera'] = config['programs'][0]['parameters']['modbus_host']
        with self.assertRaisesRegex(ValueError, '同一环境变量'):
            validate_config(config)


if __name__ == '__main__':
    unittest.main()

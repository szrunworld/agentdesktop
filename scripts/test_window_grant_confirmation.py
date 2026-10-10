import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'confirmation', Path(__file__).with_name('window-grant-confirmation.py'))
confirmation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(confirmation)
UNKNOWN = {'ok': False, 'error': {'code': 'request_acceptance_unknown'}}


class ConfirmationTests(unittest.TestCase):
    def exercise(self, replies, *, clock=lambda: 0):
        calls = []
        replies = iter(replies)

        def run(args):
            calls.append(args)
            return next(replies)

        result = confirmation.confirm('fake', ['windows', 'request'],
                                      run=run, clock=clock, sleep=lambda _: None)
        self.assertTrue(all(c[:2] == ['request', 'show'] for c in calls[1:]))
        self.assertTrue(all(c[2] == calls[0][-1] for c in calls[1:]))
        return result, calls

    def test_completed_and_failed_outcomes(self):
        for state, outcome in [('completed', {'data': {'windowGrantId': 'wg_test'}}),
                               ('failed', {'error': {'code': 'user_denied'}})]:
            with self.subTest(state=state):
                result, calls = self.exercise([UNKNOWN,
                    {'ok': True, 'data': {'state': 'accepted'}},
                    {'ok': True, 'data': {'state': state, 'outcome': outcome}}])
                self.assertEqual(result['ok'], state == 'completed')
                self.assertEqual(len(calls), 3)

    def test_direct_replies_do_not_poll(self):
        for reply in [{'ok': True, 'data': {}},
                      {'ok': False, 'error': {'code': 'user_denied'}},
                      {'ok': False, 'error': {'code': 'window_grant_cooldown'}}]:
            result, calls = self.exercise([reply])
            self.assertEqual(result, reply)
            self.assertEqual(len(calls), 1)

    def test_unknown_timeout_does_not_resubmit(self):
        ticks = iter([0, 1, 200])
        result, calls = self.exercise([UNKNOWN, UNKNOWN], clock=lambda: next(ticks))
        self.assertEqual(result['error']['code'], 'request_acceptance_unknown')
        self.assertEqual(len(calls), 2)

    def test_malformed_terminal_result_fails(self):
        with self.assertRaises(ValueError):
            self.exercise([UNKNOWN, {'ok': True, 'data': {'state': 'completed'}}])


if __name__ == '__main__':
    unittest.main()

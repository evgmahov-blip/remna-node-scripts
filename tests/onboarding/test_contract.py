"""Offline consistency checks; these do not attest production acceptance."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CanadaContractTests(unittest.TestCase):
    def test_canada_target_and_isolation(self):
        c = json.loads((ROOT / 'onboarding/can-next.json').read_text())
        self.assertEqual(c['node']['address'], '31.59.156.28')
        self.assertEqual(c['dns'], dict(type='A', name=c['node']['domain'],
                                       content=c['node']['address'], proxied=False, ttl=300))
        self.assertEqual(c['host']['address'], c['dns']['name'])
        self.assertEqual(c['host']['port'], c['transport']['port'])
        self.assertEqual(c['transport'], dict(protocol='vless', network='xhttp',
                                              security='reality', port=443))
        self.assertIsNone(c['host']['mapper'])
        self.assertIsNone(c['host']['xray_json_template'])
        self.assertEqual(c['api']['port'], 2222)
        self.assertEqual(c['api']['allowed_source'], 'panel-only')
        self.assertIsNone(c['api']['panel_ip'])
        self.assertEqual(set(c['internal_squads']), {'Svistunov', 'All'})
        self.assertEqual(set(c['protected_nodes']), {'PL', 'GER5'})
        self.assertEqual(len(c['required_evidence']), len(set(c['required_evidence'])))
        for check in ('backup', 'rollback', 'reality_client', 'api_panel_allowed',
                      'api_external_denied_ipv4', 'api_external_denied_ipv6',
                      'subscription_svistunov', 'subscription_all',
                      'independent_review_approved', 'exact_git_release',
                      'trusted_activation_used', 'materialized_production_tree_verified'):
            self.assertIn(check, c['required_evidence'])


if __name__ == '__main__':
    unittest.main()

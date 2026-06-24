"""Unit tests for the billing kill-switch.

These tests mock the Cloud Billing discovery client and feed fake base64
Pub/Sub events. They assert:
  - detach IS called when cost >= budget
  - detach is NOT called when cost < budget
  - detach is NOT called (idempotent no-op) when billing already disabled

The shipped main.py uses no mocks; only this test file does.
"""

import base64
import json
import unittest
from unittest import mock

import main


def make_event(cost, budget, name="test-budget", currency="USD"):
    """Build a fake Pub/Sub event: base64-encoded JSON in event['data']."""
    payload = {
        "costAmount": cost,
        "budgetAmount": budget,
        "budgetDisplayName": name,
        "currencyCode": currency,
    }
    encoded = base64.b64encode(json.dumps(payload).encode("utf-8"))
    return {"data": encoded}


class FakeBillingClient:
    """Records getBillingInfo / updateBillingInfo calls.

    `enabled` drives what getBillingInfo reports for billingEnabled.
    """

    def __init__(self, enabled=True):
        self._enabled = enabled
        self.get_calls = []
        self.update_calls = []

    def projects(self):
        return self

    def getBillingInfo(self, name):  # noqa: N802 (GCP API casing)
        self.get_calls.append(name)
        result = {"billingEnabled": self._enabled, "name": name}
        return _Executable(result)

    def updateBillingInfo(self, name, body):  # noqa: N802 (GCP API casing)
        self.update_calls.append((name, body))
        return _Executable({"name": name, "billingAccountName": body.get("billingAccountName")})


class _Executable:
    def __init__(self, result):
        self._result = result

    def execute(self):
        return self._result


class StopBillingTest(unittest.TestCase):
    def setUp(self):
        # Pin the resolved project so assertions are deterministic regardless of
        # the host environment.
        self._env_patch = mock.patch.dict(
            "os.environ", {"GCP_PROJECT": "heimdall-cp-prod"}, clear=False
        )
        self._env_patch.start()

    def tearDown(self):
        self._env_patch.stop()

    def test_detach_called_when_cost_exceeds_budget(self):
        fake = FakeBillingClient(enabled=True)
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing(make_event(cost=100.0, budget=50.0), None)
        self.assertEqual(len(fake.update_calls), 1, "detach must be called once")
        name, body = fake.update_calls[0]
        self.assertEqual(name, "projects/heimdall-cp-prod")
        self.assertEqual(
            body, {"billingAccountName": ""}, "detach must send empty billingAccountName"
        )

    def test_detach_called_when_cost_equals_budget(self):
        fake = FakeBillingClient(enabled=True)
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing(make_event(cost=50.0, budget=50.0), None)
        self.assertEqual(
            len(fake.update_calls), 1, "cost == budget is the 100% kill ping"
        )

    def test_detach_not_called_when_cost_below_budget(self):
        fake = FakeBillingClient(enabled=True)
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing(make_event(cost=25.0, budget=50.0), None)
        self.assertEqual(
            len(fake.update_calls), 0, "under-threshold ping must not detach"
        )
        # The client should not even be built/queried below threshold.
        self.assertEqual(len(fake.get_calls), 0)

    def test_idempotent_when_billing_already_disabled(self):
        fake = FakeBillingClient(enabled=False)
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing(make_event(cost=100.0, budget=50.0), None)
        self.assertEqual(len(fake.get_calls), 1, "must check billingEnabled first")
        self.assertEqual(
            len(fake.update_calls), 0, "already-disabled must be a no-op (idempotent)"
        )

    def test_malformed_data_does_not_detach(self):
        fake = FakeBillingClient(enabled=True)
        bad_event = {"data": base64.b64encode(b"not json")}
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing(bad_event, None)
        self.assertEqual(len(fake.update_calls), 0)

    def test_missing_data_does_not_detach(self):
        fake = FakeBillingClient(enabled=True)
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing({}, None)
        self.assertEqual(len(fake.update_calls), 0)

    def test_missing_amounts_does_not_detach(self):
        fake = FakeBillingClient(enabled=True)
        encoded = base64.b64encode(
            json.dumps({"budgetDisplayName": "x"}).encode("utf-8")
        )
        with mock.patch.object(main, "_build_billing_client", return_value=fake):
            main.stop_billing({"data": encoded}, None)
        self.assertEqual(len(fake.update_calls), 0)


if __name__ == "__main__":
    unittest.main()

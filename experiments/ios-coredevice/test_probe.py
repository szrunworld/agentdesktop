"""Unit tests for probe.py's matrix logic, on synthetic probe results (no device, no pymobiledevice3).

Run: python3 -m unittest experiments/ios-coredevice/test_probe.py   (from the repo root)
  or python3 -m unittest test_probe                                  (from this directory)
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import probe  # noqa: E402

A = "00008120-000A"
B = "00008120-000B"
ALL_SERVICES = [probe.SVC_SCREENCAPTURE, probe.SVC_DVT, probe.SVC_DISPLAY, probe.SVC_HID_UNIVERSAL,
                probe.SVC_HID_INDIGO, probe.SVC_PASTEBOARD, probe.SVC_DEVICEINFO]


def report(*, usb=(), lockdown=(), native=(), tunnels=None, rsd=None) -> dict:
    return {
        "usbmux": {"ok": True, "result": list(usb)},
        "lockdown": list(lockdown),
        "native_browse": {"ok": True, "result": list(native)},
        "tunneld": ({"address": "127.0.0.1:49151", "running": True, "tunnels": tunnels}
                    if tunnels is not None else {"address": "127.0.0.1:49151", "running": False}),
        "userspace_stack": (True, "pmd_pytcp 0.3.7 importable"),
        "mdns": None,
        "rsd_services": rsd,
    }


def paired_lockdown(udid: str, ios: str) -> dict:
    return {"serial": udid, "product_type": "iPhone15,4", "product_version": ios, "paired": True,
            "developer_mode": True, "ddi_image_type": "Personalized", "ddi_mounted": True}


class OperationsStayUnverified(unittest.TestCase):
    """Codex comment 1: an advertised RSD service must not mark the operation supported."""

    def setUp(self):
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   tunnels={A: [{"interface": "utun5"}]},
                   rsd={"via": "tunneld", "ok": True,
                        "result": [{"udid": A, "os": "18.0", "interface": "utun5", "services": ALL_SERVICES}]})
        self.m = probe.build_matrix(r, A)

    def test_operations_unverified_even_when_every_service_is_advertised(self):
        for key in probe.SERVICE_OPERATIONS:
            self.assertEqual(self.m[key]["status"], probe.UNVERIFIED, key)
            self.assertIn("NOT_RUN", self.m[key]["evidence"], key)
            self.assertIn("advertised", self.m[key]["evidence"], key)

    def test_advertisement_reported_as_its_own_capability(self):
        for key, name in probe.ADVERTISED_SERVICES.items():
            self.assertEqual(self.m[key]["status"], probe.SUPPORTED, key)
            self.assertEqual(self.m[key]["evidence"]["service"], name)
            self.assertEqual(self.m[key]["evidence"]["udid"], A)

    def test_absent_service_is_not_advertised_and_operation_still_unverified(self):
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   rsd={"via": "tunneld", "ok": True,
                        "result": [{"udid": A, "os": "18.0", "services": [probe.SVC_DEVICEINFO]}]})
        m = probe.build_matrix(r, A)
        self.assertEqual(m["service_advertised_hid_universal"]["status"], probe.UNSUPPORTED)
        self.assertEqual(m["hid_universal_tap_drag"]["status"], probe.UNVERIFIED)
        self.assertIn("not advertised", m["hid_universal_tap_drag"]["evidence"])

    def test_no_operation_is_ever_supported(self):
        supported = {k for k, v in self.m.items() if v["status"] == probe.SUPPORTED}
        self.assertFalse(supported & (set(probe.SERVICE_OPERATIONS) |
                                      {"hid_type_ascii", "text_chinese", "hid_input_exercised"}))


class NoCrossDeviceMixing(unittest.TestCase):
    """Codex comment 2: device A's lockdown facts must never be combined with device B's services."""

    def setUp(self):
        # A: on USB, paired, iOS 17.5, no tunnel. B: only reachable through tunneld, advertises HID.
        self.r = report(
            usb=[{"serial": A, "connection_type": "USB"}],
            lockdown=[paired_lockdown(A, "17.5")],
            tunnels={B: [{"interface": "utun7"}]},
            rsd={"via": "tunneld", "ok": True, "result": [
                {"udid": B, "os": "18.1", "interface": "utun7", "services": [probe.SVC_HID_UNIVERSAL]}]},
        )

    def test_each_device_gets_its_own_matrix(self):
        probe.attach_matrices(self.r, None)
        self.assertEqual(self.r["devices"], [A, B])
        a = self.r["capabilities_by_device"][A]
        b = self.r["capabilities_by_device"][B]

        self.assertEqual(a["ios_version"]["status"], probe.SUPPORTED)
        self.assertEqual(a["ios_version"]["evidence"]["ios"], "17.5")
        self.assertEqual(a["service_advertised_hid_universal"]["status"], probe.UNVERIFIED)
        self.assertEqual(a["tunnel_tunneld"]["status"], probe.UNVERIFIED)

        self.assertEqual(b["ios_version"]["status"], probe.UNVERIFIED)
        self.assertEqual(b["pairing"]["status"], probe.UNVERIFIED)
        self.assertEqual(b["ddi_mounted"]["status"], probe.UNVERIFIED)
        self.assertEqual(b["discovery_usbmux_usb"]["status"], probe.UNVERIFIED)
        self.assertEqual(b["service_advertised_hid_universal"]["status"], probe.SUPPORTED)
        self.assertEqual(b["service_advertised_hid_universal"]["evidence"]["rsd_entries"],
                         [{"interface": "utun7", "ios": "18.1"}])
        self.assertEqual(b["tunnel_tunneld"]["status"], probe.SUPPORTED)

    def test_top_level_matrix_is_one_selected_udid(self):
        probe.attach_matrices(self.r, None)
        self.assertEqual(self.r["target_udid"], A)
        self.assertIn("--udid", self.r["target_selection"])
        self.assertIs(self.r["capabilities"], self.r["capabilities_by_device"][A])

        probe.attach_matrices(self.r, B)
        self.assertEqual(self.r["target_udid"], B)
        self.assertEqual(self.r["target_selection"], "--udid")
        self.assertIs(self.r["capabilities"], self.r["capabilities_by_device"][B])
        self.assertEqual(self.r["summary"], probe.summarize(self.r["capabilities"]))

    def test_unknown_target_udid_is_all_unverified_on_device_side(self):
        probe.attach_matrices(self.r, "nope")
        m = self.r["capabilities"]
        self.assertEqual(m["ios_version"]["status"], probe.UNVERIFIED)
        self.assertEqual(m["service_advertised_hid_universal"]["status"], probe.UNVERIFIED)


class NoDevice(unittest.TestCase):
    def test_default_run_without_devices(self):
        r = report()
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [])
        self.assertIsNone(r["target_udid"])
        self.assertEqual(r["capabilities_by_device"], {})
        statuses = {k: v["status"] for k, v in r["capabilities"].items()}
        self.assertEqual([k for k, s in statuses.items() if s != probe.UNVERIFIED], ["hid_type_direct_cjk"])

    def test_usbmux_listing_same_device_twice_is_one_device(self):
        r = report(usb=[{"serial": A, "connection_type": "USB"}, {"serial": A, "connection_type": "Network"}],
                   lockdown=[{"serial": A, "error": "timed out"}, paired_lockdown(A, "18.0")])
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A])
        m = r["capabilities"]
        self.assertEqual(m["discovery_usbmux_usb"]["status"], probe.SUPPORTED)
        self.assertEqual(m["discovery_usbmux_network"]["status"], probe.SUPPORTED)
        self.assertEqual(m["ios_version"]["status"], probe.SUPPORTED)


if __name__ == "__main__":
    unittest.main()

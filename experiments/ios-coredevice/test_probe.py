"""Unit tests for probe.py's matrix logic, on synthetic probe results (no device, no pymobiledevice3).

Run: python3 -m unittest experiments/ios-coredevice/test_probe.py   (from the repo root)
  or python3 -m unittest test_probe                                  (from this directory)
"""

from __future__ import annotations

import asyncio
import sys
import types
import unittest
from unittest import mock
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


def via_tunneld(*entries, failed=()) -> dict:
    """rsd_services as probe.rsd_services_via_tunneld() reports it: one entry per opened tunnel key."""
    return {"via": "tunneld", "ok": True, "result": {"entries": list(entries), "failed_tunnels": list(failed)}}


def paired_lockdown(udid: str, ios: str) -> dict:
    return {"serial": udid, "product_type": "iPhone15,4", "product_version": ios, "paired": True,
            "developer_mode": True, "ddi_image_type": "Personalized", "ddi_mounted": True}


class OperationsStayUnverified(unittest.TestCase):
    """Codex comment 1: an advertised RSD service must not mark the operation supported."""

    def setUp(self):
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   tunnels={A: [{"interface": "utun5"}]},
                   rsd=via_tunneld({"tunnel_key": A, "udid": A, "os": "18.0", "interface": "utun5",
                                    "services": ALL_SERVICES}))
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
                   rsd=via_tunneld({"tunnel_key": A, "udid": A, "os": "18.0", "services": [probe.SVC_DEVICEINFO]}))
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
            rsd=via_tunneld({"tunnel_key": B, "udid": B, "os": "18.1", "interface": "utun7",
                             "services": [probe.SVC_HID_UNIVERSAL]}),
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


SKIPPED = "RSD endpoint could not be opened (IndexError: list index out of range)"
REMOTE = "REMOTE-PAIRING-ID-1"


class TunneldDeviceWithUnreachableRsd(unittest.TestCase):
    """Codex comment on #119: tunneld lists a tunnel whose RSD endpoint cannot be opened (upstream
    get_tunneld_devices() skips it). The device must still be reported, with the failed tunnel as evidence."""

    def test_failed_tunnel_still_gets_a_matrix_with_evidence(self):
        # A's RSD opened fine; B is in tunneld's raw map but its RSD could not be opened.
        r = report(tunnels={A: [{"interface": "utun5"}], B: [{"interface": "utun7"}]},
                   rsd=via_tunneld({"tunnel_key": A, "udid": A, "os": "18.0", "interface": "utun5",
                                    "services": ALL_SERVICES},
                                   failed=[{"tunnel_key": B, "error": SKIPPED}]))
        probe.attach_matrices(r, B)
        self.assertEqual(r["devices"], [A, B])
        self.assertEqual(r["tunneld_only_devices"], [B])
        self.assertEqual(r["target_udid"], B)
        self.assertEqual(r["target_selection"], "--udid")
        b = r["capabilities_by_device"][B]
        self.assertIs(r["capabilities"], b)
        self.assertEqual(b["tunnel_tunneld"]["status"], probe.UNSUPPORTED)
        self.assertEqual(b["tunnel_tunneld"]["evidence"]["tunnels"], {B: [{"interface": "utun7"}]})
        self.assertEqual(b["tunnel_tunneld"]["evidence"]["rsd_error"], [{"tunnel_key": B, "error": SKIPPED}])
        self.assertIn("could not be opened", b["tunnel_tunneld"]["reason"])
        self.assertEqual(b["service_advertised_hid_universal"]["status"], probe.UNVERIFIED)
        self.assertIn("tunnel_tunneld", b["service_advertised_hid_universal"]["reason"])
        self.assertEqual(r["capabilities_by_device"][A]["tunnel_tunneld"]["status"], probe.SUPPORTED)

    def test_only_failed_tunnel_is_selected_and_labelled(self):
        r = report(tunnels={B: [{"interface": "utun7"}]},
                   rsd=via_tunneld(failed=[{"tunnel_key": B, "error": SKIPPED}]))
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [B])
        self.assertEqual(r["target_udid"], B)
        self.assertIn("tunneld key", r["target_selection"])
        self.assertEqual(r["capabilities"]["tunnel_tunneld"]["status"], probe.UNSUPPORTED)

    def test_rsd_step_error_is_kept_as_evidence(self):
        r = report(tunnels={B: [{"interface": "utun7"}]},
                   rsd={"via": "tunneld", "ok": False, "result": "timed out after 8.0s"})
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [B])
        t = r["capabilities"]["tunnel_tunneld"]
        self.assertEqual(t["status"], probe.UNSUPPORTED)
        self.assertEqual(t["evidence"]["rsd_error"], "timed out after 8.0s")

    def test_tunnels_ignored_when_tunneld_not_running(self):
        r = report()
        r["tunneld"]["tunnels"] = {B: [{"interface": "utun7"}]}
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [])


class TunneldKeysAreNotUdids(unittest.TestCase):
    """Codex comment on #133: tunneld's map key is its remote identifier and need not equal the UDID
    the RSD reports; one device must not become two matrices."""

    def test_opened_tunnel_under_remote_identifier_is_one_device(self):
        r = report(tunnels={REMOTE: [{"interface": "utun9"}]},
                   rsd=via_tunneld({"tunnel_key": REMOTE, "udid": A, "os": "18.0", "interface": "utun9",
                                    "services": ALL_SERVICES}))
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A])
        self.assertEqual(r["tunneld_only_devices"], [])
        self.assertEqual(r["target_selection"], "only device seen")
        t = r["capabilities"]["tunnel_tunneld"]
        self.assertEqual(t["status"], probe.SUPPORTED)
        self.assertEqual(t["evidence"]["tunnels"], {REMOTE: [{"interface": "utun9"}]})

    def test_failed_remote_identifier_never_outranks_a_real_device(self):
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   tunnels={REMOTE: [{"interface": "utun9"}]},
                   rsd=via_tunneld(failed=[{"tunnel_key": REMOTE, "error": SKIPPED}]))
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A, REMOTE])
        self.assertEqual(r["tunneld_only_devices"], [REMOTE])
        self.assertEqual(r["target_udid"], A)
        self.assertEqual(r["target_selection"], "only device seen")
        self.assertEqual(r["capabilities_by_device"][REMOTE]["tunnel_tunneld"]["status"], probe.UNSUPPORTED)
        self.assertEqual(r["capabilities_by_device"][A]["tunnel_tunneld"]["status"], probe.UNVERIFIED)

    def test_key_matching_usbmux_serial_without_dashes_is_the_same_device(self):
        key = A.replace("-", "")
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   tunnels={key: [{"interface": "utun5"}]},
                   rsd=via_tunneld(failed=[{"tunnel_key": key, "error": SKIPPED}]))
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A])
        self.assertEqual(r["tunneld_only_devices"], [])
        t = r["capabilities"]["tunnel_tunneld"]
        self.assertEqual(t["status"], probe.UNSUPPORTED)
        self.assertEqual(t["evidence"]["rsd_error"], [{"tunnel_key": key, "error": SKIPPED}])


class EquivalentIdSpellings(unittest.TestCase):
    """Codex comment on #133 (round 2): ids that differ only by case/dashes are one device, and every
    source record of that device is attached to its matrix."""

    def test_usbmux_and_remotepairingd_spellings_share_one_matrix(self):
        native_id = A.replace("-", "").lower()
        r = report(usb=[{"serial": A, "connection_type": "USB"}], lockdown=[paired_lockdown(A, "18.0")],
                   native=[{"udid": native_id, "name": "iPhone"}])
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A])
        m = r["capabilities"]
        self.assertEqual(m["discovery_usbmux_usb"]["status"], probe.SUPPORTED)
        self.assertEqual(m["discovery_remotepairingd"]["status"], probe.SUPPORTED)
        self.assertEqual(m["discovery_remotepairingd"]["evidence"], [{"udid": native_id, "name": "iPhone"}])
        self.assertEqual(m["ios_version"]["status"], probe.SUPPORTED)


class RsdViaTunneldPerRecord(unittest.TestCase):
    """rsd_services_via_tunneld() against a mocked RemoteServiceDiscoveryService (no tunneld, no device).
    Codex comment on #133 (round 3): every RSD opened for a multi-tunnel key is recorded and closed."""

    def run_probe(self, tunnels: dict, behaviour: dict):
        """behaviour: tunnel-port -> "ok" | "refuse" | "hang" | "close-raises"."""
        made = []

        class FakeRsd:
            def __init__(self, address, name=None, open_connection=None, auxiliary_metadata=None):
                self.address, self.name, self.closed = address, name, 0
                self.udid, self.product_version, self.peer_info = None, None, None
                made.append(self)

            async def connect(self):
                mode = behaviour[self.address[1]]
                if mode == "refuse":
                    raise ConnectionRefusedError("refused")
                if mode == "hang":
                    await asyncio.sleep(3600)
                self.udid, self.product_version = A, "18.0"
                self.peer_info = {"Services": {f"svc.{self.name}": {}}}

            async def close(self):
                self.closed += 1
                if behaviour[self.address[1]] == "close-raises":
                    raise OSError("already closed")

        rsd_mod = types.ModuleType("pymobiledevice3.remote.remote_service_discovery")
        rsd_mod.RemoteServiceDiscoveryService = FakeRsd
        fake = {"pymobiledevice3": types.ModuleType("pymobiledevice3"),
                "pymobiledevice3.remote": types.ModuleType("pymobiledevice3.remote"),
                "pymobiledevice3.remote.remote_service_discovery": rsd_mod}
        with mock.patch.dict(sys.modules, fake), mock.patch.object(probe, "STEP_TIMEOUT", 0.05):
            ok, res = asyncio.run(probe.rsd_services_via_tunneld(tunnels))
        self.assertTrue(ok)
        return res, made

    @staticmethod
    def record(iface: str, port: int) -> dict:
        return {"interface": iface, "tunnel-address": "fd00::1", "tunnel-port": port}

    def test_two_tunnels_under_one_key_are_both_recorded_and_closed(self):
        res, made = self.run_probe({REMOTE: [self.record("utun5", 1), self.record("utun7", 2)]},
                                   {1: "ok", 2: "ok"})
        self.assertEqual(res["failed_tunnels"], [])
        self.assertEqual([(e["tunnel_key"], e["tunnel_index"], e["interface"], e["services"]) for e in res["entries"]],
                         [(REMOTE, 0, "utun5", ["svc.utun5"]), (REMOTE, 1, "utun7", ["svc.utun7"])])
        self.assertEqual(len(made), 2)
        self.assertEqual([m.closed for m in made], [1, 1])

    def test_failed_and_hung_records_are_kept_and_still_closed(self):
        res, made = self.run_probe({REMOTE: [self.record("utun5", 1), self.record("utun7", 2)],
                                    B: [self.record("utun9", 3), self.record("utun10", 4)]},
                                   {1: "ok", 2: "refuse", 3: "hang", 4: "close-raises"})
        self.assertEqual([(e["tunnel_key"], e["tunnel_index"]) for e in res["entries"]], [(REMOTE, 0), (B, 1)])
        failed = [(f["tunnel_key"], f["tunnel_index"], f["interface"]) for f in res["failed_tunnels"]]
        self.assertEqual(failed, [(REMOTE, 1, "utun7"), (B, 0, "utun9")])
        self.assertIn("ConnectionRefusedError", res["failed_tunnels"][0]["error"])
        self.assertIn("timed out", res["failed_tunnels"][1]["error"])
        self.assertEqual([m.closed for m in made], [1, 1, 1, 1])

    def test_multi_tunnel_key_feeds_one_device_matrix(self):
        res, _ = self.run_probe({REMOTE: [self.record("utun5", 1), self.record("utun7", 2)]}, {1: "ok", 2: "ok"})
        r = report(tunnels={REMOTE: [self.record("utun5", 1), self.record("utun7", 2)]},
                   rsd={"via": "tunneld", "ok": True, "result": res})
        probe.attach_matrices(r, None)
        self.assertEqual(r["devices"], [A])
        self.assertEqual(r["capabilities"]["tunnel_tunneld"]["status"], probe.SUPPORTED)


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

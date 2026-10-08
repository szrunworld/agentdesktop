#!/usr/bin/env python3
"""Read-only CoreDevice / pymobiledevice3 capability probe for an iPhone (test matrix I13).

What it does: asks the host (usbmuxd, remotepairingd, a running tunneld, local pair records) and,
only when a paired device is already reachable, the device's lockdown / RSD service list, which
capabilities exist. It prints one JSON document.

What it never does (by design, not by flag):
  * send any HID event (no tap / drag / swipe / type / button);
  * mount a developer disk image, install anything, enable Developer Mode, or pair
    (lockdown is opened with autopair=False, so no Trust dialog is raised on the phone);
  * start tunneld, run sudo, or open a utun interface;
  * capture a screenshot or start a screen stream (that would read the user's screen).

Opt-in flags (each one is still read-only towards the phone but has a host-side side effect):
  --allow-mdns          send one mDNS query (may raise macOS's Local Network prompt for the
                        terminal app; the office Wi-Fi is also known to block mDNS).
  --allow-native-tunnel if remotepairingd reports a device, borrow Apple's remoted tunnel to read
                        the RSD service list (no root; can briefly evict remoted's own RSD
                        connection, see pymobiledevice3 #1994).

Every capability reports status supported / unsupported / unverified, plus evidence and reason.
"unverified" is used whenever a prerequisite was not reachable -- it is never upgraded to
"supported" by inference (e.g. a working tunnel does not imply working HID input).
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as _dt
import json
import os
import platform
import sys
from pathlib import Path
from typing import Any, Optional

SUPPORTED = "supported"
UNSUPPORTED = "unsupported"
UNVERIFIED = "unverified"

# Service names (from pymobiledevice3 11.x sources, see docs/ios/coredevice-poc.md).
SVC_SCREENCAPTURE = "com.apple.coredevice.screencaptureservice"
SVC_DISPLAY = "com.apple.coredevice.displayservice"
SVC_HID_INDIGO = "com.apple.coredevice.hid.indigo"
SVC_HID_UNIVERSAL = "com.apple.coredevice.hid.universalhidservice"
SVC_PASTEBOARD = "com.apple.coredevice.pasteboardservice"
SVC_DEVICEINFO = "com.apple.coredevice.deviceinfo"
SVC_DVT = "com.apple.instruments.dtservicehub"
SVC_MOUNTER_SHIM = "com.apple.mobile.mobile_image_mounter.shim.remote"
SVC_COREDEVICE_PROXY = "com.apple.internal.devicecompute.CoreDeviceProxy"
LOCKDOWN_SCREENSHOTR = "com.apple.mobile.screenshotr"

STEP_TIMEOUT = 8.0


def cap(status: str, evidence: Any = None, reason: Optional[str] = None, next_step: Optional[str] = None) -> dict:
    out: dict[str, Any] = {"status": status, "evidence": evidence}
    if reason:
        out["reason"] = reason
    if next_step:
        out["next_step_needs_authorization"] = next_step
    return out


def err(e: BaseException) -> str:
    return f"{type(e).__name__}: {e}"


async def guarded(coro, timeout: float = STEP_TIMEOUT):
    """Run one probe step; never let it hang or take the whole report down."""
    try:
        return True, await asyncio.wait_for(coro, timeout)
    except asyncio.TimeoutError:
        return False, f"timed out after {timeout}s"
    except Exception as e:  # noqa: BLE001 -- every failure becomes evidence
        return False, err(e)


# --------------------------------------------------------------------------- host


def host_facts() -> dict:
    try:
        from pymobiledevice3._version import __version__ as pmd_version
    except Exception as e:  # noqa: BLE001
        pmd_version = f"unknown ({err(e)})"
    xcode_apps = sorted(str(p) for p in Path("/Applications").glob("Xcode*.app"))
    # Deliberately do NOT run `xcrun`: without Xcode/CLT it can pop the "install developer tools"
    # dialog. Presence is decided from the filesystem only.
    return {
        "pymobiledevice3": pmd_version,
        "python": platform.python_version(),
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
        "is_root": os.geteuid() == 0,
        "xcode_apps": xcode_apps,
        "command_line_tools": Path("/Library/Developer/CommandLineTools").is_dir(),
        "devicectl_available": bool(xcode_apps),
    }


def pair_record_facts() -> dict:
    home = Path.home() / ".pymobiledevice3"  # read only; do not create it
    own = remote = 0
    if home.is_dir():
        own = len([p for p in home.glob("*.plist") if not p.name.startswith("remote_")])
        remote = len(list(home.glob("remote_*.plist")))
    system = Path("/var/db/lockdown")
    if not system.is_dir():
        system_state = "absent"
    elif not os.access(system, os.R_OK):
        system_state = "present, not readable without root (expected on macOS)"
    else:
        system_state = f"{len(list(system.glob('*.plist')))} record(s)"
    return {"pymobiledevice3_home": str(home), "own_lockdown_records": own,
            "remote_pairing_records": remote, "system_lockdown_store": system_state}


# --------------------------------------------------------------------------- usbmux / lockdown


async def probe_usbmux() -> tuple[bool, Any]:
    from pymobiledevice3 import usbmux

    async def _list():
        devices = await usbmux.list_devices()
        return [{"serial": d.serial, "connection_type": d.connection_type} for d in devices]

    return await guarded(_list())


async def probe_lockdown(serial: str) -> dict:
    """Read-only lockdown facts. autopair=False: an unpaired device is reported, never paired."""
    from pymobiledevice3.lockdown import create_using_usbmux

    facts: dict[str, Any] = {"serial": serial}
    ok, lockdown = await guarded(create_using_usbmux(serial=serial, autopair=False))
    if not ok:
        facts["error"] = lockdown
        return facts
    try:
        facts["product_type"] = lockdown.product_type
        facts["product_version"] = lockdown.product_version
        facts["paired"] = bool(lockdown.paired)
        if not lockdown.paired:
            return facts
        ok, dev_mode = await guarded(lockdown.get_developer_mode_status())
        facts["developer_mode"] = dev_mode if ok else None
        if not ok:
            facts["developer_mode_error"] = dev_mode
        try:
            from pymobiledevice3.services.mobile_image_mounter import (
                MobileImageMounterService,
                image_type_for_device,
            )

            image_type = image_type_for_device(lockdown)
            facts["ddi_image_type"] = image_type

            async def _mounted():
                async with MobileImageMounterService(lockdown=lockdown) as mounter:
                    return await mounter.is_image_mounted(image_type)

            ok, mounted = await guarded(_mounted())
            facts["ddi_mounted"] = mounted if ok else None
            if not ok:
                facts["ddi_error"] = mounted
        except Exception as e:  # noqa: BLE001
            facts["ddi_error"] = err(e)
    finally:
        await lockdown.close()
    return facts


# --------------------------------------------------------------------------- tunnels


async def probe_tunneld() -> dict:
    from pymobiledevice3.exceptions import TunneldConnectionError
    from pymobiledevice3.tunneld.api import TUNNELD_DEFAULT_ADDRESS, get_tunneld_tunnels

    address = f"{TUNNELD_DEFAULT_ADDRESS[0]}:{TUNNELD_DEFAULT_ADDRESS[1]}"
    try:
        tunnels = await asyncio.wait_for(get_tunneld_tunnels(), STEP_TIMEOUT)
    except TunneldConnectionError:
        return {"address": address, "running": False}
    except Exception as e:  # noqa: BLE001
        return {"address": address, "running": None, "error": err(e)}
    return {"address": address, "running": True, "tunnels": tunnels}


async def probe_native_browse() -> tuple[bool, Any]:
    if sys.platform != "darwin":
        return False, "macOS only"
    from pymobiledevice3.remote.native_tunnel import browse_native_devices

    async def _browse():
        found = await browse_native_devices(timeout=3.0)
        keep = ("udid", "name", "deviceName", "productType", "osVersionNumber", "transportType",
                "pairingState", "isPaired", "connectionType")
        return [{k: v for k, v in d.items() if k in keep} or {"keys": sorted(d.keys())} for d in found]

    return await guarded(_browse(), timeout=10.0)


def probe_userspace_stack() -> tuple[bool, str]:
    try:
        import pmd_pytcp  # noqa: F401
    except ImportError as e:
        return False, err(e)
    return True, f"pmd_pytcp {getattr(pmd_pytcp, '__version__', 'unknown')} importable"


async def probe_mdns() -> tuple[bool, Any]:
    from pymobiledevice3.bonjour import is_multicast_blocked, probe_multicast

    async def _probe():
        sent, errors = await probe_multicast()
        return {"interfaces": sent, "errors": [str(e) for e in errors],
                "blocked": bool(is_multicast_blocked(sent, errors))}

    return await guarded(_probe())


async def rsd_services_via_tunneld() -> tuple[bool, Any]:
    from pymobiledevice3.tunneld.api import get_tunneld_devices

    async def _list():
        rsds = await get_tunneld_devices()
        out = []
        for rsd in rsds:
            try:
                out.append({"udid": rsd.udid, "os": rsd.product_version,
                            "services": sorted(rsd.peer_info.get("Services", {}).keys())})
            finally:
                await rsd.close()
        return out

    return await guarded(_list())


async def rsd_services_via_native(udid: Optional[str]) -> tuple[bool, Any]:
    from pymobiledevice3.remote.native_tunnel import establish_native_rsd

    async def _list():
        rsd = await establish_native_rsd(serial=udid)
        try:
            return [{"udid": rsd.udid, "os": rsd.product_version,
                     "services": sorted(rsd.peer_info.get("Services", {}).keys())}]
        finally:
            await rsd.close()

    return await guarded(_list(), timeout=20.0)


# --------------------------------------------------------------------------- matrix


def build_matrix(r: dict) -> dict:
    host = r["host"]
    usb_ok, usb = r["usbmux"]["ok"], r["usbmux"]["result"]
    usb_devices = usb if usb_ok else []
    lockdowns = r["lockdown"]
    native_ok, native = r["native_browse"]["ok"], r["native_browse"]["result"]
    tunneld = r["tunneld"]
    rsd = r.get("rsd_services") or {}
    rsd_devices = rsd.get("result") if rsd.get("ok") else []
    services = set()
    for d in rsd_devices or []:
        services.update(d.get("services", []))

    m: dict[str, dict] = {}

    # ---- discovery
    usb_list = [d for d in usb_devices if d["connection_type"] == "USB"]
    net_list = [d for d in usb_devices if d["connection_type"] == "Network"]
    m["discovery_usbmux_usb"] = (
        cap(SUPPORTED, usb_list) if usb_list else
        cap(UNVERIFIED, usb if not usb_ok else "usbmuxd reachable, 0 USB devices",
            "no iPhone on USB" if usb_ok else "usbmuxd not reachable",
            "Kevin: connect the iPhone by cable and unlock it"))
    m["discovery_usbmux_network"] = (
        cap(SUPPORTED, net_list) if net_list else
        cap(UNVERIFIED, "0 network devices listed by usbmuxd",
            "device not listed over Wi-Fi; Wi-Fi listing needs a prior USB pairing plus "
            "`lockdown wifi-connections on` (or Finder 'Show this iPhone when on Wi-Fi')",
            "Kevin: one USB connection to pair/trust, then decide whether to enable Wi-Fi connections"))
    if native_ok and native:
        m["discovery_remotepairingd"] = cap(SUPPORTED, native)
    else:
        m["discovery_remotepairingd"] = cap(
            UNVERIFIED, native if not native_ok else "remotepairingd answered, 0 devices",
            "Apple's CoreDevice pairing daemon knows no device (it learns devices from Xcode/devicectl "
            "or `remote pair`; iPhone Mirroring's Continuity pairing is a different relationship)",
            "Kevin: USB-connect + Trust, or Wi-Fi `remote pair` with on-device confirmation")
    if r.get("mdns") is None:
        m["discovery_bonjour"] = cap(UNVERIFIED, "NOT_RUN (opt-in --allow-mdns)",
                                     "an mDNS query can raise macOS's Local Network prompt for the terminal",
                                     "Kevin: allow running with --allow-mdns, accept/deny the prompt himself")
    else:
        ok, res = r["mdns"]["ok"], r["mdns"]["result"]
        m["discovery_bonjour"] = cap(
            SUPPORTED if ok and not res.get("blocked") else UNSUPPORTED if ok else UNVERIFIED, res,
            None if ok and not res.get("blocked") else "mDNS blocked or failed (see evidence)")

    # ---- device facts (from the first lockdown that answered)
    ld = next((x for x in lockdowns if "product_version" in x), None)
    if ld:
        m["ios_version"] = cap(SUPPORTED, {"product_type": ld["product_type"], "ios": ld["product_version"]})
        m["pairing"] = (cap(SUPPORTED, "lockdown reports paired") if ld["paired"] else
                        cap(UNSUPPORTED, "lockdown reports NOT paired", "host not trusted by the phone",
                            "Kevin: unlock the phone and tap Trust"))
    else:
        reason = "no device reachable over usbmux"
        m["ios_version"] = cap(UNVERIFIED, lockdowns or None, reason,
                               "Kevin: connect the device (see discovery_usbmux_usb)")
        m["pairing"] = cap(UNVERIFIED, lockdowns or None, reason, "Kevin: connect + Trust")

    if ld and ld.get("paired") and ld.get("developer_mode") is not None:
        m["developer_mode"] = (cap(SUPPORTED, "enabled") if ld["developer_mode"] else
                               cap(UNSUPPORTED, "disabled", "every developer/CoreDevice HID/stream service is refused",
                                   "Kevin: Settings > Privacy & Security > Developer Mode (device reboots)"))
    else:
        m["developer_mode"] = cap(UNVERIFIED, ld.get("developer_mode_error") if ld else None,
                                  "needs a paired, reachable device")
    if ld and ld.get("paired") and ld.get("ddi_mounted") is not None:
        m["ddi_mounted"] = (cap(SUPPORTED, f"{ld['ddi_image_type']} image mounted") if ld["ddi_mounted"] else
                            cap(UNSUPPORTED, f"no {ld['ddi_image_type']} image mounted",
                                "hid/display/screencapture services are only published by the DDI",
                                "Kevin: authorize `pymobiledevice3 mounter auto-mount` (downloads + mounts the "
                                "personalized DDI on the phone)"))
    else:
        m["ddi_mounted"] = cap(UNVERIFIED, ld.get("ddi_error") if ld else None,
                               "needs a paired, reachable device")

    # ---- tunnels
    if tunneld.get("running"):
        m["tunnel_tunneld"] = cap(SUPPORTED, tunneld)
    else:
        m["tunnel_tunneld"] = cap(UNVERIFIED, tunneld,
                                  "tunneld not running (only detected; starting it needs sudo)",
                                  "Kevin: `sudo .venv/bin/pymobiledevice3 remote tunneld` in his own terminal")
    us_ok, us = r["userspace_stack"]
    m["tunnel_userspace_no_root"] = cap(
        UNVERIFIED, us,
        "host stack present, but no tunnel was opened: it needs a paired iOS 17.4+ device "
        "(and would auto-pair, i.e. raise Trust)" if us_ok else "pmd-pytcp missing",
        "Kevin: allow a --userspace tunnel attempt once the device is paired")
    if rsd.get("via") == "native":
        m["tunnel_native_remoted"] = (cap(SUPPORTED, "RSD handshake over Apple's remoted tunnel succeeded")
                                      if rsd.get("ok") else cap(UNSUPPORTED, rsd.get("result"),
                                                                "native tunnel attempt failed"))
    else:
        m["tunnel_native_remoted"] = cap(
            UNVERIFIED, "NOT_RUN" if native_ok and native else "no device known to remotepairingd",
            "requires a device in remotepairingd and the opt-in --allow-native-tunnel",
            "Kevin: allow --allow-native-tunnel after the device shows up")

    # ---- services (only from a real RSD service list)
    def svc(name: str, label: str, extra_reason: str = "") -> dict:
        if not rsd_devices:
            return cap(UNVERIFIED, None, f"no RSD service list (no tunnel to a device){extra_reason}")
        if name in services:
            return cap(SUPPORTED, f"{name} listed by RSD (listed != usable; not exercised){extra_reason}")
        return cap(UNSUPPORTED, f"{name} absent from RSD service list",
                   "usually means Developer Mode off or DDI not mounted")

    m["screenshot_coredevice"] = svc(SVC_SCREENCAPTURE, "screenshot")
    m["screenshot_dvt"] = svc(SVC_DVT, "dvt")
    m["screen_stream_displayservice"] = svc(SVC_DISPLAY, "stream")
    m["hid_universal_tap_drag"] = svc(
        SVC_HID_UNIVERSAL, "hid",
        "; touch only reaches UIKit while a displayservice media stream is open (auth gate)")
    m["hid_indigo_buttons"] = svc(SVC_HID_INDIGO, "buttons")
    m["pasteboard_service"] = svc(SVC_PASTEBOARD, "pasteboard")
    m["hid_type_ascii"] = cap(UNVERIFIED, None,
                              "`universal-hid-service type` maps printable US-ASCII only; never exercised here",
                              "Kevin: allow a harmless HID test in Notes")
    m["hid_type_direct_cjk"] = cap(UNSUPPORTED,
                                   "pymobiledevice3 ASCII_TO_HID maps printable US-ASCII only; `type` rejects other chars",
                                   "HID keyboard reports carry key usages, not Unicode text")
    m["text_chinese"] = cap(UNVERIFIED, None,
                            "candidate paths, none exercised: (a) pinyin keystrokes through the on-device Chinese "
                            "IME + candidate pick, (b) pasteboardservice `copy` then a paste action, (c) WDA",
                            "Kevin: allow a pasteboard write + paste test in Notes")
    m["hid_input_exercised"] = cap(UNVERIFIED, "NOT_RUN",
                                   "probe never sends HID input by design",
                                   "Kevin: explicit OK for one tap on a neutral spot")
    return m


async def main_async(args) -> dict:
    report: dict[str, Any] = {
        "probe": "experiments/ios-coredevice/probe.py",
        "generated_at": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "options": {"allow_mdns": args.allow_mdns, "allow_native_tunnel": args.allow_native_tunnel},
    }
    report["host"] = host_facts()
    report["pair_records"] = pair_record_facts()

    ok, res = await probe_usbmux()
    report["usbmux"] = {"ok": ok, "result": res}
    report["lockdown"] = []
    if ok:
        for d in res:
            report["lockdown"].append(await probe_lockdown(d["serial"]))

    report["tunneld"] = await probe_tunneld()
    ok, res = await probe_native_browse()
    report["native_browse"] = {"ok": ok, "result": res}
    report["userspace_stack"] = probe_userspace_stack()

    if args.allow_mdns:
        ok, res = await probe_mdns()
        report["mdns"] = {"ok": ok, "result": res}
    else:
        report["mdns"] = None

    if report["tunneld"].get("running") and report["tunneld"].get("tunnels"):
        ok, res = await rsd_services_via_tunneld()
        report["rsd_services"] = {"via": "tunneld", "ok": ok, "result": res}
    elif args.allow_native_tunnel and report["native_browse"]["ok"] and report["native_browse"]["result"]:
        udid = report["native_browse"]["result"][0].get("udid")
        ok, res = await rsd_services_via_native(udid)
        report["rsd_services"] = {"via": "native", "ok": ok, "result": res}
    else:
        report["rsd_services"] = None

    report["capabilities"] = build_matrix(report)
    counts: dict[str, int] = {}
    for c in report["capabilities"].values():
        counts[c["status"]] = counts.get(c["status"], 0) + 1
    report["summary"] = counts
    report["i13_acceptance"] = "NOT_RUN"
    return report


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--allow-mdns", action="store_true")
    p.add_argument("--allow-native-tunnel", action="store_true")
    p.add_argument("-o", "--output", type=Path, help="also write the JSON here")
    args = p.parse_args()
    report = asyncio.run(main_async(args))
    text = json.dumps(report, ensure_ascii=False, indent=2, default=str)
    print(text)
    if args.output:
        args.output.write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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
Operations (screenshot, screen stream, HID, pasteboard) are never exercised, so they always stay
"unverified"; whether the backing RSD service is advertised is reported separately as
`service_advertised_*`.

Facts are never mixed across devices: each device seen gets its own matrix in
`capabilities_by_device`, and `capabilities` is the matrix of one selected UDID (`--udid`).
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
                out.append({"udid": rsd.udid, "os": rsd.product_version, "interface": rsd.name,
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


def known_udids(r: dict) -> list[str]:
    """Every device identifier any probe step reported, in first-seen order (usbmux serial == UDID)."""
    seen: list[str] = []

    def add(u):
        if u and u not in seen:
            seen.append(u)

    if r["usbmux"]["ok"]:
        for d in r["usbmux"]["result"] or []:
            add(d.get("serial"))
    if r["native_browse"]["ok"]:
        for d in r["native_browse"]["result"] or []:
            add(d.get("udid"))
    rsd = r.get("rsd_services") or {}
    if rsd.get("ok"):
        for d in rsd.get("result") or []:
            add(d.get("udid"))
    return seen


# operation capability -> (RSD service that must be advertised first, extra note)
SERVICE_OPERATIONS = {
    "screenshot_coredevice": (SVC_SCREENCAPTURE, ""),
    "screenshot_dvt": (SVC_DVT, ""),
    "screen_stream_displayservice": (SVC_DISPLAY, "; the stream request itself may still be refused"),
    "hid_universal_tap_drag": (SVC_HID_UNIVERSAL,
                               "; touch only reaches UIKit while a displayservice media stream is open "
                               "(auth gate), otherwise events can be dropped silently"),
    "hid_indigo_buttons": (SVC_HID_INDIGO, ""),
    "pasteboard_service": (SVC_PASTEBOARD, ""),
}
ADVERTISED_SERVICES = {
    "service_advertised_screencapture": SVC_SCREENCAPTURE,
    "service_advertised_dvt": SVC_DVT,
    "service_advertised_displayservice": SVC_DISPLAY,
    "service_advertised_hid_universal": SVC_HID_UNIVERSAL,
    "service_advertised_hid_indigo": SVC_HID_INDIGO,
    "service_advertised_pasteboard": SVC_PASTEBOARD,
}


def build_matrix(r: dict, udid: Optional[str] = None) -> dict:
    """Capability matrix for ONE device. Every device-scoped fact (usbmux entry, lockdown, remotepairingd
    entry, RSD service list) is filtered to `udid`, so facts from different phones are never mixed.
    With udid=None (no device known at all) every device-scoped capability is unverified."""
    usb_ok, usb = r["usbmux"]["ok"], r["usbmux"]["result"]
    usb_devices = [d for d in (usb if usb_ok else []) if d.get("serial") == udid]
    lockdowns = [x for x in r["lockdown"] if x.get("serial") == udid]
    native_ok, native = r["native_browse"]["ok"], r["native_browse"]["result"]
    native_devices = [d for d in (native if native_ok else []) or [] if d.get("udid") == udid]
    tunneld = r["tunneld"]
    rsd = r.get("rsd_services") or {}
    rsd_devices = [d for d in (rsd.get("result") if rsd.get("ok") else None) or [] if d.get("udid") == udid]

    m: dict[str, dict] = {}

    # ---- discovery
    usb_list = [d for d in usb_devices if d["connection_type"] == "USB"]
    net_list = [d for d in usb_devices if d["connection_type"] == "Network"]
    m["discovery_usbmux_usb"] = (
        cap(SUPPORTED, usb_list) if usb_list else
        cap(UNVERIFIED, usb if not usb_ok else "usbmuxd reachable, device not listed on USB",
            "no iPhone on USB" if usb_ok else "usbmuxd not reachable",
            "Kevin: connect the iPhone by cable and unlock it"))
    m["discovery_usbmux_network"] = (
        cap(SUPPORTED, net_list) if net_list else
        cap(UNVERIFIED, "device not listed by usbmuxd over the network",
            "device not listed over Wi-Fi; Wi-Fi listing needs a prior USB pairing plus "
            "`lockdown wifi-connections on` (or Finder 'Show this iPhone when on Wi-Fi')",
            "Kevin: one USB connection to pair/trust, then decide whether to enable Wi-Fi connections"))
    if native_devices:
        m["discovery_remotepairingd"] = cap(SUPPORTED, native_devices)
    else:
        m["discovery_remotepairingd"] = cap(
            UNVERIFIED, native if not native_ok else "remotepairingd answered, device not listed",
            "Apple's CoreDevice pairing daemon does not know this device (it learns devices from "
            "Xcode/devicectl or `remote pair`; iPhone Mirroring's Continuity pairing is a different relationship)",
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

    # ---- device facts (lockdown of THIS device only)
    ld = next((x for x in lockdowns if "product_version" in x), None)
    if ld:
        m["ios_version"] = cap(SUPPORTED, {"product_type": ld["product_type"], "ios": ld["product_version"]})
        m["pairing"] = (cap(SUPPORTED, "lockdown reports paired") if ld["paired"] else
                        cap(UNSUPPORTED, "lockdown reports NOT paired", "host not trusted by the phone",
                            "Kevin: unlock the phone and tap Trust"))
    else:
        reason = "device not reachable over usbmux lockdown"
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
    tunneld_for_device = (tunneld.get("tunnels") or {}).get(udid) if isinstance(tunneld.get("tunnels"), dict) else None
    if tunneld.get("running") and tunneld_for_device:
        m["tunnel_tunneld"] = cap(SUPPORTED, {"address": tunneld["address"], "tunnels": tunneld_for_device})
    elif tunneld.get("running"):
        m["tunnel_tunneld"] = cap(UNVERIFIED, {"address": tunneld["address"], "running": True},
                                  "tunneld is running but holds no tunnel to this device")
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
    if rsd.get("via") == "native" and (rsd_devices or rsd.get("udid") == udid):
        m["tunnel_native_remoted"] = (cap(SUPPORTED, "RSD handshake over Apple's remoted tunnel succeeded")
                                      if rsd.get("ok") else cap(UNSUPPORTED, rsd.get("result"),
                                                                "native tunnel attempt failed"))
    else:
        m["tunnel_native_remoted"] = cap(
            UNVERIFIED, "NOT_RUN" if native_devices else "device not known to remotepairingd",
            "requires the device in remotepairingd and the opt-in --allow-native-tunnel",
            "Kevin: allow --allow-native-tunnel after the device shows up")

    # ---- services: advertisement is its own fact, read from THIS device's RSD service list
    rsd_source = {"via": rsd.get("via"), "udid": udid,
                  "rsd_entries": [{"interface": d.get("interface"), "ios": d.get("os")} for d in rsd_devices]}

    def advertised(name: str) -> dict:
        if not rsd_devices:
            return cap(UNVERIFIED, None, "no RSD service list for this device (no tunnel to it)")
        hits = [i for i, d in enumerate(rsd_devices) if name in d.get("services", [])]
        if hits:
            return cap(SUPPORTED, {**rsd_source, "service": name, "listed_in_entries": hits},
                       "service is advertised; this says nothing about whether the operation works")
        return cap(UNSUPPORTED, {**rsd_source, "service": name, "listed_in_entries": []},
                   "absent from RSD service list; usually means Developer Mode off or DDI not mounted")

    for key, name in ADVERTISED_SERVICES.items():
        m[key] = advertised(name)

    # ---- operations: never exercised by this read-only probe, so never "supported"
    for key, (name, note) in SERVICE_OPERATIONS.items():
        listed = m[next(k for k, v in ADVERTISED_SERVICES.items() if v == name)]["status"]
        state = {SUPPORTED: "advertised", UNSUPPORTED: "not advertised", UNVERIFIED: "unknown"}[listed]
        m[key] = cap(UNVERIFIED, f"NOT_RUN; {name} {state}",
                     f"read-only probe never exercises this operation; an advertised service is not proof it "
                     f"works{note}",
                     "Kevin: authorize one real attempt of this operation")
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


def summarize(matrix: dict) -> dict:
    counts: dict[str, int] = {}
    for c in matrix.values():
        counts[c["status"]] = counts.get(c["status"], 0) + 1
    return counts


def attach_matrices(report: dict, target: Optional[str]) -> None:
    """One matrix per device; `capabilities` is the matrix of exactly one selected UDID."""
    udids = known_udids(report)
    report["devices"] = udids
    report["capabilities_by_device"] = {u: build_matrix(report, u) for u in udids}
    if target:
        selected, why = target, "--udid"
    elif len(udids) == 1:
        selected, why = udids[0], "only device seen"
    elif udids:
        selected, why = udids[0], "first device seen; several devices present, pass --udid to choose"
    else:
        selected, why = None, "no device seen"
    report["target_udid"] = selected
    report["target_selection"] = why
    report["capabilities"] = (report["capabilities_by_device"].get(selected) if selected in udids
                              else build_matrix(report, selected))
    report["summary"] = summarize(report["capabilities"])


async def main_async(args) -> dict:
    report: dict[str, Any] = {
        "probe": "experiments/ios-coredevice/probe.py",
        "generated_at": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "read_only": True,
        "options": {"allow_mdns": args.allow_mdns, "allow_native_tunnel": args.allow_native_tunnel,
                    "udid": args.udid},
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
        udid = args.udid or report["native_browse"]["result"][0].get("udid")
        ok, res = await rsd_services_via_native(udid)
        report["rsd_services"] = {"via": "native", "udid": udid, "ok": ok, "result": res}
    else:
        report["rsd_services"] = None

    attach_matrices(report, args.udid)
    report["i13_acceptance"] = "NOT_RUN"
    return report


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--allow-mdns", action="store_true")
    p.add_argument("--allow-native-tunnel", action="store_true")
    p.add_argument("--udid", help="device whose matrix is reported as `capabilities` (default: the only/first "
                   "device seen); every device still gets its own entry in `capabilities_by_device`")
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

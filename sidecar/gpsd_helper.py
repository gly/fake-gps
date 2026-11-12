#!/usr/bin/env python3
"""
ios-fake-gps sidecar.

A long-lived helper that holds ONE developer connection to a tethered iPhone
open and streams simulated GPS coordinates to it. The macOS app (SwiftUI) speaks
to this process over stdin/stdout using newline-delimited JSON ("NDJSON").

Why a persistent process instead of calling `pymobiledevice3 ... set` per point:
iOS 17+ requires a RemoteXPC developer tunnel, and each fresh CLI invocation
re-does an expensive handshake. For smooth movement we push a new coordinate
~once per second, so we open the LocationSimulation DVT channel once and reuse it.

Prerequisite: the tunneld daemon must be running (needs root):

    sudo pymobiledevice3 remote tunneld

It manages the per-device tunnels and auto-mounts the Developer Disk Image.
This sidecar then borrows an RSD (RemoteServiceDiscovery) connection from it.

Protocol
--------
Commands in  (one JSON object per line on stdin):
    {"cmd": "set",   "lat": 40.69, "lon": -74.04, "id": 12}
    {"cmd": "clear",                               "id": 13}
    {"cmd": "ping",                                "id": 14}
    {"cmd": "devices"}
    {"cmd": "quit"}

Events out (one JSON object per line on stdout):
    {"event": "ready",       "device": {...}}
    {"event": "reconnected", "device": {...}}
    {"event": "ok",          "id": 12}
    {"event": "pong",        "id": 14}
    {"event": "devices",     "devices": [...]}
    {"event": "error",       "message": "...", "fatal": true|false, "id": 12}
    {"event": "bye"}

A non-fatal error with "code": "connection_lost" means the helper lost the
device and is reconnecting; a "reconnected" event follows when it succeeds.

stderr carries human-readable logs only; stdout is strictly NDJSON.
"""
import argparse
import asyncio
import json
import sys
import urllib.request
from contextlib import AsyncExitStack
from typing import Any, Optional

from pymobiledevice3.exceptions import TunneldConnectionError
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.tunneld.api import (
    TUNNELD_DEFAULT_ADDRESS,
    get_tunneld_device_by_udid,
    get_tunneld_devices,
)


def emit(obj: dict[str, Any]) -> None:
    """Write a single NDJSON event to stdout and flush immediately."""
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def log(*args: Any) -> None:
    print("[sidecar]", *args, file=sys.stderr, flush=True)


# tunneld rebuilds a device's tunnel when the connection changes (USB ↔ Wi-Fi,
# reconnect). An RSD opened against the old tunnel stays ESTABLISHED locally but
# the device never sees the DTX requests, so calls can hang forever. Bound every
# device call, notice when tunneld advertises a different tunnel, and reconnect.
CONNECT_TIMEOUT = 10.0
COMMAND_TIMEOUT = 5.0
CLOSE_TIMEOUT = 3.0
TUNNELD_TIMEOUT = 2.0
MAX_RECONNECT_ATTEMPTS = 3


class FatalError(Exception):
    """An error the sidecar cannot recover from."""

    def __init__(self, code: str, message: str, retcode: int = 2) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retcode = retcode


def fetch_tunnels(address: tuple[str, int]) -> dict[str, Any]:
    """Read tunneld's device/tunnel list (blocking — call via an executor)."""
    url = f"http://{address[0]}:{address[1]}"
    with urllib.request.urlopen(url, timeout=TUNNELD_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


async def close_stack(stack: AsyncExitStack) -> None:
    try:
        await asyncio.wait_for(stack.aclose(), CLOSE_TIMEOUT)
    except Exception:  # noqa: BLE001
        # A half-dead tunnel can make service shutdown hang. Dropping the socket
        # is safe: the OS closes it when this process exits.
        log("timed out closing the previous device connection")


def describe(rsd: RemoteServiceDiscoveryService) -> dict[str, Any]:
    # rsd.name 是隧道标识符（usbmux-...-Network），对用户无意义；
    # 真正的手机名称（DeviceName）要从 lockdown 的 all_values 里拿。
    all_values = getattr(rsd, "all_values", None) or {}
    device_name = all_values.get("DeviceName")
    return {
        "udid": rsd.udid,
        "name": device_name or getattr(rsd, "name", None),
        "device_name": device_name,
        "product_type": getattr(rsd, "product_type", None) or all_values.get("ProductType"),
        "product_version": getattr(rsd, "product_version", None) or all_values.get("ProductVersion"),
    }


async def list_devices(address: tuple[str, int]) -> list[RemoteServiceDiscoveryService]:
    return await get_tunneld_devices(address)


async def pick_device(
    address: tuple[str, int], udid: Optional[str]
) -> RemoteServiceDiscoveryService:
    if udid:
        rsd = await get_tunneld_device_by_udid(udid, address)
        if rsd is None:
            raise RuntimeError(f"device {udid} not found in tunneld")
        return rsd
    rsds = await get_tunneld_devices(address)
    if not rsds:
        raise RuntimeError("no devices available from tunneld")
    # Close the ones we won't use; keep the first.
    for extra in rsds[1:]:
        try:
            await extra.close()
        except Exception:
            pass
    return rsds[0]


async def stdin_lines() -> "asyncio.StreamReader":
    """Wrap stdin as an asyncio StreamReader (works on macOS pipes)."""
    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)
    return reader


class DeviceSession:
    """An RSD + DVT + LocationSimulation stack for one device."""

    def __init__(self, address: tuple[str, int], udid: Optional[str]) -> None:
        self.address = address
        self.udid = udid
        self.stack: Optional[AsyncExitStack] = None
        self.rsd: Optional[RemoteServiceDiscoveryService] = None
        self.loc: Optional[LocationSimulation] = None
        # Last location we believe the device is simulating; re-applied after a
        # reconnect so movement continues without a gap.
        self.last_location: Optional[tuple[float, float]] = None

    @property
    def tunnel_endpoint(self) -> Optional[tuple[str, int]]:
        service = getattr(self.rsd, "service", None) if self.rsd is not None else None
        return getattr(service, "address", None)

    async def open(self) -> None:
        stack = AsyncExitStack()
        try:
            try:
                rsd = await asyncio.wait_for(
                    pick_device(self.address, self.udid), CONNECT_TIMEOUT
                )
            except asyncio.TimeoutError as e:
                raise FatalError(
                    "no_tunneld",
                    f"tunneld did not respond within {CONNECT_TIMEOUT:.0f}s at "
                    f"{self.address[0]}:{self.address[1]}.",
                    2,
                ) from e
            except TunneldConnectionError as e:
                raise FatalError(
                    "no_tunneld",
                    "Cannot reach tunneld at "
                    f"{self.address[0]}:{self.address[1]}. Start it with: "
                    "sudo pymobiledevice3 remote tunneld",
                    2,
                ) from e
            except Exception as e:  # noqa: BLE001
                raise FatalError("no_device", str(e), 2) from e

            # Remember the concrete device so reconnects target the same one
            # even when the caller let us pick "the first device".
            self.udid = rsd.udid

            # Registered first so services close (LIFO) before the RSD they use.
            stack.push_async_callback(rsd.close)
            try:
                dvt = await asyncio.wait_for(
                    stack.enter_async_context(DvtProvider(rsd)), CONNECT_TIMEOUT
                )
                loc = await asyncio.wait_for(
                    stack.enter_async_context(LocationSimulation(dvt)), CONNECT_TIMEOUT
                )
            except Exception as e:  # noqa: BLE001
                raise FatalError(
                    "dvt_failed",
                    f"Could not open LocationSimulation: {e}. "
                    "Is Developer Mode enabled and the DDI mounted?",
                    3,
                ) from e
        except BaseException:
            await close_stack(stack)
            raise

        self.stack = stack
        self.rsd = rsd
        self.loc = loc

    async def close(self) -> None:
        stack, self.stack = self.stack, None
        self.rsd = None
        self.loc = None
        if stack is not None:
            await close_stack(stack)

    async def tunnel_is_stale(self) -> bool:
        """True when tunneld no longer advertises the tunnel we're connected to."""
        endpoint = self.tunnel_endpoint
        if endpoint is None:
            return False
        try:
            tunnels = await asyncio.get_running_loop().run_in_executor(
                None, fetch_tunnels, self.address
            )
        except Exception:  # noqa: BLE001
            # Can't tell (tunneld down or busy) — let the command itself decide.
            return False
        udid = self.rsd.udid if self.rsd is not None else self.udid
        entries = (tunnels.get(udid) or []) if udid else []
        if not entries:
            return True
        return all(
            (entry.get("tunnel-address"), entry.get("tunnel-port")) != endpoint
            for entry in entries
        )


async def reconnect(session: DeviceSession) -> None:
    """Swap a stale session for a fresh tunnel, restoring the last location."""
    await session.close()
    last_error: Optional[BaseException] = None
    delay = 0.5
    for attempt in range(1, MAX_RECONNECT_ATTEMPTS + 1):
        try:
            await session.open()
        except FatalError as e:
            last_error = e
            log(f"reconnect attempt {attempt}/{MAX_RECONNECT_ATTEMPTS} failed:", e.message)
        except Exception as e:  # noqa: BLE001
            last_error = e
            log(f"reconnect attempt {attempt}/{MAX_RECONNECT_ATTEMPTS} failed:", repr(e))
        else:
            emit({"event": "reconnected", "device": describe(session.rsd)})
            log("reconnected to", session.rsd.udid)
            if session.last_location is not None and session.loc is not None:
                try:
                    await asyncio.wait_for(
                        session.loc.set(*session.last_location), COMMAND_TIMEOUT
                    )
                except Exception as e:  # noqa: BLE001
                    log("could not re-apply the last location:", repr(e))
            return
        await asyncio.sleep(delay)
        delay = min(delay * 2, 3.0)
    if isinstance(last_error, FatalError):
        raise last_error
    raise FatalError("connection_lost", f"Reconnect failed: {last_error}", 4)


async def run_device_command(
    session: DeviceSession, cmd: str, lat: float, lon: float, mid: Any
) -> None:
    """Apply one location command, reconnecting once if the tunnel went stale."""
    for attempt in (0, 1):
        try:
            if attempt == 0 and await session.tunnel_is_stale():
                log("tunneld advertises a new tunnel; reconnecting first")
                emit(
                    {
                        "event": "error",
                        "fatal": False,
                        "code": "connection_lost",
                        "message": "设备隧道已更新，正在重新连接…",
                    }
                )
                await reconnect(session)

            if session.loc is None:
                raise RuntimeError("device connection is not open")
            if cmd == "set":
                await asyncio.wait_for(session.loc.set(lat, lon), COMMAND_TIMEOUT)
                session.last_location = (lat, lon)
            else:
                await asyncio.wait_for(session.loc.clear(), COMMAND_TIMEOUT)
                session.last_location = None
            emit({"event": "ok", "id": mid})
            return
        except FatalError:
            raise
        except Exception as e:  # noqa: BLE001
            log(f"{cmd} failed (attempt {attempt + 1}):", repr(e))
            if attempt == 1:
                raise FatalError(
                    "connection_lost", f"Device connection lost: {e}", 4
                ) from e
            emit(
                {
                    "event": "error",
                    "fatal": False,
                    "code": "connection_lost",
                    "message": "与设备的连接已失效，正在重新连接…",
                }
            )
            await reconnect(session)


async def run(address: tuple[str, int], udid: Optional[str]) -> int:
    reader = await stdin_lines()
    session = DeviceSession(address, udid)
    try:
        await session.open()
    except FatalError as e:
        emit({"event": "error", "fatal": True, "code": e.code, "message": e.message})
        return e.retcode

    emit({"event": "ready", "device": describe(session.rsd)})
    log("ready, simulating location for", session.rsd.udid)

    # --- command loop ------------------------------------------------------
    try:
        while True:
            raw = await reader.readline()
            if not raw:  # EOF — parent closed the pipe
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                emit({"event": "error", "fatal": False, "message": f"bad json: {line!r}"})
                continue

            cmd = msg.get("cmd")
            mid = msg.get("id")
            try:
                if cmd in ("set", "clear"):
                    lat = lon = 0.0
                    if cmd == "set":
                        lat = float(msg["lat"])
                        lon = float(msg["lon"])
                    try:
                        await run_device_command(session, cmd, lat, lon, mid)
                    except FatalError as e:
                        emit(
                            {
                                "event": "error",
                                "fatal": True,
                                "code": e.code,
                                "message": e.message,
                                "id": mid,
                            }
                        )
                        return e.retcode
                elif cmd == "ping":
                    emit({"event": "pong", "id": mid})
                elif cmd == "devices":
                    devs = await list_devices(address)
                    emit({"event": "devices", "devices": [describe(d) for d in devs]})
                    current_udid = (
                        session.rsd.udid if session.rsd is not None else None
                    )
                    for d in devs:
                        if d.udid != current_udid:
                            try:
                                await d.close()
                            except Exception:
                                pass
                elif cmd == "quit":
                    break
                else:
                    emit(
                        {
                            "event": "error",
                            "fatal": False,
                            "id": mid,
                            "message": f"unknown cmd: {cmd!r}",
                        }
                    )
            except FatalError:
                raise
            except Exception as e:  # noqa: BLE001
                emit({"event": "error", "fatal": False, "id": mid, "message": str(e)})
    finally:
        # Best-effort: stop simulating before we drop the connection.
        if session.loc is not None:
            try:
                await asyncio.wait_for(session.loc.clear(), COMMAND_TIMEOUT)
            except Exception:  # noqa: BLE001
                pass
        await session.close()

    emit({"event": "bye"})
    return 0


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ios-fake-gps sidecar")
    p.add_argument("--udid", default=None, help="target device UDID (default: first)")
    p.add_argument(
        "--tunneld-host", default=TUNNELD_DEFAULT_ADDRESS[0], help="tunneld host"
    )
    p.add_argument(
        "--tunneld-port", type=int, default=TUNNELD_DEFAULT_ADDRESS[1], help="tunneld port"
    )
    p.add_argument(
        "--list", action="store_true", help="list devices as one NDJSON event and exit"
    )
    return p.parse_args()


async def amain() -> int:
    ns = parse_args()
    address = (ns.tunneld_host, ns.tunneld_port)
    if ns.list:
        try:
            devs = await list_devices(address)
        except TunneldConnectionError:
            emit(
                {
                    "event": "error",
                    "fatal": True,
                    "code": "no_tunneld",
                    "message": "tunneld not running (sudo pymobiledevice3 remote tunneld)",
                }
            )
            return 2
        emit({"event": "devices", "devices": [describe(d) for d in devs]})
        for d in devs:
            await d.close()
        return 0
    return await run(address, ns.udid)


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(amain()))
    except KeyboardInterrupt:
        sys.exit(130)

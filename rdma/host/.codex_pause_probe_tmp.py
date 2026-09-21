#!/usr/bin/env python3

import pathlib
import socket
import struct
import subprocess
import sys
import time


KEYS = (
    "tx_bytes.nic",
    "tx_multicast.nic",
    "tx_size_64.nic",
    "tx_errors.nic",
    "tx_dropped_link_down.nic",
    "link_xon_tx.nic",
    "link_xoff_tx.nic",
)


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True)


def pause_configuration(interface: str) -> tuple[str, str]:
    values: dict[str, str] = {}
    for line in command("ethtool", "-a", interface).splitlines():
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        values[name.strip()] = value.strip().lower()
    return values["RX"], values["TX"]


def set_pause(interface: str, rx: str, tx: str) -> None:
    subprocess.run(
        ["ethtool", "-A", interface, "autoneg", "off", "rx", rx, "tx", tx],
        check=True,
    )


def snapshot(interface: str, label: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in command("ethtool", "-S", interface).splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        if name in KEYS:
            values[name] = int(value.strip())

    missing = [key for key in KEYS if key not in values]
    if missing:
        raise RuntimeError(f"missing ethtool counters: {', '.join(missing)}")

    print(f"[{label}]")
    for key in KEYS:
        print(f"{key}={values[key]}")
    return values


def show_delta(label: str, before: dict[str, int], after: dict[str, int]) -> None:
    print(f"[{label}]")
    for key in KEYS:
        print(f"{key}={after[key] - before[key]:+d}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} INTERFACE", file=sys.stderr)
        return 2

    interface = sys.argv[1]
    original_rx, original_tx = pause_configuration(interface)
    src = bytes.fromhex(
        pathlib.Path(f"/sys/class/net/{interface}/address")
        .read_text()
        .strip()
        .replace(":", "")
    )
    ordinary = bytes.fromhex("01005e000001") + src + struct.pack("!H", 0x88B5) + bytes(46)

    def pause(quanta: int) -> bytes:
        return (
            bytes.fromhex("0180c2000001")
            + src
            + struct.pack("!HHH", 0x8808, 0x0001, quanta)
            + bytes(42)
        )

    try:
        set_pause(interface, "off", "off")
        with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003)) as sock:
            sock.bind((interface, 0))
            time.sleep(1.0)
            before = snapshot(interface, "before")
            ordinary_bytes = sum(sock.send(ordinary) for _ in range(68))
            time.sleep(1.0)
            after_ordinary = snapshot(interface, "after_ordinary_multicast")
            pause_bytes = sum(sock.send(pause(0xFFFF)) for _ in range(64))
            pause_bytes += sum(sock.send(pause(0x0000)) for _ in range(4))
            time.sleep(1.0)
            after_pause = snapshot(interface, "after_pause")

        print(f"ordinary_returned_bytes={ordinary_bytes}")
        print(f"pause_returned_bytes={pause_bytes}")
        show_delta("ordinary_multicast_delta", before, after_ordinary)
        show_delta("pause_delta", after_ordinary, after_pause)
    finally:
        set_pause(interface, original_rx, original_tx)
        print(f"restored_pause_rx={original_rx} tx={original_tx}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

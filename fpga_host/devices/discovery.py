"""Linux video node discovery via sysfs VID/PID; manual paths work everywhere."""
from pathlib import Path


def video_devices():
    found = []
    for node in sorted(Path("/sys/class/video4linux").glob("video*")):
        name = (node / "name").read_text().strip() if (node / "name").exists() else node.name
        vid_pid = (None, None)
        for parent in (node.resolve(), *node.resolve().parents):
            if (parent / "idVendor").exists() and (parent / "idProduct").exists():
                vid_pid = (int((parent / "idVendor").read_text(), 16), int((parent / "idProduct").read_text(), 16))
                break
        found.append((f"/dev/{node.name}", name, *vid_pid))
    return found

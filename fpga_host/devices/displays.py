"""Physical X11 signal modes, independent of Qt's scaled desktop rectangles."""
import os
import re
import shutil
import subprocess


def parse_xrandr(text):
    modes = {}
    output = None
    for line in text.splitlines():
        connected = re.match(r'^(\S+) connected(?:\s|$)', line)
        if connected:
            output = connected[1]
            continue
        if line and not line[0].isspace():
            output = None
        mode = re.match(r'^\s+(\d+)x(\d+)\S*\s+(.+)$', line)
        if output and mode:
            rate = next((token for token in mode[3].split() if '*' in token), None)
            if rate:
                value = re.match(r'[\d.]+', rate)
                if value:
                    modes[output] = (int(mode[1]), int(mode[2]), float(value[0]))
    return modes


def physical_modes():
    if os.name == 'nt' or not os.environ.get('DISPLAY') or not shutil.which('xrandr'):
        return {}
    try:
        result = subprocess.run(['xrandr', '--query'], capture_output=True, text=True, timeout=2)
        return parse_xrandr(result.stdout) if result.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError):
        return {}

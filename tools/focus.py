#!/usr/bin/env python3
"""A bare Dygma Focus client: sends each argument as a command and prints the reply.

    tools/focus.py version 'layer.state' 'mouse.speed'
    tools/focus.py help                       # every command the keyboard knows

Only one program can hold the keyboard's serial port, so quit Bazecor first, and pause
the helper from its menu (or quit it).
The port is found as the only /dev/cu.usbmodem* device; set FOCUS_PORT to choose one.
"""
import glob
import os
import select
import sys
import termios
import time


def find_port():
    p = os.environ.get("FOCUS_PORT")
    if p:
        return p
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("no /dev/cu.usbmodem* port: is the keyboard connected by USB?")
    if len(ports) > 1:
        sys.exit("several serial ports (%s): set FOCUS_PORT to the keyboard's" % ", ".join(ports))
    return ports[0]


class Focus:
    def __init__(self, path=None):
        path = path or find_port()
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as e:
            sys.exit("%s: %s (is Bazecor or the helper holding it?)" % (path, e.strerror))
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0
        a[2] |= termios.CLOCAL | termios.CREAD
        a[4] = a[5] = termios.B115200
        termios.tcsetattr(self.fd, termios.TCSANOW, a)

    def cmd(self, c, timeout=5.0):
        """Send one command; return its reply without the closing '.'."""
        data = (c + "\n").encode()
        while data:
            try:
                data = data[os.write(self.fd, data):]
            except BlockingIOError:
                select.select([], [self.fd], [], 0.5)
        out, t = b"", time.time()
        while time.time() - t < timeout:
            r, _, _ = select.select([self.fd], [], [], 0.3)
            if r:
                out += os.read(self.fd, 65536)
            if out.endswith(b"\r\n.\r\n") or out == b".\r\n":
                break
        return out.decode(errors="replace").strip().rstrip(".").strip()

    def ints(self, c):
        return [int(x) for x in self.cmd(c).split()]

    def close(self):
        os.close(self.fd)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    f = Focus()
    for c in sys.argv[1:]:
        print("== %s\n%s" % (c, f.cmd(c)))

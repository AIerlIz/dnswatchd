#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Boot a real OpenWrt image under QEMU and install the built packages.

Everything the unit tests cannot reach lives here:

  * procd starting dnswatchd after dnsmasq (START=95 vs START=19)
  * dnsmasq's ujail actually seeing /etc/dnswatchd/servers (EXTRA_MOUNT)
  * dnsmasq re-reading the servers-file on reload, with noresolv=1
  * rpcd discovering /usr/libexec/rpcd/dnswatchd and exposing the ubus object
  * takeover and rollback against the real uci, not a shim

The decisive assertion is step 9: after takeover, dnsmasq has exactly one
upstream and resolv.conf is ignored, so a lookup through 127.0.0.1 only works if
the jail mount is correct and the file was actually read.

    python3 scripts/qemu-smoke.py --ipk-dir ipk/ [--version 24.10.8]
"""

import argparse
import zlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

SERIAL_SOCKET = "serial.sock"


def log(msg):
    print(f"[qemu-smoke] {msg}", flush=True)


class Console:
    """Line-oriented console over a QEMU serial socket."""

    def __init__(self, path, deadline=1800):
        self.deadline = deadline
        self.buf = ""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(1.0)
        end = time.time() + 30
        while True:
            try:
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.time() > end:
                    raise
                time.sleep(0.2)

    def read_until(self, markers, timeout=60):
        """Return text up to and including one of `markers`."""
        end = time.time() + timeout
        while time.time() < end:
            for m in markers:
                idx = self.buf.find(m)
                if idx >= 0:
                    out = self.buf[: idx + len(m)]
                    self.buf = self.buf[idx + len(m):]
                    return out
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            self.buf += chunk.decode("utf-8", "replace")
        raise TimeoutError(f"waiting for {markers}, have: {self.buf[-400:]!r}")

    def send(self, line):
        self.sock.sendall((line + "\n").encode())

    def run(self, command, timeout=120, expect_rc=0):
        """Run one command, return its output; assert the exit status.

        The console echoes the command back, so a fixed marker would be matched
        inside its own echo. A per-call token plus "=digits" cannot appear in the
        echoed text, because that line carries the literal %s.
        """
        token = "__DW_" + os.urandom(4).hex()
        self.send(f"{command}; printf '{token}=%s\\n' \"$?\"")
        pattern = re.compile(re.escape(token) + r"=(\d+)")

        end = time.time() + timeout
        while True:
            m = pattern.search(self.buf)
            if m:
                body = self.buf[: m.start()]
                self.buf = self.buf[m.end():]
                rc = int(m.group(1))
                break
            if time.time() > end:
                raise TimeoutError(
                    f"{command!r} timed out; have {self.buf[-400:]!r}"
                )
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError("serial console closed")
            self.buf += chunk.decode("utf-8", "replace")

        # Drop the echoed command line and the shell prompt around the output.
        lines = body.splitlines()
        if lines and (token in lines[0] or command.split(";")[0][:20] in lines[0]):
            lines = lines[1:]
        body = "\n".join(lines)

        if expect_rc is not None and rc != expect_rc:
            raise AssertionError(
                f"{command!r} exited {rc} (wanted {expect_rc})\n{body.strip()[:1500]}"
            )
        return body

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Smoke:
    def __init__(self, args):
        self.args = args
        self.work = tempfile.mkdtemp(prefix="dnsqemu-")
        self.qemu = None
        self.http = None
        self.console = None
        self.passed = 0
        self.failed = 0

    # ---------------------------------------------------------------- setup

    def image_path(self):
        name = f"openwrt-{self.args.version}-x86-64-generic-ext4-combined.img"
        raw = os.path.join(self.work, name)
        if os.path.exists(raw):
            return raw

        gz = raw + ".gz"
        url = (f"https://downloads.openwrt.org/releases/{self.args.version}"
               f"/targets/x86/64/{os.path.basename(gz)}")
        log(f"downloading {url}")
        last = None
        for attempt in range(1, 4):
            try:
                urllib.request.urlretrieve(url, gz)
                break
            except Exception as exc:            # network flake, not a decision
                last = exc
                log(f"download attempt {attempt} failed: {exc}")
                time.sleep(5 * attempt)
        else:
            raise SystemExit(f"could not download {url}: {last}")

        # A captive portal or an error page is a 200 with HTML in it; say so
        # instead of letting gzip raise "Not a gzipped file".
        with open(gz, "rb") as fh:
            magic = fh.read(2)
        if magic != b"\x1f\x8b":
            size = os.path.getsize(gz)
            with open(gz, "rb") as fh:
                head = fh.read(200).decode("utf-8", "replace")
            raise SystemExit(
                f"{url} did not return gzip ({size} bytes, starts {head[:80]!r})"
            )

        # Decompress only the first gzip member. Some networks append a notice
        # to the body (a TLS interceptor's page, a captive portal), which makes
        # the stream a valid member followed by text: `gzip` tolerates it,
        # Python's gzip module raises "Not a gzipped file" mid-stream.
        written = 0
        needle = zlib.decompressobj(16 + zlib.MAX_WBITS)
        with open(gz, "rb") as src, open(raw, "wb") as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(needle.decompress(chunk))
                written = dst.tell()
                if needle.eof:
                    break
        if needle.unused_data:
            log(f"ignored {len(needle.unused_data)} trailing bytes after the "
                f"gzip member (network notice?)")
        if written < 10 * 1024 * 1024:
            raise SystemExit(f"decompressed image is only {written} bytes")
        log(f"image ready, {written} bytes")
        os.unlink(gz)
        return raw

    def start_http(self):
        self.http = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(self.args.http_port),
             "--bind", "127.0.0.1"],
            cwd=self.args.ipk_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1.0)

    def start_qemu(self, img):
        sock = os.path.join(self.work, SERIAL_SOCKET)
        cmd = [
            "qemu-system-x86_64",
            "-display", "none",
            "-m", "512",
            "-smp", "2",
            "-no-reboot",
            "-drive", f"file={img},format=raw,if=virtio",
            # Two NICs: OpenWrt's x86 default puts eth0 in br-lan (static LAN,
            # no DHCP client) and leaves eth1 as the DHCP WAN. With a single NIC
            # the guest has no route to 10.0.2.2 and wget fails with EPERM.
            "-netdev", "user,id=n0",
            "-device", "virtio-net-pci,netdev=n0",
            "-netdev", "user,id=n1",
            "-device", "virtio-net-pci,netdev=n1",
            "-serial", f"unix:{sock},server=on,wait=off",
        ]
        kvm = os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.R_OK | os.W_OK)
        if kvm:
            cmd[1:1] = ["-enable-kvm", "-cpu", "host"]

        log("booting with " + ("kvm" if kvm else "tcg (slow)"))
        self.qemu = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT
        )
        self.console = Console(sock)

    def boot(self):
        # OpenWrt's console sits behind "Please press Enter to activate this
        # console" until something arrives on stdin, so a passive wait for a
        # prompt never returns.
        deadline = time.time() + self.args.boot_timeout
        while time.time() < deadline:
            self.console.send("")
            try:
                out = self.console.read_until(
                    ["login:", "Please press Enter", "# "], 10
                )
            except TimeoutError:
                continue

            if "login:" in out:
                self.console.send("root")
                self.console.read_until(["# "], 120)
                return
            if "# " in out:
                return

        raise TimeoutError("no console prompt after boot")

    # ---------------------------------------------------------------- checks

    def wait_dns(self, seconds=25):
        """dnsmasq restarts on reload; give it a moment before probing it."""
        c = self.console
        c.run(f"i=0; while [ $i -lt {seconds} ]; do "
              "if nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; then "
              "echo DNS_UP; break; fi; sleep 1; i=$((i+1)); done; true",
              timeout=seconds + 20, expect_rc=None)

    def dns_ok(self):
        out = self.console.run(
            "nslookup openwrt.org 127.0.0.1 2>&1 | tail -3", timeout=60, expect_rc=None
        )
        return "Address" in out, out

    def check(self, label, ok, detail=""):
        if ok:
            self.passed += 1
            print(f"ok   {label}")
        else:
            self.failed += 1
            print(f"FAIL {label}\n     {detail}")

    def check_contains(self, label, haystack, needle):
        self.check(label, needle in haystack,
                   f"expected {needle!r} in:\n{haystack.strip()[:1200]}")

    def run(self):
        img = self.image_path()
        self.start_http()
        self.start_qemu(img)
        self.boot()

        c = self.console
        c.run("mkdir -p /tmp/pkgs", timeout=30, expect_rc=0)

        # Wait for the WAN lease; the fetch below runs seconds after boot.
        c.run("for i in $(seq 1 30); do "
              "ping -c1 -W1 10.0.2.2 >/dev/null 2>&1 && break; sleep 1; done; true",
              timeout=90, expect_rc=0)

        ipks = sorted(
            f for f in os.listdir(self.args.ipk_dir) if f.endswith(".ipk")
        )
        if not ipks:
            raise SystemExit(f"no .ipk in {self.args.ipk_dir}")

        for name in ipks:
            c.run(
                f"wget -q -O /tmp/pkgs/{name} "
                f"http://10.0.2.2:{self.args.http_port}/{name}",
                timeout=120,
            )
        log(f"fetched {len(ipks)} packages")

        out = c.run("opkg install /tmp/pkgs/*.ipk 2>&1", timeout=300, expect_rc=None)
        self.check("all three packages install",
                   "Configuring dnswatchd" in out, out)

        # -- 1. the files are where the code expects them
        paths = [
            "/usr/sbin/dnswatchd",
            "/usr/libexec/dnswatchd/probe",
            "/usr/libexec/rpcd/dnswatchd",
            "/etc/init.d/dnswatchd",
            "/usr/lib/dnswatchd/select.sh",
            "/www/luci-static/resources/view/dnswatchd/main.js",
        ]
        out = c.run("for f in %s; do if [ -e \"$f\" ]; then echo \"OK $f\"; "
                    "else echo \"MISSING $f\"; fi; done" % " ".join(paths),
                    expect_rc=0)
        # Count OK lines: the echoed command contains the word MISSING.
        self.check("installed files exist", out.count("OK /") == len(paths), out)

        out = c.run("ls -l /usr/libexec/dnswatchd/probe", expect_rc=0)
        self.check_contains("probe is installed executable", out, "-rwx")

        # -- 2. rpcd found the plugin
        out = c.run("ubus list 2>/dev/null | grep -c '^dnswatchd$'", expect_rc=0)
        self.check("rpcd exposes the dnswatchd object", out.strip().endswith("1"), out)

        # -- 3. baseline: dnsmasq answers before we touch anything. Right after
        #       boot it may still be starting, so wait for it like any other
        #       point where a reload has just happened.
        self.wait_dns()
        ok, out = self.dns_ok()
        self.check("dnsmasq resolves before takeover", ok, out)

        # -- 4. takeover
        out = c.run("dnswatchd takeover 2>&1", timeout=180, expect_rc=0)
        self.check_contains("takeover reports success", out, "managed by dnswatchd")

        out = c.run("uci get dhcp.@dnsmasq[0].noresolv", expect_rc=0)
        self.check("noresolv is set", out.strip().endswith("1"), out)

        out = c.run("uci get dhcp.@dnsmasq[0].serversfile", expect_rc=0)
        self.check_contains("serversfile points at ours", out, "/etc/dnswatchd/servers")

        out = c.run("grep -c '^server=' /etc/dnswatchd/servers", expect_rc=0)
        self.check("exactly one server line", out.strip().endswith("1"), out)

        # -- 5. THE test: one upstream, no resolv.conf, and DNS still works.
        #        If the ujail mount were wrong, dnsmasq would have no upstream.
        self.wait_dns()
        ok, out = self.dns_ok()
        self.check("dnsmasq still resolves after takeover", ok, out)

        out = c.run(
            "logread 2>/dev/null | grep 'cannot read' | tail -3 || true",
            expect_rc=0)
        self.check("dnsmasq did not fail to read the servers-file",
                   "/etc/dnswatchd/servers" not in out, out)

        # -- 6. the daemon does a real round against a real upstream
        out = c.run(
            "o=$(dnswatchd once --json 2>/dev/null); i=0; "
            "while [ $i -lt 5 ]; do "
            "case \"$o\" in *busy*) sleep 3; "
            "o=$(dnswatchd once --json 2>/dev/null) ;; *) break ;; esac; "
            "i=$((i+1)); done; echo \"$o\"",
            timeout=300, expect_rc=None)
        line = next((l.strip() for l in out.splitlines()
                     if l.strip().startswith("{")), "")
        self.check("one round produces JSON", line.startswith('{"ok":true'), out)
        try:
            data = json.loads(line)
            self.check("status json has upstreams", len(data.get("upstreams", [])) >= 1,
                       json.dumps(data)[:800])
            self.check("status json reports the active upstream",
                       data.get("active", {}).get("section", "") != "",
                       json.dumps(data.get("active", {})))
        except (ValueError, IndexError) as exc:
            self.check("status json parses", False, f"{exc}: {out[:400]}")

        # -- 7. procd supervises it
        out = c.run("/etc/init.d/dnswatchd status 2>&1 || true", expect_rc=0)
        self.check_contains("service is running", out, "running")

        # -- 8. rollback restores the original configuration
        out = c.run("dnswatchd rollback 2>&1", timeout=180, expect_rc=0)
        self.check_contains("rollback reports success", out, "restored dnsmasq")

        out = c.run("uci -q get dhcp.@dnsmasq[0].serversfile || echo unset", expect_rc=0)
        self.check("serversfile is gone again", out.strip().endswith("unset"), out)

        out = c.run("uci -q get dhcp.@dnsmasq[0].noresolv || echo unset", expect_rc=0)
        self.check("noresolv is gone again", out.strip().endswith("unset"), out)

        self.wait_dns()
        ok, out = self.dns_ok()
        self.check("dnsmasq resolves after rollback", ok, out)

        out = c.run("sleep 3; /etc/init.d/dnswatchd status 2>&1; "
                    "pgrep -f '/usr/sbin/dnswatchd' | head -3", expect_rc=0)
        self.check("service is stopped", "running" not in out, out)

    # ---------------------------------------------------------------- teardown

    def close(self):
        try:
            if self.console:
                self.console.send("poweroff")
                time.sleep(2)
        except Exception:
            pass
        for proc in (self.qemu, self.http):
            if proc:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
        shutil.rmtree(self.work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipk-dir", required=True)
    ap.add_argument("--version", default="24.10.8")
    ap.add_argument("--http-port", type=int, default=8000)
    ap.add_argument("--boot-timeout", type=int, default=900)
    args = ap.parse_args()

    smoke = Smoke(args)
    try:
        smoke.run()
    except Exception as exc:
        import traceback
        print(f"\nqemu-smoke aborted: {exc}", file=sys.stderr)
        traceback.print_exc()
        smoke.failed += 1
    finally:
        smoke.close()

    print(f"\n{smoke.passed} passed, {smoke.failed} failed")
    return 0 if smoke.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

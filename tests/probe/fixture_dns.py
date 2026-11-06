#!/usr/bin/env python3
"""Deterministic DNS fixture for dnswatch-probe tests.

Serves a handful of canned answers over UDP and TCP on 127.0.0.1. No external
network, no daemon state: every case is fully determined by the query name.

    python3 fixture_dns.py [PORT]      # default 5353

Cases
    ok.test         A 198.18.0.1
    ok2.test        A 198.18.0.2
    multi.test      A 198.18.0.1 + A 8.8.8.8      (mixed: must fail "in")
    multiok.test    A 198.18.0.1 + A 198.18.0.2    (all inside)
    cname.test      CNAME -> ok.test + A 198.18.0.1
    nx.test         NXDOMAIN
    nodata.test     NOERROR, no answer
    servfail.test   SERVFAIL
    refused.test    REFUSED
    trunc.test      UDP truncated flag, TCP carries A 198.18.0.1
    blackhole.test  no reply at all
"""
import os
import socket
import struct
import sys
import threading

TRIES = 3


def qname(pkt, off):
    labels = []
    while True:
        n = pkt[off]
        if n == 0:
            off += 1
            break
        if n & 0xC0:
            off += 2
            break
        labels.append(pkt[off + 1:off + 1 + n].decode())
        off += 1 + n
    return ".".join(labels), off


def enc_name(name):
    out = b""
    for part in name.split("."):
        if part:
            out += bytes([len(part)]) + part.encode()
    return out + b"\x00"


def a_record(ip):
    return b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton(ip)


def cname_record(target):
    data = enc_name(target)
    return b"\xc0\x0c" + struct.pack(">HHIH", 5, 1, 60, len(data)) + data


def reply(qid, name, answers, rcode=0, trunc=0):
    flags = 0x8180 | (rcode & 0x0F) | (0x0200 if trunc else 0)
    header = struct.pack(">HHHHHH", qid, flags, 1, len(answers), 0, 0)
    question = enc_name(name) + struct.pack(">HH", 1, 1)
    body = b"".join(answers) if not trunc else b""
    return header + question + body


CASES = {
    "ok.test": lambda i: reply(i, "ok.test", [a_record("198.18.0.1")]),
    "ok2.test": lambda i: reply(i, "ok2.test", [a_record("198.18.0.2")]),
    "multi.test": lambda i: reply(i, "multi.test",
                                  [a_record("198.18.0.1"), a_record("8.8.8.8")]),
    "multiok.test": lambda i: reply(i, "multiok.test",
                                    [a_record("198.18.0.1"), a_record("198.18.0.2")]),
    "cname.test": lambda i: reply(i, "cname.test",
                                  [cname_record("ok.test"), a_record("198.18.0.1")]),
    "nx.test": lambda i: reply(i, "nx.test", [], rcode=3),
    "nodata.test": lambda i: reply(i, "nodata.test", []),
    "servfail.test": lambda i: reply(i, "servfail.test", [], rcode=2),
    "refused.test": lambda i: reply(i, "refused.test", [], rcode=5),
    "trunc.test": lambda i: reply(i, "trunc.test", [a_record("198.18.0.1")], trunc=1),
}


def handle_udp(sock):
    while True:
        try:
            pkt, addr = sock.recvfrom(4096)
        except OSError:
            return
        if len(pkt) < 12:
            continue
        qid = struct.unpack(">H", pkt[:2])[0]
        name, _ = qname(pkt, 12)
        if name == "blackhole.test":
            continue
        builder = CASES.get(name)
        if builder is None:
            sock.sendto(reply(qid, name, [], rcode=3), addr)
            continue
        sock.sendto(builder(qid), addr)


def handle_tcp(conn):
    with conn:
        hdr = conn.recv(2)
        if len(hdr) < 2:
            return
        want = struct.unpack(">H", hdr)[0]
        pkt = b""
        while len(pkt) < want:
            chunk = conn.recv(want - len(pkt))
            if not chunk:
                return
            pkt += chunk
        qid = struct.unpack(">H", pkt[:2])[0]
        name, _ = qname(pkt, 12)
        # Only trunc.test is ever asked over TCP by the probe.
        msg = reply(qid, name, [a_record("198.18.0.1")])
        conn.sendall(struct.pack(">H", len(msg)) + msg)


def serve_tcp(sock):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        threading.Thread(target=handle_tcp, args=(conn,), daemon=True).start()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5353
    bind = os.environ.get("DNS_BIND", "127.0.0.1")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind((bind, port))

    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.bind((bind, port))
    tcp.listen(8)

    threading.Thread(target=serve_tcp, args=(tcp,), daemon=True).start()
    print(f"fixture listening on {bind}:{port}", flush=True)
    handle_udp(udp)


if __name__ == "__main__":
    main()

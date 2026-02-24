"""DNS beacon server for backup-monitor.gr — parses beacon queries and logs to PostgreSQL."""

from __future__ import annotations

import os
import signal
import sys
import time

import psycopg2
from dnslib import QTYPE, RCODE, DNSRecord, RR
from dnslib.server import BaseResolver, DNSServer

DATABASE_URL = os.environ["DATABASE_URL"]

BEACON_SUFFIX = ".b.backup-monitor.gr."


class BeaconResolver(BaseResolver):
    def __init__(self):
        self._conn = None
        self._backoff = 1

    def _get_conn(self):
        if self._conn is None or self._conn.closed:
            try:
                self._conn = psycopg2.connect(DATABASE_URL)
                self._conn.autocommit = True
                self._backoff = 1
                print("[dns] connected to PostgreSQL", flush=True)
            except Exception as e:
                print(f"[dns] DB connect failed: {e}", flush=True)
                self._conn = None
                time.sleep(self._backoff)
                self._backoff = min(self._backoff * 2, 60)
        return self._conn

    def _log_beacon(self, source_ip: str, source_port: int, query_name: str,
                    fingerprint: str, src_hash: str, tool_version: str):
        conn = self._get_conn()
        if conn is None:
            return
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO dns_beacon_log (source_ip, source_port, query_name, fingerprint, src_hash, tool_version) "
                    "VALUES (%s, %s, %s, %s, %s, %s)",
                    (source_ip, source_port, query_name, fingerprint, src_hash, tool_version),
                )
        except Exception as e:
            print(f"[dns] DB insert failed: {e}", flush=True)
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    def resolve(self, request, handler):
        reply = request.reply()
        reply.header.rcode = RCODE.NXDOMAIN

        qname = str(request.q.qname)
        source = handler.client_address

        if qname.lower().endswith(BEACON_SUFFIX.lower()):
            # Strip the suffix and split: <fingerprint>.<src_hash>.<version>
            prefix = qname[: -(len(BEACON_SUFFIX))].rstrip(".")
            parts = prefix.split(".")

            fingerprint = parts[0] if len(parts) >= 1 else None
            src_hash = parts[1] if len(parts) >= 2 else None
            tool_version = parts[2].replace("-", ".") if len(parts) >= 3 else None

            source_ip = source[0] if source else None
            source_port = source[1] if source and len(source) > 1 else None

            print(f"[dns] beacon: fp={fingerprint} hash={src_hash} ver={tool_version} from={source_ip}", flush=True)

            self._log_beacon(source_ip, source_port, qname, fingerprint, src_hash, tool_version)

        return reply


def main():
    resolver = BeaconResolver()
    server = DNSServer(resolver, port=5353, address="0.0.0.0", tcp=False)
    server.start_thread()
    print("[dns] listening on UDP :5353", flush=True)

    def shutdown(signum, frame):
        print("[dns] shutting down", flush=True)
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    while server.isAlive():
        time.sleep(1)


if __name__ == "__main__":
    main()

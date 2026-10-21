#!/usr/bin/env python3
"""
discodoor-announce.py - register a box with the Syncthing global discovery servers
without running Syncthing, so its public IP can be looked up by device ID.

Steps:
  1. generate a TLS client cert + key (once; reused on later runs)
  2. derive the Syncthing device ID from the cert
  3. announce to the discovery announce server
  4. print the lookup URL (and optionally check it)

Needs: python3 (stdlib only) and the openssl binary.

Examples:
  ./discodoor-announce.py                                     # setup if needed, announce, print lookup URL
  ./discodoor-announce.py -d                                  # same, with debug output
  ./discodoor-announce.py --check                             # also look yourself up after announcing
  ./discodoor-announce.py --id-only                           # just print the device ID
  ./discodoor-announce.py -c /usr/local/etc/discodoor -k      # cert lives in that dir
  ./discodoor-announce.py --cert st-cert.pem --key st-key.pem # name each file

The cert and key are reused if both exist; they are only generated when
both are missing (or with --force-new). If only one of them exists the
script stops rather than overwrite your identity.

Default location is cert.pem / key.pem in the current directory, so either
run it from the same directory each time or give -c / --cert / --key.
"""

import argparse
import base64
import hashlib
import json
import logging
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ANNOUNCE_URL = "https://discovery-announce-v4.syncthing.net/v2/"
LOOKUP_URL = "https://discovery-lookup.syncthing.net/v2/"
B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

log = logging.getLogger("discodoor")


# --------------------------------------------------------------------------
# 1. cert + key
# --------------------------------------------------------------------------
def ensure_cert(cert, key, force=False):
    have_cert, have_key = os.path.exists(cert), os.path.exists(key)
    log.debug("cert path %s (%s), key path %s (%s)",
              cert, "exists" if have_cert else "missing",
              key, "exists" if have_key else "missing")

    if have_cert and have_key and not force:
        log.info("reusing existing cert %s and key %s", cert, key)
        return cert, key

    if (have_cert or have_key) and not force:
        # Only one half present: don't silently overwrite an identity.
        sys.exit(f"found {'cert ' + cert if have_cert else 'key ' + key} "
                 f"but not its {'key ' + key if have_cert else 'cert ' + cert}.\n"
                 "Fix the paths, or use --force-new to make a new identity "
                 "(this changes the device ID).")

    for d in {os.path.dirname(cert), os.path.dirname(key)}:
        if d:
            os.makedirs(d, mode=0o700, exist_ok=True)
    log.info("generating new cert %s and key %s", cert, key)
    cmd = [
        "openssl", "req", "-x509",
        "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:secp384r1",
        "-nodes", "-keyout", key, "-out", cert,
        "-days", "7300", "-subj", "/CN=syncthing",
    ]
    log.debug("running: %s", " ".join(cmd))
    old_umask = os.umask(0o077)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    finally:
        os.umask(old_umask)
    if r.returncode != 0:
        sys.exit("openssl failed:\n" + r.stderr)
    log.debug("openssl stderr: %s", r.stderr.strip())
    os.chmod(key, 0o600)
    os.chmod(cert, 0o644)
    log.info("wrote %s and %s (key is your identity - keep it private)", cert, key)
    return cert, key


# --------------------------------------------------------------------------
# 2. device ID
# --------------------------------------------------------------------------
def luhn32(s):
    factor, total = 1, 0
    for ch in s:
        addend = factor * B32.index(ch)
        factor = 1 if factor == 2 else 2
        total += addend // 32 + addend % 32
    return B32[(32 - total % 32) % 32]


def device_id(cert_path):
    with open(cert_path) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    digest = hashlib.sha256(der).digest()
    log.debug("cert SHA-256: %s", digest.hex())
    raw = base64.b32encode(digest).decode().rstrip("=")
    log.debug("base32 (52 chars): %s", raw)
    chunks = [raw[i:i + 13] for i in range(0, 52, 13)]
    with_check = "".join(c + luhn32(c) for c in chunks)
    log.debug("with luhn check chars: %s", with_check)
    return "-".join(with_check[i:i + 7] for i in range(0, 56, 7))


# --------------------------------------------------------------------------
# 3. announce
# --------------------------------------------------------------------------
def tls_context(insecure, cert=None, key=None):
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    if cert:
        ctx.load_cert_chain(cert, key)
    return ctx


def http(req, ctx, timeout):
    """Return (status, headers, body) without raising on HTTP errors."""
    log.debug("> %s %s", req.get_method(), req.full_url)
    for k, v in req.header_items():
        log.debug(">   %s: %s", k, v)
    if req.data:
        log.debug(">   body: %s", req.data.decode())
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
            status, headers, body = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, headers, body = e.code, e.headers, e.read()
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", e)
        if isinstance(reason, ssl.SSLCertVerificationError):
            sys.exit(f"TLS verification failed: {reason}\n"
                     "Fix your CA bundle (e.g. reinstall ca-certificates / "
                     "pkg install ca_root_nss) or rerun with -k.")
        sys.exit(f"request to {req.full_url} failed: {reason}")
    log.debug("< HTTP %s", status)
    for k, v in headers.items():
        log.debug("<   %s: %s", k, v)
    if body:
        log.debug("<   body: %s", body.decode(errors="replace").strip())
    return status, headers, body


def announce(url, cert, key, addresses, insecure, timeout):
    log.info("announcing %s to %s", addresses, url)
    ctx = tls_context(insecure, cert, key)
    req = urllib.request.Request(
        url,
        data=json.dumps({"addresses": addresses}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    status, headers, body = http(req, ctx, timeout)
    if status == 204:
        again = headers.get("Reannounce-After")
        log.info("announce accepted (204)%s",
                 f", reannounce after {again}s" if again else "")
        return True, again
    retry = headers.get("Retry-After")
    msg = body.decode(errors="replace").strip()
    print(f"announce FAILED: HTTP {status} {msg}"
          + (f" (server says retry after {retry}s - don't retry before then)"
             if retry else ""), file=sys.stderr)
    return False, retry


# --------------------------------------------------------------------------
# 4. lookup
# --------------------------------------------------------------------------
def lookup_url(base, dev):
    return base + "?" + urllib.parse.urlencode({"device": dev})


def lookup(url, insecure, timeout, tries=3, pause=10):
    ctx = tls_context(insecure)
    for i in range(1, tries + 1):
        log.info("lookup attempt %d/%d", i, tries)
        status, _, body = http(urllib.request.Request(url), ctx, timeout)
        if status == 200:
            data = json.loads(body)
            return data.get("addresses", [])
        if i < tries:
            log.info("got HTTP %s, waiting %ds (servers can take a moment "
                     "to sync)", status, pause)
            time.sleep(pause)
    return None


# --------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(
        description="Announce this box to Syncthing global discovery "
                    "without running Syncthing.")
    p.add_argument("-d", "--debug", action="store_true",
                   help="show debug output (commands, HTTP headers, bodies)")
    p.add_argument("-c", "--cert-dir", "--dir", dest="dir", default=".",
                   help="directory where cert.pem/key.pem are created and "
                        "kept (default: the directory you run the script from)")
    p.add_argument("--cert", metavar="FILE",
                   help="path/name of the certificate "
                        "(default: <cert-dir>/cert.pem)")
    p.add_argument("--key", metavar="FILE",
                   help="path/name of the private key "
                        "(default: <cert-dir>/key.pem)")
    p.add_argument("--force-new", action="store_true",
                   help="generate a NEW identity even if one exists "
                        "(changes the device ID!)")
    p.add_argument("--address", action="append",
                   help="address to announce (repeatable; "
                        "default tcp://0.0.0.0:22000 - server fills in your IP)")
    p.add_argument("--announce-url", default=ANNOUNCE_URL)
    p.add_argument("--lookup-url", default=LOOKUP_URL)
    p.add_argument("-k", "--insecure", action="store_true",
                   help="don't verify the discovery servers' TLS certs")
    p.add_argument("--check", action="store_true",
                   help="after announcing, look yourself up and show the result")
    p.add_argument("--id-only", action="store_true",
                   help="set up cert if needed, print device ID, don't announce")
    p.add_argument("--timeout", type=int, default=20)
    a = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if a.debug else logging.WARNING,
        format="[%(levelname)s] %(message)s")
    if a.debug:
        log.setLevel(logging.DEBUG)

    cert = a.cert or os.path.join(a.dir, "cert.pem")
    key = a.key or os.path.join(a.dir, "key.pem")
    cert, key = ensure_cert(cert, key, a.force_new)
    dev = device_id(cert)

    if a.id_only:
        print(dev)
        return

    addresses = a.address or ["tcp://0.0.0.0:22000"]
    ok, _ = announce(a.announce_url, cert, key, addresses,
                     a.insecure, a.timeout)

    url = lookup_url(a.lookup_url, dev)
    print(f"device ID : {dev}")
    print(f"lookup URL: {url}")
    print(f"query with: curl -s{'k' if a.insecure else ''} '{url}'")

    if not ok:
        sys.exit(1)

    if a.check:
        addrs = lookup(url, a.insecure, a.timeout)
        if addrs is None:
            print("lookup: not found yet - try the URL again in a minute",
                  file=sys.stderr)
            sys.exit(2)
        print("lookup result:")
        for x in addrs:
            print(f"  {x}")


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""Throwaway servers for kultrdl-probe in CI.

FTP on 2121, explicit FTPS on 2122, implicit FTPS on 2123 (self-signed
certificate) and SFTP on 2222, all with the user "kultr" / "secret". SFTP
also accepts the client keys written to $KULTRDL_TEST_KEYS (default
/tmp/kultrdl-test-keys) in the formats people bring: OpenSSH with and
without a passphrase, PEM (PKCS#1 / SEC1) and PKCS#8.
"""

import asyncio
import logging
import os
import subprocess
import sys
import tempfile
import threading

import asyncssh
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

ROOT = os.path.join(tempfile.gettempdir(), "kultrdl-server-root")
KEYS = os.environ.get("KULTRDL_TEST_KEYS", os.path.join(tempfile.gettempdir(), "kultrdl-test-keys"))
USER, PASSWORD = "kultr", "secret"


def log(*parts):
    print(*parts, flush=True)


def make_keys():
    os.makedirs(KEYS, exist_ok=True)
    # (file name, algorithm, format, passphrase, cipher); names ending in
    # "-pass" are read with the passphrase "keypass".
    wanted = [
        ("ed25519", "ssh-ed25519", "openssh", None, None),
        ("ecdsa", "ecdsa-sha2-nistp256", "openssh", None, None),
        ("rsa", "ssh-rsa", "openssh", None, None),
        ("ed25519-pass", "ssh-ed25519", "openssh", "keypass", "aes256-ctr"),
        ("rsa-pass", "ssh-rsa", "openssh", "keypass", "aes256-ctr"),
        ("ecdsa-gcm-pass", "ecdsa-sha2-nistp256", "openssh", "keypass", "aes256-gcm@openssh.com"),
        ("ed25519-cbc-pass", "ssh-ed25519", "openssh", "keypass", "aes128-cbc"),
        ("rsa-pem", "ssh-rsa", "pkcs1-pem", None, None),
        ("rsa-pem-pass", "ssh-rsa", "pkcs1-pem", "keypass", "aes256-cbc"),
        ("ecdsa-pem", "ecdsa-sha2-nistp384", "pkcs1-pem", None, None),
        ("pkcs8-ed25519", "ssh-ed25519", "pkcs8-pem", None, None),
    ]
    public = []
    for name, alg, fmt, passphrase, cipher in wanted:
        try:
            key = asyncssh.generate_private_key(alg, key_size=2048) if alg == "ssh-rsa" else asyncssh.generate_private_key(alg)
            path = os.path.join(KEYS, name)
            if passphrase:
                key.write_private_key(path, format_name=fmt, passphrase=passphrase, cipher_name=cipher)
            else:
                key.write_private_key(path, format_name=fmt)
            with open(path) as f:
                log(f"key {name}: {f.readline().strip()}")
            public.append(key.export_public_key().decode().strip())
        except Exception as error:  # A missing key skips its check; the servers still start.
            log(f"key {name}: not written ({error})")
    return asyncssh.import_authorized_keys("\n".join(public) + "\n")


def make_certificate(directory):
    cert = os.path.join(directory, "cert.pem")
    key = os.path.join(directory, "key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
         "-days", "2", "-subj", "/CN=kultrdl-test"],
        check=True, capture_output=True,
    )
    both = os.path.join(directory, "server.pem")
    with open(both, "w") as out:
        out.write(open(cert).read())
        out.write(open(key).read())
    return both


class ImplicitTLSHandler(TLS_FTPHandler):
    """FTPS on its own port: TLS from the first byte, then the usual FTP."""

    def handle(self):
        self.secure_connection(self.ssl_context)

    def handle_ssl_established(self):
        TLS_FTPHandler.handle(self)


def ftp_servers(pem):
    authorizer = DummyAuthorizer()
    authorizer.add_user(USER, PASSWORD, ROOT, perm="elradfmwMT")

    plain = type("Plain", (FTPHandler,), {})
    plain.authorizer = authorizer
    plain.passive_ports = range(30000, 30100)

    explicit = type("Explicit", (TLS_FTPHandler,), {})
    explicit.authorizer = authorizer
    explicit.certfile = pem
    explicit.tls_control_required = True
    explicit.tls_data_required = True
    explicit.passive_ports = range(30100, 30200)

    implicit = type("Implicit", (ImplicitTLSHandler,), {})
    implicit.authorizer = authorizer
    implicit.certfile = pem
    implicit.passive_ports = range(30200, 30300)

    servers = [
        FTPServer(("127.0.0.1", 2121), plain),
        FTPServer(("127.0.0.1", 2122), explicit),
        FTPServer(("127.0.0.1", 2123), implicit),
    ]
    log("FTP 2121, FTPS 2122, implicit FTPS 2123")
    # They share one IO loop; serving one serves all three.
    servers[0].serve_forever(handle_exit=False)


class SSHServer(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == USER and password == PASSWORD


async def sftp_server(authorized):
    host_key = asyncssh.generate_private_key("ssh-ed25519")
    await asyncssh.listen(
        "127.0.0.1", 2222,
        server_host_keys=[host_key],
        authorized_client_keys=authorized,
        server_factory=SSHServer,
        sftp_factory=lambda chan: asyncssh.SFTPServer(chan, chroot=ROOT),
        allow_scp=False,
    )
    log("SFTP 2222, host key", host_key.get_fingerprint())
    await asyncio.Event().wait()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s", stream=sys.stdout)
    logging.getLogger("asyncssh").setLevel(logging.WARNING)
    os.makedirs(ROOT, exist_ok=True)
    work = tempfile.mkdtemp(prefix="kultrdl-servers-")
    authorized = make_keys()
    pem = make_certificate(work)
    threading.Thread(target=ftp_servers, args=(pem,), daemon=True).start()
    try:
        asyncio.run(sftp_server(authorized))
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()

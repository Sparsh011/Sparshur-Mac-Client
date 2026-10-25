#!/usr/bin/env python3
"""Android -> the signed native app, no browser/Python receiver/legacy helper.

The debug app exposes management only through inherited anonymous pipes. The QR
bundle is forwarded to trusted adb stdin, never printed or put in an argument.
This deliberately performs a fresh pairing with the emulator using the existing
Mac identity. It changes the active phone/pairing epoch, not the Mac identity.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT.parent / 'SparshurAndroid'
ADB = Path.home() / 'Library/Android/sdk/platform-tools/adb'
DEFAULT_APP = Path('/private/tmp/SparshurDerivedData/Build/Products/Debug/Sparshur.app/Contents/MacOS/Sparshur')


def adb(*args, **kwargs):
    return subprocess.run([str(ADB), *args], check=True, **kwargs)


class NativeApp:
    def __init__(self, binary, memory_only=False):
        read_fd, write_fd = os.pipe()
        self.process = subprocess.Popen(
            [str(binary), '--integration-reply-fd', str(write_fd), *(['--integration-memory'] if memory_only else [])],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            pass_fds=(write_fd,), bufsize=0)
        os.close(write_fd)
        self.pipe = os.fdopen(read_fd, 'rb', buffering=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.pipe, selectors.EVENT_READ)
        self.buffer = b''

    def call(self, op, timeout=45, **fields):
        self.process.stdin.write(json.dumps(dict(op=op, **fields)).encode() + b'\n')
        until = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            if time.monotonic() > until or not self.selector.select(timeout=1):
                if self.process.poll() is not None or time.monotonic() > until:
                    raise RuntimeError('Native app did not answer its trusted test pipe')
                continue
            chunk = self.pipe.read(4096)
            if not chunk:
                raise RuntimeError('Native app stopped')
            self.buffer += chunk
            if len(self.buffer) > 1_000_000:
                raise RuntimeError('Invalid native test response')
        line, self.buffer = self.buffer.split(b'\n', 1)
        result = json.loads(line)
        if result.get('ok') is not True:
            raise RuntimeError('Native operation failed: ' + result.get('status', 'receiver unavailable'))
        return result

    def close(self):
        try:
            if self.process.poll() is None:
                try:
                    self.call('quit', timeout=8)
                    self.process.wait(timeout=8)
                except (RuntimeError, BrokenPipeError, subprocess.TimeoutExpired):
                    pass
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=5)
            self.selector.close()
            self.pipe.close()
            self.process.stdin.close()


def instrument(test=None, **args):
    command = ['shell', 'am', 'instrument', '-w', '-r', '-e', 'receiverHost', '10.0.2.2']
    if test:
        command += ['-e', 'class', test]
    for key, value in args.items():
        command += ['-e', key, value]
    result = adb(*command, 'com.sparsh.sparshur.test/androidx.test.runner.AndroidJUnitRunner',
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if 'FAILURES!!!' in result.stdout or 'OK (' not in result.stdout:
        # Instrumentation diagnostics contain test failures, not the pairing bundle.
        print(result.stdout[-8000:])
        raise RuntimeError('Android integration failed')
    print(next(line for line in result.stdout.splitlines() if line.startswith('OK (')))


def check_native_transport_bounds():
    # A slow/incomplete HTTP body must time out without entering the protocol engine.
    with socket.create_connection(('127.0.0.1', 8787), timeout=7) as peer:
        peer.sendall(b'POST /message HTTP/1.1\r\nHost: localhost:8787\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{')
        assert peer.recv(4096).startswith(b'HTTP/1.1 408 ')
    peers = []
    try:
        for _ in range(8):
            peer = socket.create_connection(('127.0.0.1', 8787), timeout=2)
            peer.sendall(b'GET /health HTTP/1.1\r\nHost: localhost:8787\r\n')
            peers.append(peer)
        time.sleep(0.1)
        with socket.create_connection(('127.0.0.1', 8787), timeout=2) as excess:
            excess.sendall(b'GET /health HTTP/1.1\r\nHost: localhost:8787\r\n\r\n')
            try:
                assert excess.recv(4096) == b''
            except ConnectionResetError:
                pass
    finally:
        for peer in peers:
            peer.close()
    time.sleep(0.1)
    print('Native request deadline and eight-connection bound passed.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    parser.add_argument('--memory-only', action='store_true', help='Test native transport with a temporary in-memory identity; does not validate Keychain migration')
    parser.add_argument('--authorize-keychain', action='store_true', help='Explicitly allow the app to show macOS authorization for its existing identity')
    options = parser.parse_args()
    # Do not replace another running recipient or create simultaneous writers.
    with socket.socket() as check:
        if check.connect_ex(('127.0.0.1', 8787)) == 0:
            raise RuntimeError('Quit the current recipient before this explicit integration run')
    adb('install', '-r', str(ANDROID / 'app/build/outputs/apk/debug/app-debug.apk'), stdout=subprocess.DEVNULL)
    adb('install', '-r', str(ANDROID / 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'), stdout=subprocess.DEVNULL)
    app = NativeApp(options.app, options.memory_only)
    try:
        try:
            initial = app.call('ready')
        except RuntimeError:
            if not options.authorize_keychain:
                raise
            print('Approve the macOS Keychain prompt for Sparshur; no item is replaced or exported.', flush=True)
            app.call('authorize', timeout=120)
            initial = app.call('ready')
        print('Signed native listener ready; ' + ('explicit memory-only test identity.' if options.memory_only else 'existing Mac identity loaded.'))
        check_native_transport_bounds()
        pairing = app.call('new_pairing', host='10.0.2.2')
        adb('shell', 'run-as', 'com.sparsh.sparshur', 'tee', 'cache/bridge-pairing-test.json',
            input=pairing['bundle'].encode(), stdout=subprocess.DEVNULL)
        del pairing
        instrument()
        stats = app.call('stats')
        assert stats['paired'] >= 2 and stats['comparisons'] >= 2 and stats['duplicates'] >= 2
        assert stats['rejected'] >= 2 and stats['qr_visible'] is False
        assert stats['fingerprint'] == initial['fingerprint']
        app.call('pause')
        assert app.call('stats')['listening'] is False
        app.call('resume')
        app.call('ready')
        assert app.call('stats')['listening'] is True
        print('Actual Android deliveries decrypted natively; tampering rejected; QR cleared; pause/resume passed.')
        if options.memory_only:
            print('Memory-only transport proof passed. Real Keychain access/write/restart remains unverified in this mode.')
            return
        saved = app.call('stats')
        app.close()
        app = NativeApp(options.app)
        restored = app.call('ready')
        assert restored['fingerprint'] == saved['fingerprint']
        assert restored['highest'] == saved['highest']
        instrument('com.sparsh.sparshur.PairedDeliveryTest#retriesSavedEnvelopeAgainstNativeRestart', nativeReplayOnly='true')
        replayed = app.call('stats')
        assert replayed['paired'] == 0 and replayed['duplicates'] == 1
        print('Fresh native app restored the same identity/counter; Android verified its duplicate receipt; no inbox redisplay.')
        print('Emulator proof only. Physical-phone camera/hotspot and interactive Mac lifecycle checks remain separate.')
    finally:
        app.close()
        adb('shell', 'run-as', 'com.sparsh.sparshur', 'rm', '-f',
            'cache/bridge-pairing-test.json', 'cache/bridge-paired-retry.json', stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()

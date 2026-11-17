"""Run a compiled Barcode module probe against an ephemeral loopback Modbus peer."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
from concurrent.futures import ThreadPoolExecutor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('prefix')
    args = parser.parse_args()
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(8)
        def serve():
            with listener.accept()[0] as connection:
                connection.settimeout(5)
                request = b''
                while len(request) < 12:
                    chunk = connection.recv(12 - len(request))
                    assert chunk, 'Client closed before sending the request'
                    request += chunk
                # Actual client code must use the configured slave and unchanged OK register.
                assert request[6:] == bytes([17, 6, 0, 4, 0, 99]), request.hex()
                connection.sendall(request)
                return request
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            environment = dict(os.environ, **{args.prefix + '_MODBUS_HOST': '127.0.0.1',
                args.prefix + '_MODBUS_PORT': str(listener.getsockname()[1]), args.prefix + '_MODBUS_SLAVE': '17'})
            result = subprocess.run([str(args.probe.resolve())], env=environment, capture_output=True, text=True, timeout=12)
            assert result.returncode == 0, result
            future.result(timeout=10)
            assert '127.0.0.1' in result.stdout, result.stdout
    print('PASS:', args.prefix, 'actual Haskell/C++ host, port and slave settings reach loopback peer')


if __name__ == '__main__':
    main()

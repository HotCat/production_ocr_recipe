"""Verify real compiled client I/O against loopback only; debug must use no socket."""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

probe, prefix = sys.argv[1:]
def receive(connection, count):
    data = b''
    while len(data) < count:
        part = connection.recv(count-len(data))
        assert part, 'unexpected EOF'
        data += part
    return data

for debug in ['1', '0']:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(1 if debug == '1' else 8)
        env = dict(os.environ, OCR_DEBUG_MODE=debug, **{
            prefix+'_MODBUS_HOST':'127.0.0.1',
            prefix+'_MODBUS_PORT':str(listener.getsockname()[1]),
            prefix+'_MODBUS_SLAVE':'17'})
        def serve():
            with listener.accept()[0] as connection:
                connection.settimeout(5)
                for expected, value in [(bytes([3,0,0,0,1]),77),
                                        (bytes([6,0,4,0,99]),None),
                                        (bytes([6,0,2,0,88]),None),
                                        (bytes([3,0,0,0,1]),0)]:
                    header = receive(connection, 7)
                    length = struct.unpack('>H',header[4:6])[0]
                    payload = receive(connection, length-1)
                    assert header[6] == 17 and payload == expected, (header.hex(),payload.hex())
                    response = payload if value is None else bytes([3,2])+struct.pack('>H',value)
                    connection.sendall(header[:4]+struct.pack('>H',len(response)+1)+header[6:]+response)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(serve) if debug == '0' else None
            result = subprocess.run([str(Path(probe).resolve())],env=env,capture_output=True,text=True,timeout=20)
            assert result.returncode == 0, (result.stdout,result.stderr)
            if future:
                future.result(timeout=10)
            else:
                try:
                    connection,_ = listener.accept()
                except socket.timeout:
                    pass
                else:
                    connection.close()
                    raise AssertionError('debug mode connected to Modbus')
                assert result.stdout.count('模拟PLC输出 OK') == 1, result.stdout
                assert result.stdout.count('模拟PLC输出 NG') == 1, result.stdout
    print('PASS:',prefix, 'debug offline' if debug == '1' else 'production read/OK/NG unchanged')

#!/usr/bin/env python3
"""Probe classic DNS from a LAN client; does not prove absence of encrypted app DoH."""
import argparse
import ipaddress
import json
import secrets
import socket
import struct


def query(server, name, tcp=False):
    ident = secrets.randbits(16)
    data = struct.pack('!HHHHHH', ident, 0x100, 1, 0, 0, 0)
    data += b''.join(bytes([len(part)]) + part.encode('ascii') for part in name.split('.'))
    data += b'\0' + struct.pack('!HH', 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
        sock.settimeout(8)
        if tcp:
            sock.connect((server, 53))
            sock.sendall(struct.pack('!H', len(data)) + data)
            def receive(size):
                answer = b''
                while len(answer) < size:
                    part = sock.recv(size - len(answer))
                    if not part:
                        raise ValueError('DNS TCP closed early')
                    answer += part
                return answer
            response = receive(struct.unpack('!H', receive(2))[0])
        else:
            sock.sendto(data, (server, 53))
            response, peer = sock.recvfrom(16384)
            if peer != (server, 53):
                raise ValueError('Unexpected DNS peer')
    if len(response) < 12 or struct.unpack('!H', response[:2])[0] != ident or not response[2] & 0x80:
        raise ValueError('Invalid DNS reply')
    qd, an = struct.unpack('!HH', response[4:8])
    def skip_name(offset):
        for _ in range(128):
            size = response[offset]
            offset += 1
            if size & 0xC0 == 0xC0:
                return offset + 1
            if size == 0:
                return offset
            if size > 63:
                raise ValueError('Malformed DNS name')
            offset += size
        raise ValueError('Malformed DNS name')
    offset, addresses = 12, []
    for _ in range(qd):
        offset = skip_name(offset) + 4
    for _ in range(an):
        offset = skip_name(offset)
        kind, cls, ttl, size = struct.unpack('!HHIH', response[offset:offset + 10])
        offset += 10
        if kind == 1 and cls == 1 and size == 4:
            addresses.append(socket.inet_ntoa(response[offset:offset + 4]))
        offset += size
    return {'server': server, 'transport': 'TCP' if tcp else 'UDP',
            'rcode': response[3] & 15, 'addresses': addresses}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--router', default='192.168.1.1')
    parser.add_argument('--external-dns', default='8.8.8.8')
    parser.add_argument('--local-name', help='Optional local A record, expected to equal the router IP')
    args = parser.parse_args()
    for value in (args.router, args.external_dns):
        ipaddress.IPv4Address(value)
    results, passed = [], True
    for server in (args.router, args.external_dns):
        for tcp in (False, True):
            try:
                positive = query(server, 'www.iana.org', tcp)
                if positive['rcode'] or not positive['addresses']:
                    raise ValueError('Positive DNS query did not return an address')
                for address in positive['addresses']:
                    if ipaddress.ip_address(address) not in ipaddress.ip_network('198.18.0.0/16'):
                        raise ValueError('Expected a protected LAN fake-IP in 198.18.0.0/16')
                fresh = query(server, 'mm-dns-' + secrets.token_hex(6) + '.example.net', tcp)
                if fresh['rcode'] not in (0, 3):
                    raise ValueError('Fresh DNS query failed')
                if args.local_name:
                    local = query(server, args.local_name, tcp)
                    if local['addresses'] != [args.router]:
                        raise ValueError('Local record was not resolved through the router')
                results.append({'server': server, 'transport': positive['transport'], 'ok': True})
            except (OSError, ValueError, IndexError, struct.error) as error:
                passed = False
                results.append({'server': server, 'transport': 'TCP' if tcp else 'UDP', 'ok': False, 'error': str(error)})
    print(json.dumps({'ok': passed, 'scope': 'client-classic-DNS-only', 'results': results}, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())

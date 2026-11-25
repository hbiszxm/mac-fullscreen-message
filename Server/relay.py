#!/usr/bin/env python3
"""TLS relay using only Python 3.6+ standard library; never logs message bodies."""
import asyncio
import hashlib
import json
import os
import re
import ssl
import struct
import time
import uuid

MAX = 300000
CLIENTS, PENDING = {}, {}
CONFIG = json.load(open(os.environ.get('RELAY_CONFIG', 'private/config.json')))
REGISTRY_PATH = CONFIG.get('registry', 'private/devices.json')
REGISTRY = json.load(open(REGISTRY_PATH)) if os.path.exists(REGISTRY_PATH) else {}

def valid_id(value):
    try:
        uuid.UUID(value)
        return isinstance(value, str) and len(value) == 36
    except (ValueError, TypeError, AttributeError):
        return False

def identity(device, key):
    if not isinstance(key, str) or not re.match(r'^[A-Za-z0-9-]{32,128}$', key):
        return False
    hashed = hashlib.sha256(key.encode()).hexdigest()
    if device in REGISTRY:
        return REGISTRY[device] == hashed
    if len(REGISTRY) >= 10000:
        return False
    REGISTRY[device] = hashed
    with open(REGISTRY_PATH + '.tmp', 'w') as f:
        json.dump(REGISTRY, f)
    os.chmod(REGISTRY_PATH + '.tmp', 0o600)
    os.replace(REGISTRY_PATH + '.tmp', REGISTRY_PATH)
    return True

async def write(client, packet):
    body = json.dumps(packet, ensure_ascii=False, separators=(',', ':')).encode()
    writer = client['writer']
    try:
        closing = writer.transport.is_closing()
        buffered = writer.transport.get_write_buffer_size()
    except AttributeError:
        raise ConnectionError('TLS transport is closed')
    if closing:
        raise ConnectionError('Connection is closed')
    if buffered > MAX * 4:
        writer.close()
        raise ConnectionError('Slow receiver')
    writer.write(struct.pack('!I', len(body)) + body)
    await asyncio.wait_for(writer.drain(), 5)

async def broadcast():
    for c in list(CLIENTS.values()):
        try:
            await write(c, {'type': 'peers', 'peers': [{'id': p['id'], 'name': p['name']}
                        for p in CLIENTS.values() if p is not c]})
        except (ConnectionError, OSError, asyncio.TimeoutError):
            c['writer'].close()

async def finish(request, entry):
    try:
        result = await asyncio.wait_for(entry['future'], 10)
    except asyncio.TimeoutError:
        result = (False, '对方未确认收到')
    finally:
        if PENDING.get(request) is entry:
            del PENDING[request]
    try:
        await write(entry['sender'], {'type': 'result', 'requestID': request, 'ok': result[0], 'error': result[1]})
    except (ConnectionError, OSError, asyncio.TimeoutError):
        pass

def disconnect(c):
    c['writer'].close()
    for p in list(PENDING.values()):
        if (p['sender'] is c or p['target'] is c) and not p['future'].done():
            p['future'].set_result((False, '设备已离线'))

async def handle(reader, writer):
    c = {'writer': writer}
    rate_start, rate = time.monotonic(), 0
    try:
        while True:
            timeout = 35 if 'id' in c else 10
            header = await asyncio.wait_for(reader.readexactly(4), timeout)
            size = struct.unpack('!I', header)[0]
            if not 0 < size <= MAX:
                break
            data = await asyncio.wait_for(reader.readexactly(size), 10)
            p = json.loads(data.decode())
            if not isinstance(p, dict):
                break
            now = time.monotonic()
            if now - rate_start > 1:
                rate_start, rate = now, 0
            rate += 1
            if rate > 100:
                break
            if 'id' not in c:
                device, name = p.get('id'), p.get('name')
                if (p.get('type') != 'hello' or not isinstance(device, str) or
                    not re.match(r'^[A-Za-z0-9-]{8,64}$', device) or not isinstance(name, str) or
                    not name.strip() or len(name) > 120 or len(CLIENTS) >= 200 or
                    not identity(device, p.get('deviceKey'))):
                    await write(c, {'type': 'error', 'error': '设备身份无效'})
                    break
                if device in CLIENTS:
                    disconnect(CLIENTS[device])
                c.update(id=device, name=name.strip())
                CLIENTS[device] = c
                await write(c, {'type': 'ready'})
                await broadcast()
                continue
            if CLIENTS.get(c['id']) is not c:
                break
            if p.get('type') == 'ping':
                await write(c, {'type': 'pong'})
            elif p.get('type') == 'ack':
                entry = PENDING.get(p.get('requestID'))
                if entry and entry['target'] is c and not entry['future'].done():
                    entry['future'].set_result((True, None))
            elif p.get('type') == 'send':
                request, m = p.get('requestID'), p.get('message')
                if not valid_id(request):
                    break
                error = None
                if (not isinstance(m, dict) or not isinstance(m.get('text'), str) or
                    not valid_id(m.get('id')) or not isinstance(m.get('sentAt'), (float, int)) or
                    m.get('kind', 'alert') not in ('alert', 'accepted', 'rejected') or
                    (m.get('kind') in ('accepted', 'rejected') and not valid_id(m.get('relatedMessageID'))) or
                    len(json.dumps(m, ensure_ascii=False).encode()) > 262144):
                    error = '消息格式无效'
                target = CLIENTS.get(p.get('to'))
                if not target or target is c:
                    error = '接收电脑不在线'
                if request in PENDING or len(PENDING) >= 1000 or sum(1 for e in PENDING.values() if e['sender'] is c) >= 50:
                    error = '发送过于频繁或重复请求'
                if error:
                    await write(c, {'type': 'result', 'requestID': request, 'ok': False, 'error': error})
                    continue
                future = asyncio.get_event_loop().create_future()
                entry = {'sender': c, 'target': target, 'future': future}
                PENDING[request] = entry
                asyncio.ensure_future(finish(request, entry))
                m['sender'], m['senderInstanceID'] = c['name'], c['id']
                try:
                    await write(target, {'type': 'message', 'requestID': request, 'message': m})
                except (ConnectionError, OSError, asyncio.TimeoutError):
                    if not future.done():
                        future.set_result((False, '接收电脑已离线'))
    except (ConnectionError, OSError, asyncio.TimeoutError, asyncio.IncompleteReadError, ValueError, TypeError):
        pass
    finally:
        disconnect(c)
        if c.get('id') and CLIENTS.get(c['id']) is c:
            del CLIENTS[c['id']]
            await broadcast()

if __name__ == '__main__':
    context = ssl.SSLContext(ssl.PROTOCOL_TLS)
    context.options |= ssl.OP_NO_TLSv1 | ssl.OP_NO_TLSv1_1
    context.load_cert_chain(CONFIG['cert'], CONFIG['key'])
    loop = asyncio.get_event_loop()
    server = loop.run_until_complete(asyncio.start_server(handle, CONFIG.get('host', '0.0.0.0'),
                                                         CONFIG.get('port', 18443), ssl=context))
    print('Fullscreen relay ready on port {}'.format(CONFIG.get('port', 18443)), flush=True)
    loop.run_forever()

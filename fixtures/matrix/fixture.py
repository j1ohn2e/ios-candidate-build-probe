"""Own a loopback Synapse fixture and drive the peer through Matrix Client-Server APIs."""

from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
import hashlib
from importlib.metadata import version
from io import BytesIO
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from threading import Event
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from PIL import Image, ImageDraw


SERVER = '127.0.0.1:8090'
BASE = 'http://' + SERVER
CLIENT = '/_matrix/client/v3'
USER = 'ios_probe'
ROOM_NAME = 'iOS native Matrix probe'
HISTORY = 'Native iOS fixture history'
OUTGOING = 'iOS native outbound'
REPLY = 'Peer reply after iOS send'
RESTORED = 'iOS restored session online'
RESTART_REPLY = 'Peer reply after iOS restart'
FILE_NAME = 'probe-note.txt'
FILE_BYTES = b'Isolated Matrix attachment content for iOS.\n'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Matrix:
    def __init__(self):
        self.opener = build_opener(ProxyHandler({}), NoRedirect)

    def request(self, method, path, data=None, token=None, content_type=None):
        headers = {}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        if isinstance(data, dict):
            data = json.dumps(data).encode()
            content_type = 'application/json'
        if content_type:
            headers['Content-Type'] = content_type
        request = Request(BASE + path, data=data, headers=headers, method=method)
        with self.opener.open(request, timeout=10) as response:
            return response.read()

    def call(self, method, path, data=None, token=None):
        return json.loads(self.request(method, path, data, token))

    def register(self, name, password, device):
        body = {'username': name, 'password': password, 'device_id': device}
        try:
            return self.call('POST', CLIENT + '/register', body)
        except HTTPError as error:
            if error.code != 401:
                raise
            challenge = json.load(error)
        if not any(flow['stages'] == ['m.login.dummy'] for flow in challenge['flows']):
            raise RuntimeError('Unexpected loopback registration challenge')
        body['auth'] = {'type': 'm.login.dummy', 'session': challenge['session']}
        return self.call('POST', CLIENT + '/register', body)

    def upload(self, name, mime, body, token):
        query = urlencode({'filename': name})
        return json.loads(self.request('POST', '/_matrix/media/v3/upload?' + query, body, token, mime))['content_uri']

    def download(self, uri, token):
        media = urlsplit(uri)
        if media.scheme != 'mxc' or media.netloc != SERVER or not media.path or '/' in media.path[1:]:
            raise RuntimeError('Expected an MXC URL from the owned loopback Synapse')
        return self.request('GET', '/_matrix/client/v1/media/download/' + quote(SERVER, safe='') + media.path, token=token)


def announce(message):
    print('MATRIX_PROBE ' + message, flush=True)


def start_server(directory, api):
    config = directory / 'homeserver.json'
    logging_config = directory / 'logging.json'
    logging_config.write_text(json.dumps({
        'version': 1,
        'formatters': {'plain': {'format': '%(message)s'}},
        'handlers': {'access': {'class': 'logging.FileHandler', 'formatter': 'plain',
                                'filename': str(directory / 'access.log'), 'encoding': 'utf-8'}},
        'loggers': {'synapse.access.http': {'level': 'INFO', 'handlers': ['access'], 'propagate': False}},
    }), encoding='utf-8')
    config.write_text(json.dumps({
        'server_name': SERVER, 'public_baseurl': BASE + '/', 'report_stats': False,
        'listeners': [{'port': 8090, 'type': 'http', 'bind_addresses': ['127.0.0.1'],
                       'resources': [{'names': ['client'], 'compress': False}]}],
        'database': {'name': 'sqlite3', 'args': {'database': str(directory / 'homeserver.db')}},
        'log_config': str(logging_config),
        'signing_key_path': str(directory / 'signing.key'), 'media_store_path': str(directory / 'media'),
        'registration_shared_secret': secrets.token_hex(32),
        'enable_registration': True, 'enable_registration_without_verification': True,
        'trusted_key_servers': [], 'suppress_key_server_warning': True,
        'federation_domain_whitelist': [], 'url_preview_enabled': False,
    }), encoding='utf-8')
    command = [sys.executable, '-m', 'synapse.app.homeserver', '-c', str(config)]
    with (directory / 'synapse.log').open('wb') as log:
        subprocess.run(command + ['--generate-missing-configs'], cwd=directory, stdout=log, stderr=log,
                       check=True, timeout=90)
        process = subprocess.Popen(command, cwd=directory, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 70
        while process.poll() is None and time.monotonic() < deadline:
            try:
                if api.call('GET', '/_matrix/client/versions')['versions']:
                    announce(f'synapse={version("matrix-synapse")} listener=loopback db=sqlite')
                    return process
            except URLError:
                time.sleep(0.5)
        raise RuntimeError('Owned Synapse did not reach the versions endpoint')
    except BaseException:
        stop_server(process)
        raise


def stop_server(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    announce('owned Synapse stopped')


def prepare(api, directory):
    password = 'Test' + secrets.token_hex(12)
    user = api.register(USER, password, 'FIXTURE_SETUP')
    peer = api.register('fixture_peer', 'Test' + secrets.token_hex(12), 'PEER')
    room = api.call('POST', CLIENT + '/createRoom', {
        'name': ROOM_NAME, 'preset': 'private_chat', 'is_direct': True, 'invite': [user['user_id']],
        'creation_content': {'m.federate': False},
    }, peer['access_token'])['room_id']
    api.call('POST', CLIENT + '/join/' + quote(room, safe=''), {}, user['access_token'])
    room_path = CLIENT + '/rooms/' + quote(room, safe='')
    image = Image.new('RGB', (64, 64), (32, 101, 197))
    ImageDraw.Draw(image).rectangle((8, 8, 40, 34), fill=(252, 185, 60))
    photo = directory / 'probe-photo.png'
    image.save(photo)
    token = peer['access_token']
    png_uri = api.upload(photo.name, 'image/png', photo.read_bytes(), token)
    text_uri = api.upload(FILE_NAME, 'text/plain', FILE_BYTES, token)
    if api.download(png_uri, user['access_token']) != photo.read_bytes() or api.download(text_uri, user['access_token']) != FILE_BYTES:
        raise RuntimeError('Initial authenticated media bytes differ')
    # The App must obtain its own independent device through the sign-in UI.
    api.call('POST', CLIENT + '/logout', {}, user['access_token'])
    announce('two synthetic accounts and one private room; two authenticated media byte checks passed')
    return user['user_id'], token, room_path, password, png_uri, text_uri


def probe_peer(api, fixture, stop):
    user_id, token, room, _, png_uri, text_uri = fixture

    def messages():
        events = api.call('GET', room + '/messages?dir=b&limit=35', token=token)['chunk']
        return [event['content'] for event in events if event.get('sender') == user_id and event.get('type') == 'm.room.message']

    def wait_for(predicate):
        while not stop.is_set():
            found = [event for event in messages() if predicate(event)]
            if found:
                if len(found) != 1:
                    raise AssertionError('Expected exactly one matching iOS event')
                return found[0]
            stop.wait(0.7)
        raise RuntimeError('App run finished before the expected Matrix event reached the peer')

    def send(transaction, content):
        api.call('PUT', room + '/send/m.room.message/' + transaction, content, token)

    send('seed', {'msgtype': 'm.text', 'body': HISTORY})
    wait_for(lambda event: event.get('body') == OUTGOING)
    announce('peer observed one iOS text event')
    send('reply', {'msgtype': 'm.text', 'body': REPLY})
    wait_for(lambda event: event.get('body') == RESTORED)
    send('after-restart', {'msgtype': 'm.text', 'body': RESTART_REPLY})
    announce('peer received the restored device message and sent a fresh reply')

    send('image', {'msgtype': 'm.image', 'body': 'probe-image.png', 'url': png_uri,
                   'info': {'mimetype': 'image/png', 'w': 64, 'h': 64}})
    image = wait_for(lambda event: event.get('msgtype') == 'm.image')
    data = api.download(image['url'], token)
    with Image.open(BytesIO(data)) as decoded:
        decoded.load()
        if decoded.size != (64, 64):
            raise ValueError('iOS image dimensions differ from the synthetic photo')
    announce('peer downloaded the iOS image and decoded 64x64 pixels')

    send('file', {'msgtype': 'm.file', 'body': FILE_NAME, 'filename': FILE_NAME, 'url': text_uri,
                  'info': {'mimetype': 'text/plain', 'size': len(FILE_BYTES)}})
    file = wait_for(lambda event: event.get('msgtype') == 'm.file' and event.get('body') == FILE_NAME)
    received = api.download(file['url'], token)
    if received != FILE_BYTES:
        raise ValueError('Round-tripped TXT bytes differ')
    announce('peer downloaded the iOS text file sha256=' + hashlib.sha256(received).hexdigest())


def run_ui(api, fixture, command):
    _, _, _, password, _, _ = fixture
    env = dict(os.environ, TEST_RUNNER_MATRIX_BASE=BASE, TEST_RUNNER_MATRIX_USER=USER,
               TEST_RUNNER_MATRIX_PASSWORD=password, TEST_RUNNER_MATRIX_ROOM=ROOM_NAME, TEST_RUNNER_MATRIX_HISTORY=HISTORY,
               TEST_RUNNER_MATRIX_OUTGOING=OUTGOING, TEST_RUNNER_MATRIX_REPLY=REPLY,
               TEST_RUNNER_MATRIX_RESTORED=RESTORED, TEST_RUNNER_MATRIX_RESTART_REPLY=RESTART_REPLY,
               TEST_RUNNER_MATRIX_FILE=FILE_NAME)
    stop = Event()
    with ThreadPoolExecutor(max_workers=1) as pool:
        peer = pool.submit(probe_peer, api, fixture, stop)
        try:
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=700)
            for stream, output in ((sys.stdout, result.stdout), (sys.stderr, result.stderr)):
                for line in output.splitlines(keepends=True):
                    if 'SecureTextField' in line:
                        line = re.sub(r"\bType .+? into ", "Type '<fixture-password>' into ", line)
                    stream.write(line.replace(password, '<fixture-password>'))
            result.check_returncode()
            peer.result(timeout=25)
        finally:
            stop.set()


def report_server_observations(directory):
    counts = {}
    for line in (directory / 'access.log').read_text(encoding='utf-8').splitlines():
        match = re.search(r' \d+B (\d{3})!? "(GET|POST) (/_matrix/client/[^? ]+)(?:\?[^ ]*)? HTTP/', line)
        if not match:
            continue
        status, method, route = match.groups()
        if (method == 'POST' and route.endswith('/login')) or route.endswith('/sync'):
            key = (method, 'login' if route.endswith('/login') else 'sync', status)
            counts[key] = counts.get(key, 0) + 1
    for (method, operation, status), count in sorted(counts.items()):
        announce(f'client {method} {operation}: http={status} count={count}')


def main():
    parser = ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--simulator')
    parser.add_argument('command', nargs='*')
    args = parser.parse_args()
    if bool(args.simulator) != bool(args.command):
        parser.error('Simulator and XCTest command must be provided together')
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700)
    api = Matrix()
    server = start_server(directory, api)
    try:
        fixture = prepare(api, directory)
        if args.command:
            subprocess.run(['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'], check=True, timeout=240)
            run_ui(api, fixture, args.command)
    finally:
        stop_server(server)
        if args.command:
            report_server_observations(directory)


if __name__ == '__main__':
    main()

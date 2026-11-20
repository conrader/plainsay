#!/usr/bin/python3
"""Daily encrypted Plainsay backup; run as ubuntu, with sudo for SQLite reads."""
import datetime
import fcntl
import hashlib
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

DB = Path('/var/lib/plainsay/plainsay.db')
BACKUPS = Path('/var/lib/plainsay/backups')
RECIPIENT = Path('/etc/plainsay-offbox/recipient.txt')
LOG = Path('/var/log/plainsay-offbox.log')
LOCK = Path('/var/lib/plainsay-offbox/backup.lock')
REMOTE = '/var/backups/plainsay-offbox'
SSH = ['/usr/bin/ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
       '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15',
       '-o', 'ServerAliveCountMax=2', 'serwerdmt']
SCP = ['/usr/bin/scp', '-q', '-o', 'BatchMode=yes',
       '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
       '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2']
SQLITE = ['/usr/bin/sudo', '-n', '/usr/bin/sqlite3', '-readonly']
NOTIFY = '/home/ubuntu/sb/bin/sb-codejob'
recent = []


class BackupError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code if 0 < code < 256 else 1


def iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def log(message):
    line = f'{iso()} {message}\n'
    recent.append(line)
    try:
        with LOG.open('a') as handle:
            handle.write(line)
    except OSError:
        sys.stderr.write(line)


def run(argv, step, timeout=120):
    # Keep command output private. Logs contain only steps, paths and status codes.
    try:
        result = subprocess.run(argv, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise BackupError(f'{step}: timeout', 124)
    except OSError:
        raise BackupError(f'{step}: command unavailable', 127)
    if result.returncode:
        raise BackupError(f'{step}: exit {result.returncode}', result.returncode)
    return result.stdout


def source_file():
    exists = subprocess.run(['/usr/bin/sudo', '-n', '/usr/bin/test', '-d', str(BACKUPS)],
                            capture_output=True, timeout=30)
    if exists.returncode == 0:
        listing = run(['/usr/bin/sudo', '-n', '/usr/bin/find', str(BACKUPS),
                       '-maxdepth', '1', '-type', 'f', '-name', '*.db',
                       '-printf', '%T@ %p\\0'], 'list local snapshots', 30)
        files = []
        for record in listing.split(b'\0'):
            if record:
                modified, path = record.split(b' ', 1)
                files.append((float(modified), Path(os.fsdecode(path))))
        if files:
            modified, path = max(files)
            age = time.time() - modified
            if 0 <= age < 26 * 3600:
                log(f'source=local path={path} age_seconds={int(age)}')
                return path
    log(f'source=live path={DB}; local snapshot absent or older than 26 hours')
    return DB


def backup():
    source = source_file()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    name = f'plainsay-{stamp}.db.age'
    final = f'{REMOTE}/{name}'
    partial = f'{REMOTE}/.{name}.part'
    with tempfile.TemporaryDirectory(prefix='plainsay-offbox-', dir='/tmp') as stage:
        snapshot = Path(stage) / f'plainsay-{stamp}.db'
        encrypted = Path(stage) / name
        # A precreated file keeps ubuntu ownership while root reads the source.
        snapshot.touch(mode=0o600, exist_ok=False)
        quoted = str(snapshot).replace("'", "''")
        run(SQLITE + [str(source), '.timeout 30000', f".backup '{quoted}'"],
            'consistent SQLite snapshot')
        run(['/usr/bin/sqlite3', str(snapshot), 'PRAGMA journal_mode=DELETE;'],
            'make standalone snapshot')
        integrity = run(['/usr/bin/sqlite3', '-readonly', str(snapshot),
                         'PRAGMA integrity_check;'], 'snapshot integrity check')
        if integrity.strip() != b'ok':
            raise BackupError('snapshot integrity check did not return ok', 2)
        log('snapshot integrity=ok')
        run(['/usr/bin/age', '-R', str(RECIPIENT), '-o', str(encrypted), str(snapshot)],
            'age encryption')
        run(SSH + [f'umask 077; /usr/bin/install -d -m 0700 {REMOTE} && '
                   f'cd -P -- {shlex.quote(REMOTE)} && test "$(pwd -P)" = {shlex.quote(REMOTE)} && '
                   f'test ! -e {final} && test ! -L {final} && '
                   f'test ! -e {partial} && test ! -L {partial}'],
            'prepare remote directory')
        digest = hashlib.sha256(encrypted.read_bytes()).hexdigest()
        pattern = 'plainsay-' + '[0-9]' * 8 + 'T' + '[0-9]' * 6 + 'Z.db.age'
        published = False
        try:
            run(SCP + [str(encrypted), f'serwerdmt:{partial}'], 'upload ciphertext')
            command = f"""
set -eu
cd -P -- {shlex.quote(REMOTE)}
test "$(pwd -P)" = {shlex.quote(REMOTE)}
exec 9<.
flock -x -w 20 9
test -f {partial}
test ! -L {partial}
printf '%s  %s\\n' {digest} {partial} | sha256sum --check --status
# Reject a stale writer before publishing. Hold the lock through pruning.
export LC_ALL=C
for existing in {pattern}; do
    if [ -f "$existing" ] && [ "$existing" \\> {name} ]; then exit 1; fi
done
chmod 0600 {partial}
mv -nT -- {partial} {final}
test ! -e {partial}
test ! -L {partial}
test -f {final}
test ! -L {final}
if ! printf '%s  %s\\n' {digest} {final} | sha256sum --check --status; then
    rm -- {final}
    exit 1
fi
for old in {pattern}; do
    if [ -f "$old" ] && [ ! -L "$old" ] && [ "$old" \\< {name} ]; then
        rm -- "$old"
    fi
done
"""
            run(SSH + [command], 'verify, publish and retain one ciphertext')
            published = True
        finally:
            if not published:
                try:
                    run(SSH + [f'cd -P -- {shlex.quote(REMOTE)} && '
                               f'test "$(pwd -P)" = {shlex.quote(REMOTE)} && '
                               f'/usr/bin/rm -f -- {shlex.quote(partial)}'],
                        'remove incomplete upload', 30)
                except BackupError:
                    log('incomplete-upload cleanup failed')
        log(f'SUCCESS destination=serwerdmt:{final} bytes={encrypted.stat().st_size} retention=1')


def interrupted(signum, frame):
    raise BackupError(f'interrupted by signal {signum}', 128 + signum)


def main():
    os.umask(0o077)
    started = iso()
    lock = None
    try:
        lock = LOCK.open('a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError('another backup is still running', 75)
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        log('START plainsay-offbox')
        backup()
        return 0
    except Exception as error:
        code = error.code if isinstance(error, BackupError) else 1
        message = str(error) if isinstance(error, BackupError) else type(error).__name__
        log(f'FAIL exit={code} step={message}')
        ended = iso()
        try:
            lines = LOG.read_text().splitlines(keepends=True)[-15:]
        except OSError:
            lines = recent[-15:]
        try:
            notice = subprocess.run([NOTIFY, 'notify', '--agent', 'infra-caretaker',
                                     '--host', 'ovh', '--exit-code', str(code),
                                     '--started', started, '--ended', ended,
                                     '--label', 'plainsay-offbox', '--source', 'cron'],
                                    input=''.join(lines).encode(), capture_output=True, timeout=30)
            log(f'failure_wake_exit={notice.returncode}')
        except (OSError, subprocess.TimeoutExpired):
            log('failure_wake=failed')
        return code
    finally:
        if lock is not None:
            lock.close()


if __name__ == '__main__':
    sys.exit(main())

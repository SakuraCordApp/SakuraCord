#!/usr/bin/env python3
"""PR archive metadata and non-executing inspection for the trusted publisher."""
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

MAX_ARCHIVE_SIZE = 4 * 1024**3
MAX_EXPANDED_SIZE = 8 * 1024**3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def build_id(pr, run, attempt):
    return f"pr-{pr}-run-{run}-attempt-{attempt}"


def embed(bundle):
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    pr = event['pull_request']
    run = int(os.environ['GITHUB_RUN_ID'])
    attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
    metadata = dict(schemaVersion=1, id=build_id(pr['number'], run, attempt),
                    pullRequest=pr['number'], headSHA=pr['head']['sha'],
                    baseSHA=pr['base']['sha'], builtSHA=os.environ['GITHUB_SHA'],
                    runID=run, runAttempt=attempt, configuration='debug',
                    architecture=os.uname().machine)
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
            == metadata['builtSHA'], 'checkout does not match build SHA')
    info_path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    require(info.get('SakuraCordBuildSwitchingProtocol') == 1, 'missing switching protocol')
    info['SakuraCordPullRequestBuildID'] = metadata['id']
    info['SakuraCordPullRequestNumber'] = metadata['pullRequest']
    info['SakuraCordBuildHeadSHA'] = metadata['headSHA']
    info['SakuraCordBuildCommitSHA'] = metadata['builtSHA']
    info['SakuraCordBuildRunID'] = str(run)
    info['SakuraCordBuildRunAttempt'] = attempt
    # PR builds do not periodically transition back to a release.
    info['SUEnableAutomaticChecks'] = True
    info_path.write_bytes(plistlib.dumps(info))
    (bundle / 'Contents/Resources/pr-build.json').write_text(json.dumps(metadata, indent=2) + '\n')


def validate_extra_fields(extra):
    cursor = 0
    while cursor < len(extra):
        require(cursor + 4 <= len(extra), 'truncated ZIP extra field')
        kind, size = struct.unpack_from('<HH', extra, cursor)
        cursor += 4
        require(cursor + size <= len(extra), 'truncated ZIP extra value')
        # zipfile uses the ordinary header pathname; ditto may honor this override.
        # Refuse a second pathname instead of letting the two parsers disagree.
        require(kind != 0x7075, 'alternate Unicode ZIP pathname')
        cursor += size


def inspect_zip(path):
    require(path.stat().st_size <= MAX_ARCHIVE_SIZE, 'archive too large')
    archive = zipfile.ZipFile(path)
    entries = archive.infolist()
    require(len(entries) < 100000, 'too many archive entries')
    require(sum(x.file_size for x in entries) <= MAX_EXPANDED_SIZE, 'expanded archive too large')
    names = set()
    canonical_names = set()
    links = {}
    for entry in entries:
        require(entry.orig_filename == entry.filename, 'ambiguous archive filename')
        validate_extra_fields(entry.extra)
        with path.open('rb') as raw:
            raw.seek(entry.header_offset)
            header = raw.read(30)
            require(len(header) == 30 and header[:4] == b'PK\x03\x04', 'invalid local ZIP header')
            name_size, extra_size = struct.unpack_from('<HH', header, 26)
            raw.seek(name_size, 1)
            extra = raw.read(extra_size)
            require(len(extra) == extra_size, 'truncated local ZIP extras')
            validate_extra_fields(extra)
        # Validate every local header against its central-directory name before
        # ditto can interpret it; reading only required payloads leaves a parser gap.
        with archive.open(entry) as member:
            member.read(0)
        name = entry.filename.rstrip('/')
        parts = PurePosixPath(name).parts
        require(name and not name.startswith('/') and '\\' not in name
                and all(p not in ('.', '..') for p in parts)
                and posixpath.normpath(name) == name, 'unsafe archive path')
        canonical = unicodedata.normalize('NFD', name).casefold()
        require(canonical not in canonical_names, 'duplicate archive path')
        names.add(name)
        canonical_names.add(canonical)
        mode = entry.external_attr >> 16
        require(not mode or stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK),
                'special archive entry')
        if stat.S_ISLNK(mode):
            require(not entry.is_dir(), 'symlink marked as directory')
            require(entry.file_size < 4096, 'oversized symlink')
            target = archive.read(entry).decode('utf-8')
            # Framework aliases use Versions/Current and a version directory. Never
            # permit '..': its meaning after an earlier symlink differs from lexical
            # normpath, and safe extraction does not require such aliases here.
            require(target and not target.startswith('/') and '\\' not in target
                    and '..' not in PurePosixPath(target).parts, 'unsafe symlink')
            links[canonical] = target
    for name in names:
        # macOS normally uses case-insensitive, normalization-insensitive paths.
        # No archive entry may write through an alias, even to an in-root target.
        for parent in PurePosixPath(name).parents:
            require(unicodedata.normalize('NFD', str(parent)).casefold() not in links,
                    'archive member beneath symlink')
        current = name
        for _ in range(64):
            parts = current.split('/')
            found = False
            for i in range(1, len(parts) + 1):
                prefix = '/'.join(parts[:i])
                canonical_prefix = unicodedata.normalize('NFD', prefix).casefold()
                if canonical_prefix in links:
                    current = posixpath.normpath(posixpath.join(
                        posixpath.dirname(prefix), links[canonical_prefix], *parts[i:]))
                    require(current != '..' and not current.startswith('../'), 'escaping symlink')
                    found = True
                    break
            if not found:
                break
        else:
            raise ValueError('cyclic archive symlink')
    return archive


def read_regular(archive, name, limit):
    entry = archive.getinfo(name)
    require(entry.file_size <= limit and not stat.S_ISLNK(entry.external_attr >> 16)
            and not entry.is_dir(), 'invalid required archive member')
    # Required members may not be under a symlink.
    for parent in PurePosixPath(name).parents:
        if str(parent) in archive.namelist():
            require(not stat.S_ISLNK(archive.getinfo(str(parent)).external_attr >> 16),
                    'required member under symlink')
    return archive.read(entry)


def macho_uuids(data):
    """Read LC_UUID without executing or loading contributor-supplied code."""
    magic = data[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', data, 4)[0]
        require(0 < count <= 8, 'invalid fat Mach-O')
        result = {}
        fat64 = magic[-1] == 0xbf
        for i in range(count):
            offset = 8 + i * (32 if fat64 else 20)
            start, size = struct.unpack_from('>QQ' if fat64 else '>II', data, offset + 8)
            require(start + size <= len(data), 'truncated fat Mach-O')
            result.update(macho_uuids(data[start:start + size]))
        return result
    require(magic == b'\xcf\xfa\xed\xfe', 'expected 64-bit Mach-O')
    cpu, _, _, count, commands_size = struct.unpack_from('<IIIII', data, 4)
    require(count < 10000 and 32 + commands_size <= len(data), 'invalid load commands')
    architecture = {0x100000C: 'arm64', 0x1000007: 'x86_64'}.get(cpu)
    require(architecture is not None, 'unsupported architecture')
    cursor = 32
    result = {}
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, cursor)
        require(size >= 8 and cursor + size <= 32 + commands_size, 'invalid load command')
        if command == 0x1b:
            require(size == 24 and not result, 'invalid UUID command')
            result[architecture] = data[cursor + 8:cursor + 24].hex()
        cursor += size
    require(result, 'Mach-O has no UUID')
    return result


def unwrap(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with inspect_zip(source) as archive:
        require(set(archive.namelist()) == {'SakuraCord.app.zip', 'SakuraCord.dSYM.zip', 'build.json'},
                'unexpected artifact files')
        for name in archive.namelist():
            # No extraction API, permissions, links, or executable files from the outer artifact.
            data = read_regular(archive, name, MAX_ARCHIVE_SIZE if name.endswith('.zip') else 16384)
            (destination / name).write_bytes(data)


def validate(directory, context):
    metadata = json.loads((directory / 'build.json').read_text())
    for key in ('schemaVersion', 'id', 'pullRequest', 'headSHA', 'baseSHA', 'builtSHA',
                'runID', 'runAttempt', 'configuration', 'architecture'):
        require(metadata.get(key) == context[key], f'metadata mismatch: {key}')
    with inspect_zip(directory / 'SakuraCord.app.zip') as app:
        require(all(x.startswith(('SakuraCord.app/', '__MACOSX/')) or x == 'SakuraCord.app'
                    for x in app.namelist()), 'unexpected app archive root')
        info = plistlib.loads(read_regular(app, 'SakuraCord.app/Contents/Info.plist', 1024**2))
        expected = dict(CFBundleIdentifier='dev.sakuracord.SakuraCord',
                        CFBundleExecutable='SakuraCord',
                        CFBundleVersion=str(4000000000000000000 + context['runID'] * 1000 + context['runAttempt']),
                        SakuraCordBuildConfiguration='debug', SakuraCordUpdatesEnabled=True,
                        SakuraCordReleaseTrack='nightly', SUAllowsVersionDowngrades=True,
                        SUScheduledCheckInterval=21600, SUAllowsAutomaticUpdates=True,
                        SakuraCordBuildSwitchingProtocol=1, SakuraCordPullRequestBuildID=context['id'],
                        SakuraCordPullRequestNumber=context['pullRequest'],
                        SakuraCordBuildHeadSHA=context['headSHA'], SakuraCordBuildCommitSHA=context['builtSHA'],
                        SakuraCordBuildRunID=str(context['runID']), SakuraCordBuildRunAttempt=context['runAttempt'],
                        SUPublicEDKey=os.environ['SPARKLE_ED_PUBLIC_KEY'],
                        SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                        SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                        SUEnableInstallerLauncherService=True,
                        SUFeedURL='https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml',
                        SakuraCordNightlyFeedURL='https://sakuracord.app/updates/appcast.xml')
        for key, value in expected.items():
            require(type(info.get(key)) is type(value) and info[key] == value, f'invalid bundle setting: {key}')
        require(not info.get('SakuraCordInsecureDebugCredentialsEnabled'), 'insecure credentials enabled')
        require(not info.get('SUEnableInstallerConnectionService'), 'forwarded installer connection is unsupported')
        require(re.fullmatch(r'\d+\.\d+\.\d+', info['CFBundleShortVersionString']) is not None, 'invalid version')
        require(info['LSMinimumSystemVersion'] == '27.0', 'unexpected minimum OS')
        embedded = json.loads(read_regular(app, 'SakuraCord.app/Contents/Resources/pr-build.json', 16384))
        require(embedded == metadata, 'embedded metadata differs')
        require(any('/Frameworks/Sparkle.framework/' in x for x in app.namelist()), 'Sparkle absent')
        app_uuids = macho_uuids(read_regular(app, 'SakuraCord.app/Contents/MacOS/SakuraCord', 1024**3))
    with inspect_zip(directory / 'SakuraCord.dSYM.zip') as symbols:
        symbol_uuids = macho_uuids(read_regular(
            symbols, 'SakuraCord.app.dSYM/Contents/Resources/DWARF/SakuraCord', 2 * 1024**3))
    require(app_uuids == symbol_uuids and set(app_uuids) == {context['architecture']}, 'symbols do not match app')
    return dict(version=info['CFBundleShortVersionString'], buildVersion=info['CFBundleVersion'], uuids=app_uuids)


def verify_signatures(directory, context):
    # Inspect all members and symlink destinations before ditto sees the archive.
    # The isolated extraction directory is new and contains no trusted files.
    validate(directory, context)
    with tempfile.TemporaryDirectory(prefix='sakuracord-pr-signatures-') as temporary:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(directory / 'SakuraCord.app.zip'), temporary], check=True)
        bundle = Path(temporary) / 'SakuraCord.app'
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(bundle)], check=True)
        result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)],
                                check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        require(entitlements.get('com.apple.security.app-sandbox') is True, 'app sandbox missing')
        services = entitlements.get('com.apple.security.temporary-exception.mach-lookup.global-name', [])
        require(all(service in services for service in (
            'dev.sakuracord.SakuraCord-spks', 'dev.sakuracord.SakuraCord-spki')), 'Sparkle Mach entitlements missing')
        require(entitlements.get('com.apple.security.files.bookmarks.app-scope') is True,
                'recovery bookmark entitlement missing')
        require(entitlements.get('com.apple.security.files.user-selected.executable') is True,
                'recovery executable-write entitlement missing')
    print('Validated bundle and nested signatures, app sandbox, Sparkle services, and recovery bookmarks.')


if __name__ == '__main__':
    if sys.argv[1] == 'embed':
        embed(Path(sys.argv[2]))
    elif sys.argv[1] == 'unwrap':
        unwrap(Path(sys.argv[2]), Path(sys.argv[3]))
    elif sys.argv[1] == 'verify-signatures':
        verify_signatures(Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()))
    elif sys.argv[1] == 'validate':
        print(json.dumps(validate(Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()))))
    else:
        raise SystemExit('expected embed, unwrap, validate, or verify-signatures')

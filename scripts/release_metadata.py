"""Validate public labels and the numeric versions required by Windows."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def windows_version(label):
    """Map major.minor[.patch][letter] to a four-part Windows version.

    A letter revision uses a=1 through z=26 in the fourth component. The
    public label remains unchanged in filenames, addon metadata and the UI.
    """
    if not isinstance(label, str):
        raise ValueError('The public version must be a string')
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*)([a-z])?)?', label)
    if not match:
        raise ValueError('Invalid public version: ' + label)
    major, minor, patch, letter = match.groups()
    parts = [int(major), int(minor), int(patch or 0), ord(letter) - ord('a') + 1 if letter else 0]
    if any(part >= 65535 for part in parts):
        raise ValueError('Version component exceeds the Windows assembly limit')
    return '.'.join(str(part) for part in parts)


def load_release_config(root):
    config = json.loads((Path(root) / 'release.json').read_text(encoding='utf-8'))
    version = config.get('version')
    if config.get('windows_version') != windows_version(version):
        raise ValueError('Windows version differs from the public release label')
    if config.get('tag') != 'v' + version:
        raise ValueError('Release tag differs from the public release label')
    if not isinstance(config.get('title'), str) or not config['title'].endswith(' ' + version):
        raise ValueError('Release title differs from the public release label')
    if config.get('draft') is not True:
        raise ValueError('Build and preparation helpers require an explicit draft')
    return config


def validate_build_versions(root, config=None):
    root = Path(root)
    config = load_release_config(root) if config is None else config
    toc = (root / 'addon/Interface/AddOns/UniversalBasisKeeper/UniversalBasisKeeper.toc').read_text(encoding='utf-8')
    if re.findall(r'^## Version:\s*(\S+)\s*$', toc, re.M) != [config['version']]:
        raise ValueError('Addon version differs from the public release label')
    source = (root / 'installer/Installer.cs').read_text(encoding='utf-8')
    for name, expected in (
        ('AssemblyVersion', config['windows_version']),
        ('AssemblyFileVersion', config['windows_version']),
        ('AssemblyInformationalVersion', config['version']),
    ):
        if re.findall(r'\[assembly:\s*' + name + r'\("([^"\r\n]+)"\)\]', source) != [expected]:
            raise ValueError(name + ' differs from the public release metadata')
    identity = ET.parse(root / 'installer/Installer.manifest').getroot().find('{urn:schemas-microsoft-com:asm.v1}assemblyIdentity')
    if identity is None or identity.get('version') != config['windows_version']:
        raise ValueError('Windows manifest version differs from the public release metadata')
    return config

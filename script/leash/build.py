#!/usr/bin/env python3
"""Compile Leash and AutonomousTreasury with solc 0.8.26 (the repo's foundry.toml settings) into
script/leash/artifacts.json. SOLC: the compiler (default ~/.svm/0.8.26/solc-0.8.26 or solc on PATH).
OZ_DIR: OpenZeppelin contracts 5.4.0 (default lib/openzeppelin-contracts)."""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SOLC = os.environ.get('SOLC') or (os.path.expanduser('~/.svm/0.8.26/solc-0.8.26') if os.path.exists(os.path.expanduser('~/.svm/0.8.26/solc-0.8.26')) else shutil.which('solc'))
OZ = os.path.abspath(os.environ.get('OZ_DIR') or os.path.join(ROOT, 'lib', 'openzeppelin-contracts'))
TARGETS = {'src/Leash.sol': 'Leash', 'src/AutonomousTreasury.sol': 'AutonomousTreasury'}

version = subprocess.check_output([SOLC, '--version'], text=True)
if '0.8.26+commit.8a97fa7a' not in version:
    sys.exit(f'need solc 0.8.26+commit.8a97fa7a, got: {version}')
job = {
    'language': 'Solidity',
    'sources': {p: {'urls': [p]} for p in TARGETS},
    'settings': {
        'viaIR': True,
        'optimizer': {'enabled': True, 'runs': 44_444_444},
        'evmVersion': 'cancun',
        'metadata': {'bytecodeHash': 'none'},
        'outputSelection': {'*': {'*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object']}},
    },
}
inc = tempfile.mkdtemp()
os.makedirs(os.path.join(inc, '@openzeppelin'))
os.symlink(os.path.join(OZ, 'contracts'), os.path.join(inc, '@openzeppelin', 'contracts'))
out = json.loads(subprocess.run([SOLC, '--standard-json', '--base-path', ROOT, '--include-path', inc,
                                 '--allow-paths', f'{ROOT},{OZ},{inc}'],
                                input=json.dumps(job), capture_output=True, text=True, check=True).stdout)
errors = [e for e in out.get('errors', []) if e['severity'] == 'error']
for e in out.get('errors', []):
    print(e['formattedMessage'], file=sys.stderr)
if errors:
    sys.exit(1)
art = {'solc': '0.8.26+commit.8a97fa7a', 'settings': job['settings'] | {'remappings': ['@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/']}}
for path, name in TARGETS.items():
    c = out['contracts'][path][name]
    art[name] = {'abi': c['abi'], 'bytecode': '0x' + c['evm']['bytecode']['object'],
                 'runtimeSize': len(c['evm']['deployedBytecode']['object']) // 2}
    print(f"{name}: {art[name]['runtimeSize']} bytes runtime")
with open(os.path.join(ROOT, 'script', 'leash', 'artifacts.json'), 'w') as f:
    json.dump(art, f, indent=1)

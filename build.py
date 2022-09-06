#!/usr/bin/env python3

import glob
import os
import re
import subprocess
import random
import shutil
import string
import sys
import time

RELEASE = len(sys.argv) > 1 and sys.argv[1] == 'release'

odin = 'odin'
program_name = 'foobar'

[os.remove(f) for f in glob.iglob('build/dist/*', recursive=True)]
for ext in ['*.o', '*.wasm', '*.wat']:
    [os.remove(f) for f in glob.iglob('build/**/' + ext, recursive=True)]

os.makedirs('build', exist_ok=True)

start_time = time.time()
print('Compiling...')
subprocess.run([
    odin,
    'build', 'src',
    '-target:js_wasm32',
    f"-out:build/{program_name}.wasm",
    '-o:speed', '-debug'
])
print("Compiled in {:.1f} seconds".format(time.time() - start_time))

# Optimize output WASM file
if RELEASE:
    print('Optimizing WASM...')
    subprocess.run([
        'wasm-opt', f"build/{program_name}.wasm",
        '-o', f"build/{program_name}.wasm",
        '-O4', # general perf optimizations
        '--memory-packing', # remove unnecessary and extremely large .bss segment
        '--zero-filled-memory',
    ])

# Patch memcpy and memmove
start_time = time.time()
print('Patching WASM...')
subprocess.run([
    'wasm2wat',
    '-o', f"build/{program_name}.wat",
    f"build/{program_name}.wasm",
])
memcpy = """(\\1
    local.get 0
    local.get 1
    local.get 2
    memory.copy
    local.get 0)"""
memset = """(\\1
    local.get 0
    local.get 1
    local.get 2
    memory.fill
    local.get 0)"""
with open(f"build/{program_name}.wat", 'r') as infile, open(f"build/{program_name}_patched.wat", 'w') as outfile:
    wat = infile.read()
    wat = re.sub(r'\((func \$memcpy.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
    wat = re.sub(r'\((func \$memmove.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
    wat = re.sub(r'\((func \$memset.*?\(result i32\)).*?local.get 0(.*?return)?\)', memset, wat, flags=re.DOTALL)
    outfile.write(wat)
subprocess.run([
    'wat2wasm',
    '-o', f"build/{program_name}_patched.wasm",
    f"build/{program_name}_patched.wat",
])
print("Patched in {:.1f} seconds".format(time.time() - start_time))

#
# Output the dist folder for upload
#

print('Building dist folder...')
os.makedirs('build/dist', exist_ok=True)

buildId = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8)) # so beautiful. so pythonic.

root = 'src/index.html'
assets = [
    'src/runtime.js',
    f"build/{program_name}_patched.wasm",
]

rootContents = open(root).read()

def addId(filename, id):
    parts = filename.split('.')
    parts.insert(-1, buildId)
    return '.'.join(parts)

for asset in assets:
    basename = os.path.basename(asset)
    newFilename = addId(basename, buildId)
    shutil.copy(asset, 'build/dist/{}'.format(newFilename))

    rootContents = rootContents.replace(basename, newFilename)

with open('build/dist/index.html', 'w') as f:
    f.write(rootContents)

print('Done!')

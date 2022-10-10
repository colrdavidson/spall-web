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
import http.server

RELEASE = len(sys.argv) > 1 and sys.argv[1] == 'release'
EXTRARELEASE = len(sys.argv) > 1 and sys.argv[1] == 'extrarelease'

RUN_SERVER = False
for arg in sys.argv:
    if arg == 'run':
        RUN_SERVER = True

odin = 'odin'
program_name = 'spall'

[os.remove(f) for f in glob.iglob('build/dist/*', recursive=True)]
for ext in ['*.o', '*.wasm', '*.wat']:
    [os.remove(f) for f in glob.iglob('build/**/' + ext, recursive=True)]

os.makedirs('build', exist_ok=True)

build_str = []
if RELEASE:
    build_str = ['-o:speed']
else:
    build_str = ['-debug']

wasm_out = f"build/{program_name}.wasm"

initial_size = (64 * 1024) * 2000
max_size     = (64 * 1024) * 65536

start_time = time.time()
print('Compiling...')
subprocess.run([
    odin,
    'build', 'src',
    '-collection:formats=formats',
    '-target:js_wasm32',
    '-target-features:+bulk-memory',
    f"-extra-linker-flags:--import-memory --initial-memory={initial_size} --max-memory={max_size}",
    f"-out:{wasm_out}",
    *build_str,
], check=True)
print("Compiled in {:.1f} seconds".format(time.time() - start_time))

#
# Output the dist folder for upload
#

print('Building dist folder...')
os.makedirs('build/dist', exist_ok=True)

shutil.copyfile('src/index.html', 'build/dist/index.html')
shutil.copyfile('src/index.js', 'build/dist/index.js')
shutil.copyfile('src/runtime.js', 'build/dist/runtime.js')
shutil.copyfile(f"build/{program_name}.wasm", f"build/dist/{program_name}.wasm")

print('Done!')

print('\n')

if RUN_SERVER:
    print('Running server...')
    print('Connect to http://localhost:8000 in your browser to open the trace viewer.')
    print('Press Control-C to stop running the server.')
    print('')
    os.chdir('./build/dist')
    try:
        http.server.ThreadingHTTPServer(('', 8000), http.server.SimpleHTTPRequestHandler).serve_forever()
    except KeyboardInterrupt:
        print('')
else:
    print('Go to the build/dist folder and run "python -m http.server" to serve the trace viewer.')
    print('Or, build with "python build.py run" to auto-run a server.')
    print('Then, connect to http://localhost:8000 in your browser to open the trace viewer.')


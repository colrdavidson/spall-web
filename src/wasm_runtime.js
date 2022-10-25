"use strict";

class WasmMemoryInterface {
	constructor(memory) {
		this.memory = memory;
		this.exports = null;
		this.listenerMap = {};
	}

	setMemory(memory) {
		this.memory = memory;
	}

	setExports(exports) {
		this.exports = exports;
	}

	get mem() {
		return new DataView(this.memory.buffer);
	}

	loadF32Array(addr, len) {
		let array = new Float32Array(this.memory.buffer, addr, len);
		return array;
	}
	loadF64Array(addr, len) {
		let array = new Float64Array(this.memory.buffer, addr, len);
		return array;
	}
	loadU32Array(addr, len) {
		let array = new Uint32Array(this.memory.buffer, addr, len);
		return array;
	}
	loadI32Array(addr, len) {
		let array = new Int32Array(this.memory.buffer, addr, len);
		return array;
	}

	loadU8(addr) { return this.mem.getUint8(addr, true); }
	loadI8(addr) { return this.mem.getInt8(addr, true); }
	loadU16(addr) { return this.mem.getUint16(addr, true); }
	loadI16(addr) { return this.mem.getInt16(addr, true); }
	loadU32(addr) { return this.mem.getUint32(addr, true); }
	loadI32(addr) { return this.mem.getInt32(addr, true); }
	loadU64(addr) {
		const lo = this.mem.getUint32(addr + 0, true);
		const hi = this.mem.getUint32(addr + 4, true);
		return lo + hi*4294967296;
	};
	loadI64(addr) {
		// TODO(bill): loadI64 correctly
		const lo = this.mem.getUint32(addr + 0, true);
		const hi = this.mem.getUint32(addr + 4, true);
		return lo + hi*4294967296;
	};
	loadF32(addr)  { return this.mem.getFloat32(addr, true); }
	loadF64(addr)  { return this.mem.getFloat64(addr, true); }
	loadInt(addr)  { return this.mem.getInt32(addr, true); }
	loadUint(addr) { return this.mem.getUint32(addr, true); }

	loadPtr(addr) { return this.loadUint(addr); }

	loadBytes(ptr, len) {
		return new Uint8Array(this.memory.buffer, ptr, len);
	}

	loadString(ptr, len) {
		const bytes = this.loadBytes(ptr, len);
		return new TextDecoder("utf-8").decode(bytes);
	}
	putString(ptr, str) {
		const buf = new Uint8Array(this.memory.buffer);
		let i = 0;
		for (; i < str.length; i++) {
			buf[ptr + i] = str.charCodeAt(i);
		}
		buf[ptr + i] = 0;
	}

	storeU8(addr, value)  { this.mem.setUint8  (addr, value, true); }
	storeI8(addr, value)  { this.mem.setInt8   (addr, value, true); }
	storeU16(addr, value) { this.mem.setUint16 (addr, value, true); }
	storeI16(addr, value) { this.mem.setInt16  (addr, value, true); }
	storeU32(addr, value) { this.mem.setUint32 (addr, value, true); }
	storeI32(addr, value) { this.mem.setInt32  (addr, value, true); }
	storeU64(addr, value) {
		this.mem.setUint32(addr + 0, value, true);
		this.mem.setUint32(addr + 4, Math.floor(value / 4294967296), true);
	}
	storeI64(addr, value) {
		// TODO(bill): storeI64 correctly
		this.mem.setUint32(addr + 0, value, true);
		this.mem.setUint32(addr + 4, Math.floor(value / 4294967296), true);
	}
	storeF32(addr, value)  { this.mem.setFloat32(addr, value, true); }
	storeF64(addr, value)  { this.mem.setFloat64(addr, value, true); }
	storeInt(addr, value)  { this.mem.setInt32  (addr, value, true); }
	storeUint(addr, value) { this.mem.setUint32 (addr, value, true); }
};

function odinSetupDefaultImports(wasmMemoryInterface, consoleElement, memory) {
	const MAX_INFO_CONSOLE_LINES = 512;
	let infoConsoleLines = new Array();
	let currentLine = {};
	currentLine[false] = "";
	currentLine[true] = "";
	let prevIsError = false;

	const writeToConsole = (line, isError) => {
		if (!line) {
			return;
		}

		const println = (text, forceIsError) => {
			let style = [
				"color: #eee",
				"background-color: #d20",
				"padding: 2px 4px",
				"border-radius: 2px",
			].join(";");
			let doIsError = isError;
			if (forceIsError !== undefined) {
				doIsError = forceIsError;
			}

			if (doIsError) {
				console.log("%c"+text, style);
			} else {
				console.log(text);
			}

		};

		// Print to console
		if (line == "\n") {
			println(currentLine[isError]);
			currentLine[isError] = "";
		} else if (!line.includes("\n")) {
			currentLine[isError] = currentLine[isError].concat(line);
		} else {
			let lines = line.split("\n");
			let printLast = lines.length > 1 && line.endsWith("\n");
			println(currentLine[isError].concat(lines[0]));
			currentLine[isError] = "";
			for (let i = 1; i < lines.length-1; i++) {
				println(lines[i]);
			}
			let last = lines[lines.length-1];
			if (last !== "") {
				if (printLast) {
					println(last);
				} else {
					currentLine[isError] = last;
				}
			}
		}

		if (prevIsError != isError) {
			if (prevIsError) {
				println(currentLine[prevIsError], prevIsError);
				currentLine[prevIsError] = "";
			}
		}
		prevIsError = isError;


		// HTML based console
		if (!consoleElement) {
			return;
		}
		const wrap = (x) => {
			if (isError) {
				return '<span style="color:#f21">'+x+'</span>';
			}
			return x;
		};

		if (line == "\n") {
			infoConsoleLines.push(line);
		} else if (!line.includes("\n")) {
			let prevLine = "";
			if (infoConsoleLines.length > 0) {
				prevLine = infoConsoleLines.pop();
			}
			infoConsoleLines.push(prevLine.concat(wrap(line)));
		} else {
			let lines = line.split("\n");
			let lastHasNewline = lines.length > 1 && line.endsWith("\n");

			let prevLine = "";
			if (infoConsoleLines.length > 0) {
				prevLine = infoConsoleLines.pop();
			}
			infoConsoleLines.push(prevLine.concat(wrap(lines[0]).concat("\n")));

			for (let i = 1; i < lines.length-1; i++) {
				infoConsoleLines.push(wrap(lines[i]).concat("\n"));
			}
			let last = lines[lines.length-1];
			if (lastHasNewline) {
				infoConsoleLines.push(last.concat("\n"));
			} else {
				infoConsoleLines.push(last);
			}
		}

		if (infoConsoleLines.length > MAX_INFO_CONSOLE_LINES) {
			infoConsoleLines.shift(MAX_INFO_CONSOLE_LINES);
		}

		let data = "";
		for (let i = 0; i < infoConsoleLines.length; i++) {
			data = data.concat(infoConsoleLines[i]);
		}

		let info = consoleElement;
		info.innerHTML = data;
		info.scrollTop = info.scrollHeight;
	};

	let event_temp_data = {};

	return {
		"env": {
			memory
		},
		"odin_env": {
			write: (fd, ptr, len) => {
				const str = wasmMemoryInterface.loadString(ptr, len);
				if (fd == 1) {
					writeToConsole(str, false);
					return;
				} else if (fd == 2) {
					writeToConsole(str, true);
					return;
				} else {
					throw new Error("Invalid fd to 'write'" + stripNewline(str));
				}
			},
			trap:  () => { throw new Error() },
			alert: (ptr, len) => { alert(wasmMemoryInterface.loadString(ptr, len)) },
			abort: () => { Module.abort() },

			sqrt:    (x) => Math.sqrt(x),
			sin:     (x) => Math.sin(x),
			cos:     (x) => Math.cos(x),
			pow:     (x, y) => Math.pow(x, y),
			fmuladd: (x, y, z) => x*y + z,
			ln:      (x) => Math.log(x),
			exp:     (x) => Math.exp(x),
			ldexp:   (x) => Math.ldexp(x),
		},
		"odin_dom": { init_event_raw: (ep) => { }, },
	};
};

// this is a deliberately bad hash.
function generateHash(blob) {
	let encoded_blob = new Uint8Array(blob);
    let hash = 0;
	let len = encoded_blob.length;
    for (let i = 0; i < len; i++) {
        let chr = encoded_blob[i];
        hash = (hash << 5) - hash + chr;
        hash |= 0;
    }
    return hash;
}

async function runWasm(wasmPath, consoleElement, memory, extraForeignImports) {
	let wasmMemoryInterface = new WasmMemoryInterface(memory);

	let imports = odinSetupDefaultImports(wasmMemoryInterface, consoleElement, memory);
	let exports = {};

	if (extraForeignImports !== undefined) {
		imports = {
			...imports,
			...extraForeignImports,
		};
	}

	const response = await fetch(wasmPath);
	const file = await response.arrayBuffer();
	const wasm = await WebAssembly.instantiate(file, imports);

	exports = wasm.instance.exports;
	wasmMemoryInterface.setExports(exports);

	exports._start();

	const jsExports = {
		...exports,
		blob_hash: generateHash(file),
		odinMem: wasmMemoryInterface,
	};
	delete jsExports._start;
	delete jsExports._end;
	delete jsExports.default_context_ptr;

	for (const key of Object.keys(jsExports)) {
		const func = jsExports[key];
		if (typeof func !== 'function') {
			continue;
		}

		Object.defineProperty(jsExports, key, {
			value: (...args) => func(...args, exports.default_context_ptr()),
			writable: false,
		});
	}

	return jsExports;
};

window.odin = {
	// Interface Types
	WasmMemoryInterface: WasmMemoryInterface,

	// Functions
	setupDefaultImports: odinSetupDefaultImports,
	runWasm:             runWasm,
};

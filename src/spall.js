"use strict";

function str(s) {
	const bytes = new TextEncoder("utf-8").encode(s);
	const len = bytes.length;
	const p = window.wasm.temp_allocate(len);
	window.wasm.odinMem.loadBytes(p, len).set(bytes);
	return [p, len];
}
function bytes(b) {
	const len = b.byteLength;
	const p = window.wasm.temp_allocate(len);
	let _b = window.wasm.odinMem.loadBytes(p, len)
	_b.set(new Uint8Array(b));
	return [p, len];
}

const vert_src = `#version 300 es
	in vec2 pos_attr;

	in float x_attr;
	in float width_attr;

	in vec4 color;

	uniform float u_y;
	uniform float u_dpr;
	uniform float u_height;
	uniform vec2 u_resolution;

	out vec4 v_color;

	void main() {
		// offset/scale quad
		vec2 xy = vec2(x_attr * u_dpr, u_y * u_dpr) + (pos_attr * vec2(width_attr * u_dpr, u_height * u_dpr));

		// convert to GL-space, send
		gl_Position = vec4((xy / u_resolution) * 2.0 - 1.0, 0.0, 1.0);
		gl_Position.y = -gl_Position.y;

		v_color = color;
	}
`;

const frag_src = `#version 300 es
	precision mediump float;

	in vec4 v_color;
	out vec4 out_color;

	void main() {
		out_color = v_color.xyzw;
	}
`;

function build_shader(gl, src, type) {
	let shader = gl.createShader(type);

	gl.shaderSource(shader, src);
	gl.compileShader(shader);

	if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
		console.error("An error compiling shaders: " + gl.getShaderInfoLog(shader));
		return null;
	}

	return shader;
}

function init_shader(gl, vert_src, frag_src) {
	let vert_shader = build_shader(gl, vert_src, gl.VERTEX_SHADER);
	let frag_shader = build_shader(gl, frag_src, gl.FRAGMENT_SHADER);

	let shader_program = gl.createProgram();
	gl.attachShader(shader_program, vert_shader);
	gl.attachShader(shader_program, frag_shader);
	gl.linkProgram(shader_program);

	if (!gl.getProgramParameter(shader_program, gl.LINK_STATUS)) {
		console.error("Unable to init shader program: " + gl.getProgramInfoLog(shader_program));
	}

	return shader_program;
}

const text_container = document.querySelector('.text-container');
const rect_container = document.querySelector('.rect-container');

const text_canvas = document.getElementById('text-canvas');
const text_ctx = text_canvas.getContext('2d');

const rect_canvas = document.getElementById('rect-canvas');
const gl_ctx = rect_canvas.getContext('webgl2');

// WebGL2 init
const shader = init_shader(gl_ctx, vert_src, frag_src);

const pos_attr   = gl_ctx.getAttribLocation(shader, "pos_attr");
const start_attr = gl_ctx.getAttribLocation(shader, "x_attr");
const width_attr = gl_ctx.getAttribLocation(shader, "width_attr");
const color_attr = gl_ctx.getAttribLocation(shader, "color");

const y_uni      = gl_ctx.getUniformLocation(shader, "u_y");
const dpr_uni    = gl_ctx.getUniformLocation(shader, "u_dpr");
const height_uni = gl_ctx.getUniformLocation(shader, "u_height");
const resolution_uni = gl_ctx.getUniformLocation(shader, "u_resolution");

gl_ctx.enable(gl_ctx.BLEND);
gl_ctx.blendFunc(gl_ctx.SRC_ALPHA, gl_ctx.ONE_MINUS_SRC_ALPHA);

gl_ctx.useProgram(shader);

let vao = gl_ctx.createVertexArray();
gl_ctx.bindVertexArray(vao);

const rect_deets_buffer = gl_ctx.createBuffer();
gl_ctx.bindBuffer(gl_ctx.ARRAY_BUFFER, rect_deets_buffer);

let draw_rect_size = 4 + 4 + 4;
gl_ctx.enableVertexAttribArray(start_attr);
gl_ctx.vertexAttribPointer(start_attr, 1, gl_ctx.FLOAT, false, draw_rect_size, 0);
gl_ctx.vertexAttribDivisor(start_attr, 1);

gl_ctx.enableVertexAttribArray(width_attr);
gl_ctx.vertexAttribPointer(width_attr, 1, gl_ctx.FLOAT, false, draw_rect_size, 4);
gl_ctx.vertexAttribDivisor(width_attr, 1);

gl_ctx.enableVertexAttribArray(color_attr);
gl_ctx.vertexAttribPointer(color_attr, 4, gl_ctx.UNSIGNED_BYTE, true, draw_rect_size, 8);
gl_ctx.vertexAttribDivisor(color_attr, 1);


const rect_points_buffer = gl_ctx.createBuffer();
gl_ctx.bindBuffer(gl_ctx.ARRAY_BUFFER, rect_points_buffer);

const rect_pos = new Float32Array([
	0.0, 0.0,
	1.0, 0.0,
	0.0, 1.0,
	1.0, 1.0,
]);
gl_ctx.bufferData(gl_ctx.ARRAY_BUFFER, rect_pos, gl_ctx.STATIC_DRAW);

gl_ctx.enableVertexAttribArray(pos_attr);
gl_ctx.vertexAttribPointer(pos_attr, 2, gl_ctx.FLOAT, false, 0, 0);

const idx_arr = new Uint16Array([
	0, 1, 2,
	2, 1, 3,
]);
const rect_idx_buffer = gl_ctx.createBuffer();
gl_ctx.bindBuffer(gl_ctx.ELEMENT_ARRAY_BUFFER, rect_idx_buffer);
gl_ctx.bufferData(gl_ctx.ELEMENT_ARRAY_BUFFER, idx_arr, gl_ctx.STATIC_DRAW);
//

let dpr;
let cached_font = "";
let cached_cursor = "";
let cached_size = 0;
let cached_height = 0;

let loading_file = null;
let loading_reader = null;
let everythings_dead = false;

function implode() {
	document.getElementById("error").classList.remove("hide");
	document.getElementById("rect-display").classList.add("hide");
	document.getElementById("text-display").classList.add("hide");
}

function updateFont(size, font, forced = false) {
	let font_str = `${size * dpr}px ${font}`;
	let cached_font_str = `${cached_size * dpr}px ${cached_font}`;
	if (font_str !== cached_font_str || forced) {
		text_ctx.font = font_str;
		cached_font = font;
		cached_size = size;
		cached_height = text_ctx.measureText('NothinBelowTheBaseline').actualBoundingBoxDescent / dpr;
	}
}

function get_system_colormode() {
	return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function set_error(code) {
	let error_elem = document.getElementById("error-field");
	switch (code) {
		case 1: { // OutOfMemory
			error_elem.innerHTML = 
			`We're out of memory. WASM only supports up to 4 GB of memory *tops*, so files above 1-2 GB aren't always viable to load. If you need bigger file support, let me know! We've got a native version brewing that should run faster and let you use all the memory you can throw at it.`;
		} break;
		case 2: { // Bug
			error_elem.innerHTML = "We hit a bug! Check the JS console for more details. In the meantime, you can try reloading the page and loading your file again.";
		} break;
		case 3: { // Invalid File
			error_elem.innerHTML = "Invalid File! Check the JS console for more details";
		} break;
		case 4: { // Invalid File Version
			error_elem.innerHTML = "Your spall trace is out of date! Check tools/upconvert if you want to upgrade your file, or update to the newest header for next time.";
		} break;
	}
}

async function init() {
	// set default error message to bug in case we get a module-level error
	set_error(2);

	const memory = new WebAssembly.Memory({ initial: 2000, maximum: 65536 });

	try {
		window.wasm = await window.odin.runWasm(`spall.wasm`, null, memory, {
			js: {
				// Canvas
				_canvas_clear() {
					text_ctx.clearRect(0, 0, text_canvas.width, text_canvas.height);
				},
				_canvas_clip(x, y, w, h) {
					text_ctx.restore();
					text_ctx.save();
					text_ctx.beginPath();
					text_ctx.rect(x, y, w, h);
					text_ctx.clip();
				},
				_canvas_rect(x, y, w, h, red, green, blue, alpha) {
					text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					text_ctx.fillRect(x, y, w, h);
				},
				_canvas_rectc(x, y, w, h, r, red, green, blue, alpha) {
					r = Math.min(r, w / 2, h / 2);

					const diw = (w - (2 * r)); // device inner width
					const dih = (h - (2 * r)); // device inner height

					text_ctx.beginPath();
					text_ctx.moveTo(x + r, y);
					text_ctx.lineTo(x + r + diw, y);
					text_ctx.arc(x + r + diw, y + r, r, -Math.PI/2, 0);
					text_ctx.lineTo(x + r + diw + r, y + r + dih);
					text_ctx.arc(x + r + diw, y + r + dih, r, 0, Math.PI/2);
					text_ctx.lineTo(x + r, y + r + dih + r);
					text_ctx.arc(x + r, y + r + dih, r, Math.PI/2, Math.PI);
					text_ctx.lineTo(x, y + r);
					text_ctx.arc(x + r, y + r, r, Math.PI, (3*Math.PI)/2);

					text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					text_ctx.fill();
				},
				_canvas_circle(x, y, radius, red, green, blue, alpha) {
					text_ctx.beginPath();
					text_ctx.arc(x, y, radius, 0, 2*Math.PI, true);

					text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					text_ctx.fill();
				},
				_canvas_text(strP, strLen, x, y, r, g, b, a, size, f, flen) {
					const str = window.wasm.odinMem.loadString(strP, strLen);
					const font = window.wasm.odinMem.loadString(f, flen);
					updateFont(size, font);

					text_ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a})`;
					text_ctx.fillText(str, x * dpr, y * dpr);
				},
				_canvas_line(x1, y1, x2, y2, r, g, b, a, strokeWidth) {
					text_ctx.beginPath();
					text_ctx.moveTo(x1, y1);
					text_ctx.lineTo(x2, y2);

					text_ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, ${a/255})`;
					text_ctx.lineWidth = strokeWidth;
					text_ctx.stroke();
				},
				_canvas_arc(x, y, radius, angleStart, angleEnd, r, g, b, a, strokeWidth) {
					text_ctx.beginPath();
					text_ctx.arc(x, y, radius, -angleStart, -angleEnd - 0.001, true);
					/*
					The 0.001 is because Firefox has some dumb bug where
					it doesn't draw all the way to the end of the arc and
					leaves some empty pixels. Lines don't join up with arcs
					nicely because of it. It sucks but a little bias seems
					to "fix" it.

					Bug report: https://bugzilla.mozilla.org/show_bug.cgi?id=1664959
					*/

					text_ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, ${a/255})`;
					text_ctx.lineWidth = strokeWidth;
					text_ctx.stroke();
				},
				_measure_text: (p, len, size, f, flen) => {
					const str = window.wasm.odinMem.loadString(p, len);
					const font = window.wasm.odinMem.loadString(f, flen);
					updateFont(size, font);
					const metrics = text_ctx.measureText(str);

					return metrics.width / dpr;
				},
				_get_text_height: (size, f, flen) => {
					const font = window.wasm.odinMem.loadString(f, flen);
					updateFont(size, font);
					return cached_height;
				},

				_gl_init_frame: (r, g, b, a) => {
					gl_ctx.viewport(0, 0, gl_ctx.canvas.width, gl_ctx.canvas.height);

					gl_ctx.clearColor(r / 255, g / 255, b / 255, a / 255);
					gl_ctx.clear(gl_ctx.COLOR_BUFFER_BIT);

					gl_ctx.uniform1f(dpr_uni, dpr);
					gl_ctx.uniform2f(resolution_uni, gl_ctx.canvas.width, gl_ctx.canvas.height);

					gl_ctx.bindBuffer(gl_ctx.ARRAY_BUFFER, rect_deets_buffer);
					gl_ctx.bindVertexArray(vao);
				},
				_gl_push_rects: (ptr, len, size, y, height) => {
					let _b = window.wasm.odinMem.loadBytes(ptr, len)

					gl_ctx.bufferData(gl_ctx.ARRAY_BUFFER, _b, gl_ctx.DYNAMIC_DRAW);

					gl_ctx.uniform1f(height_uni, height);
					gl_ctx.uniform1f(y_uni, y);

					gl_ctx.drawElementsInstanced(gl_ctx.TRIANGLES, idx_arr.length, gl_ctx.UNSIGNED_SHORT, 0, size);
				},

				// Debugging
				debugger() { debugger; },
				log_string(p, len) {
					console.log(window.wasm.odinMem.loadString(p, len));
				},
				log_error(p, len) {
					console.error(window.wasm.odinMem.loadString(p, len));
				},
				_push_fatal(code) {
					set_error(code);
				},

				// Utils
				get_session_storage(k, klen) {
					let key = window.wasm.odinMem.loadString(k, klen);
					let data = sessionStorage.getItem(key);
					window.wasm.loaded_session_result(k, klen, ...str(data));
				},
				set_session_storage(k, klen, v, vlen) {
					let key = window.wasm.odinMem.loadString(k, klen);
					let val = window.wasm.odinMem.loadString(v, vlen);

					sessionStorage.setItem(key, val);
				},
				get_time() { return Date.now(); },
				get_system_color() { return get_system_colormode() },
				_pow(x, power) { return Math.pow(x, power); },
				change_cursor(p, len) {
					let cursor_type = window.wasm.odinMem.loadString(p, len);
					if (cursor_type !== cached_cursor) {
						document.body.style.cursor = cursor_type;
						cached_cursor = cursor_type;
					}
				},

				// Config Loading
				get_chunk(offset, size) {
					let blob = loading_file.slice(offset, offset + size);
					loading_reader.onload = (e) => {
						if (e.target.error != null) {
							console.log("Failed to read file: " + e.target.error);
							return;
						}

						try {
							window.wasm.load_config_chunk(offset, loading_file.size, ...bytes(e.target.result));
							wakeUp();
						} catch (e) {
							console.error(e);
							implode();
							return;
						}
					};
					loading_reader.readAsArrayBuffer(blob);
				},

				open_file_dialog() {
					document.getElementById('file-dialog').click();
				}
			},
		});
	} catch (e) {
		console.error(e);
		implode();
		return;
	}

	function load_file(file) {
		loading_file = file;
		loading_reader = new FileReader();

		try {
			window.wasm.start_loading_file(loading_file.size, ...str(loading_file.name));
			wakeUp();
		} catch (e) {
			console.error(e);
			implode();
			return;
		}
	}

	let fd = document.getElementById('file-dialog');
	fd.addEventListener("change", () => {
		if (fd.files.length == 0) {
			return;
		}

		load_file(fd.files[0]);
	}, false);

	let awake = false;
	function wakeUp() {
		if (awake) {
			return;
		}
		awake = true;
		window.requestAnimationFrame(doFrame);
	}

	let pinch_start_pos = [];
	window.addEventListener('touchstart', e => {
		e.preventDefault();

		const containerRect = text_container.getBoundingClientRect();
		if (e.touches.length === 1) {
			let touch = e.touches[0];

			let x = touch.clientX - containerRect.x;
			let y = touch.clientY - containerRect.y;
			window.wasm.mouse_down(x, y);
			wakeUp();
		} else if (e.touches.length === 2) {
			pinch_start_pos[0] = {x: (e.touches[0].clientX - containerRect.x), y: (e.touches[0].clientY - containerRect.y)};
			pinch_start_pos[1] = {x: (e.touches[1].clientX - containerRect.x), y: (e.touches[1].clientY - containerRect.y)};
		}
	}, {passive: false});
	window.addEventListener('touchmove', e => {
		e.preventDefault();

		const containerRect = text_container.getBoundingClientRect();
		if (e.touches.length === 1) {
			let touch = e.touches[0];

			let x = touch.clientX - containerRect.x;
			let y = touch.clientY - containerRect.y;
			window.wasm.mouse_move(x, y);
			wakeUp();
		} else if (e.touches.length === 2) {
			let new_start_pos = [];
			new_start_pos[0] = {x: (e.touches[0].clientX - containerRect.x), y: (e.touches[0].clientY - containerRect.y)};
			new_start_pos[1] = {x: (e.touches[1].clientX - containerRect.x), y: (e.touches[1].clientY - containerRect.y)};

			let old_dist = Math.hypot(pinch_start_pos[0].x - pinch_start_pos[1].x, pinch_start_pos[0].y - pinch_start_pos[1].y);
			let new_dist = Math.hypot(new_start_pos[0].x - new_start_pos[1].x, new_start_pos[0].y - new_start_pos[1].y);

			let deltaY = new_dist - old_dist;

			window.wasm.zoom(0, -deltaY * 2);
			pinch_start_pos = new_start_pos;
			wakeUp();
		}
	}, {passive: false});
	window.addEventListener('touchend', e => {
		e.preventDefault();

		const containerRect = text_container.getBoundingClientRect();

		if (e.touches.length === 0) {
			let touch = e.changedTouches[0];

			let x = touch.clientX - containerRect.x;
			let y = touch.clientY - containerRect.y;
			window.wasm.mouse_up(x, y);
			wakeUp();
		} else if (e.touches.length === 1) {
			let touch = e.touches[0];

			let x = touch.clientX - containerRect.x;
			let y = touch.clientY - containerRect.y;
			window.wasm.mouse_up(x, y);
			wakeUp();
		} else if (e.touches.length === 2) {
			pinch_start_pos = [];
		}

	}, {passive: false});

	window.addEventListener('mousemove', e => {
		const containerRect = text_container.getBoundingClientRect();
		let x = e.clientX - containerRect.x;
		let y = e.clientY - containerRect.y;
		window.wasm.mouse_move(x, y);
		wakeUp();
	});
	window.addEventListener('mousedown', e => {
		if (e.button != 0) {
			return;
		}

		const containerRect = text_container.getBoundingClientRect();
		let x = e.clientX - containerRect.x;
		let y = e.clientY - containerRect.y;
		window.wasm.mouse_down(x, y);
		wakeUp();
	});
	window.addEventListener('mouseup', e => {
		const containerRect = text_container.getBoundingClientRect();

		let x = e.clientX - containerRect.x;
		let y = e.clientY - containerRect.y;
		window.wasm.mouse_up(x, y);
		wakeUp();
	});

	function specialKeyEvent(downOrUp, e) {
		e.preventDefault();

		const func = downOrUp === 'down' ? window.wasm.key_down : window.wasm.key_up;

		/*
		MU_KEY_SHIFT        = (1 << 0),
		MU_KEY_CTRL         = (1 << 1),
		MU_KEY_ALT          = (1 << 2),
		MU_KEY_BACKSPACE    = (1 << 3),
		MU_KEY_RETURN       = (1 << 4),
		MU_KEY_ARROWLEFT    = (1 << 5),
		MU_KEY_ARROWRIGHT   = (1 << 6),
		MU_KEY_ARROWUP      = (1 << 7),
		MU_KEY_ARROWDOWN    = (1 << 8),
		MU_KEY_DELETE       = (1 << 9),
		MU_KEY_HOME         = (1 << 10),
		MU_KEY_END          = (1 << 11),
		MU_KEY_TAB          = (1 << 12),
		*/

		if (e.key === 'Shift') {
			func(1 << 0);
		} else if (e.key === 'Control' || e.key === 'Meta') {
			func(1 << 1);
		} else if (e.key === 'Alt') {
			func(1 << 2);
		} else if (e.key === 'Backspace') {
			func(1 << 3);
		} else if (e.key === 'Enter') {
			func(1 << 4);
		} else if (e.key === 'ArrowLeft') {
			func(1 << 5);
		} else if (e.key === 'ArrowRight') {
			func(1 << 6);
		} else if (e.key === 'ArrowUp') {
			func(1 << 7);
		} else if (e.key === 'ArrowDown') {
			func(1 << 8);
		} else if (e.key === 'Delete') {
			func(1 << 9);
		} else if (e.key === 'Home') {
			func(1 << 10);
		} else if (e.key === 'End') {
			func(1 << 11);
		} else if (e.key === 'Tab') {
			func(1 << 12);
		}

		wakeUp();
	}
	window.addEventListener('keydown', e => {
		if (e.key.length > 1) {
			specialKeyEvent('down', e);
		} else if ( !(e.ctrlKey || e.metaKey) || e.code == 'KeyA' || e.code == 'KeyZ') {
			window.wasm.text_input(...str(e.key), ...str(e.code));
			e.preventDefault();
		}
		wakeUp();
	});
	window.addEventListener('keyup', e => {
		if (e.key.length > 1) {
			specialKeyEvent('up', e);
		}
		wakeUp();
	});

	window.addEventListener('paste', e => {
		let clipdata = str(e.clipboardData.getData('text/plain'));
		window.wasm.text_input(...clipdata);
		wakeUp();
	});
	text_canvas.addEventListener('wheel', e => {
		e.preventDefault();
		let x = e.deltaX;
		let y = e.deltaY;

		if (e.deltaMode === 1) {
			// "lines"
			x *= 20;
			y *= 20;
		}

		window.wasm.scroll(x, y);
		wakeUp();
	}, { passive: false });

	text_canvas.addEventListener('dragover', e => { e.preventDefault(); });
	text_canvas.addEventListener('drop', e => {
		e.preventDefault();

		let initial_chunk_size = 1024 * 1024;
		if (e.dataTransfer.items) {
			[...e.dataTransfer.items].forEach((item, i) => {
				if (item.kind === "file") {
					let file = item.getAsFile();
					load_file(file);
				}
			});
		}
	});
	window.addEventListener('blur', () => {
		window.wasm.blur();
		wakeUp();
	});
	window.addEventListener('focus', () => {
		window.wasm.focus();
		wakeUp();
	});

	let color_ret = sessionStorage.getItem("colormode");
	if (color_ret === "") {
		sessionStorage.setItem("colormode", "auto");
	}
	window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', event => {
		let color_ret = sessionStorage.getItem("colormode");
		if (color_ret === "auto") {
			let is_dark = event.matches;
			window.wasm.set_color_mode(true, is_dark);
			wakeUp();
		}
	})
	if (color_ret === "auto") {
		window.wasm.set_color_mode(true, get_system_colormode())
	} else {
		window.wasm.set_color_mode(false, color_ret === "dark")
	}

	window.wasm.load_build_hash(window.wasm.blob_hash);

	function updateCanvasSize() {
		dpr = window.devicePixelRatio;
		text_canvas.width = text_container.getBoundingClientRect().width * dpr;
		text_canvas.height = text_container.getBoundingClientRect().height * dpr;
		rect_canvas.width = rect_container.getBoundingClientRect().width * dpr;
		rect_canvas.height = rect_container.getBoundingClientRect().height * dpr;
		window.wasm.set_dpr(dpr);

		text_ctx.textBaseline = 'top';
		updateFont(cached_size, cached_font, true);

		wakeUp();
	}
	updateCanvasSize();
	window.addEventListener('resize', () => updateCanvasSize());
	window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener('change', () => updateCanvasSize());

	// TODO: The timer should probably have a cap or otherwise
	// keep ticking in some other way. We have weird issues where
	// the first mouse move after a while fast forwards time
	// by a lot.
	let lastTime = new Date().getTime() / 1000;
	function doFrame() {
		try {
			const currentTime = new Date().getTime() / 1000;

			let animating;
			try {
				animating = window.wasm.frame(text_canvas.width / dpr, text_canvas.height / dpr, currentTime - lastTime);
			} catch (e) {
				console.error(e);
				implode();
				return;
			}

			lastTime = currentTime;

			if (animating) {
				window.requestAnimationFrame(doFrame);
			} else {
				awake = false;
			}
		} catch (error) {
			console.error(error);
		}
	}
	wakeUp();
}

init();

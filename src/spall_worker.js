"use strict";

importScripts('./wasm_runtime.js');

let wasm = {};
let rdr = {};

function updateFont(size, font, forced = false) {
	let font_str = `${size * rdr.dpr}px ${font}`;
	let cached_font_str = `${rdr.cached_size * rdr.dpr}px ${rdr.cached_font}`;
	if (font_str !== cached_font_str || forced) {
		rdr.text_ctx.font = font_str;
		rdr.cached_font = font;
		rdr.cached_size = size;
		rdr.cached_height = rdr.text_ctx.measureText('NothinBelowTheBaseline').actualBoundingBoxDescent / rdr.dpr;
	}
}

function str(s) {
	const bytes = new TextEncoder("utf-8").encode(s);
	const len = bytes.length;
	const p = wasm.temp_allocate(len);
	wasm.odinMem.loadBytes(p, len).set(bytes);
	return [p, BigInt(len)];
}
function bytes(b) {
	const len = b.byteLength;
	const p = wasm.temp_allocate(len);
	let _b = wasm.odinMem.loadBytes(p, len)
	_b.set(new Uint8Array(b));
	return [p, BigInt(len)];
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


let set_error = (code) => {
    console.log(code);
}

let implode = () => {
    console.log("boom");
}

let init = async () => {
    rdr.dpr = 1;
    rdr.cached_font = "";
    rdr.cached_size = 0;
    rdr.cached_height = 0;

    rdr.loading_file = null;
    rdr.loading_reader = null;

    rdr.text_ctx = rdr.text_canvas.getContext('2d');
    rdr.gl_ctx = rdr.rect_canvas.getContext('webgl2', { alpha: false });

    // WebGL2 init
    const shader = init_shader(rdr.gl_ctx, vert_src, frag_src);

    const pos_attr   = rdr.gl_ctx.getAttribLocation(shader, "pos_attr");
    const start_attr = rdr.gl_ctx.getAttribLocation(shader, "x_attr");
    const width_attr = rdr.gl_ctx.getAttribLocation(shader, "width_attr");
    const color_attr = rdr.gl_ctx.getAttribLocation(shader, "color");

    const y_uni      = rdr.gl_ctx.getUniformLocation(shader, "u_y");
    const dpr_uni    = rdr.gl_ctx.getUniformLocation(shader, "u_dpr");
    const height_uni = rdr.gl_ctx.getUniformLocation(shader, "u_height");
    const resolution_uni = rdr.gl_ctx.getUniformLocation(shader, "u_resolution");

    rdr.gl_ctx.enable(rdr.gl_ctx.BLEND);
    rdr.gl_ctx.blendFunc(rdr.gl_ctx.SRC_ALPHA, rdr.gl_ctx.ONE_MINUS_SRC_ALPHA);

    rdr.gl_ctx.useProgram(shader);

    let vao = rdr.gl_ctx.createVertexArray();
    rdr.gl_ctx.bindVertexArray(vao);

    const rect_deets_buffer = rdr.gl_ctx.createBuffer();
    rdr.gl_ctx.bindBuffer(rdr.gl_ctx.ARRAY_BUFFER, rect_deets_buffer);

    let draw_rect_size = 4 + 4 + 4;
    rdr.gl_ctx.enableVertexAttribArray(start_attr);
    rdr.gl_ctx.vertexAttribPointer(start_attr, 1, rdr.gl_ctx.FLOAT, false, draw_rect_size, 0);
    rdr.gl_ctx.vertexAttribDivisor(start_attr, 1);

    rdr.gl_ctx.enableVertexAttribArray(width_attr);
    rdr.gl_ctx.vertexAttribPointer(width_attr, 1, rdr.gl_ctx.FLOAT, false, draw_rect_size, 4);
    rdr.gl_ctx.vertexAttribDivisor(width_attr, 1);

    rdr.gl_ctx.enableVertexAttribArray(color_attr);
    rdr.gl_ctx.vertexAttribPointer(color_attr, 4, rdr.gl_ctx.UNSIGNED_BYTE, true, draw_rect_size, 8);
    rdr.gl_ctx.vertexAttribDivisor(color_attr, 1);

    const rect_points_buffer = rdr.gl_ctx.createBuffer();
    rdr.gl_ctx.bindBuffer(rdr.gl_ctx.ARRAY_BUFFER, rect_points_buffer);

    const rect_pos = new Float32Array([
        0.0, 0.0,
        1.0, 0.0,
        0.0, 1.0,
        1.0, 1.0,
    ]);
    rdr.gl_ctx.bufferData(rdr.gl_ctx.ARRAY_BUFFER, rect_pos, rdr.gl_ctx.STATIC_DRAW);

    rdr.gl_ctx.enableVertexAttribArray(pos_attr);
    rdr.gl_ctx.vertexAttribPointer(pos_attr, 2, rdr.gl_ctx.FLOAT, false, 0, 0);

    const idx_arr = new Uint16Array([
        0, 1, 2,
        2, 1, 3,
    ]);
    const rect_idx_buffer = rdr.gl_ctx.createBuffer();
    rdr.gl_ctx.bindBuffer(rdr.gl_ctx.ELEMENT_ARRAY_BUFFER, rect_idx_buffer);
    rdr.gl_ctx.bufferData(rdr.gl_ctx.ELEMENT_ARRAY_BUFFER, idx_arr, rdr.gl_ctx.STATIC_DRAW);

	// set default error message to bug in case we get a module-level error
	set_error(2);

	const memory = new WebAssembly.Memory({ initial: 2000, maximum: 65536 });

	try {
		wasm = await odin.runWasm(`spall.wasm`, null, memory, {
			js: {
				// Canvas
				_canvas_clear() {
					rdr.text_ctx.clearRect(0, 0, rdr.text_canvas.width, rdr.text_canvas.height);
				},
				_canvas_clip(x, y, w, h) {
					rdr.text_ctx.restore();
					rdr.text_ctx.save();
					rdr.text_ctx.beginPath();
					rdr.text_ctx.rect(x, y, w, h);
					rdr.text_ctx.clip();
				},
				_canvas_rect(x, y, w, h, red, green, blue, alpha) {
					rdr.text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					rdr.text_ctx.fillRect(x, y, w, h);
				},
				_canvas_rectc(x, y, w, h, r, red, green, blue, alpha) {
					r = Math.min(r, w / 2, h / 2);

					const diw = (w - (2 * r)); // device inner width
					const dih = (h - (2 * r)); // device inner height

					rdr.text_ctx.beginPath();
					rdr.text_ctx.moveTo(x + r, y);
					rdr.text_ctx.lineTo(x + r + diw, y);
					rdr.text_ctx.arc(x + r + diw, y + r, r, -Math.PI/2, 0);
					rdr.text_ctx.lineTo(x + r + diw + r, y + r + dih);
					rdr.text_ctx.arc(x + r + diw, y + r + dih, r, 0, Math.PI/2);
					rdr.text_ctx.lineTo(x + r, y + r + dih + r);
					rdr.text_ctx.arc(x + r, y + r + dih, r, Math.PI/2, Math.PI);
					rdr.text_ctx.lineTo(x, y + r);
					rdr.text_ctx.arc(x + r, y + r, r, Math.PI, (3*Math.PI)/2);

					rdr.text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					rdr.text_ctx.fill();
				},
				_canvas_circle(x, y, radius, red, green, blue, alpha) {
					rdr.text_ctx.beginPath();
					rdr.text_ctx.arc(x, y, radius, 0, 2*Math.PI, true);

					rdr.text_ctx.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha/255})`;
					rdr.text_ctx.fill();
				},
				_canvas_text(strP, strLen, x, y, r, g, b, a, size, f, flen) {
					const str = wasm.odinMem.loadString(strP, strLen);
					const font = wasm.odinMem.loadString(f, flen);
					updateFont(size, font);

					rdr.text_ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a})`;
					rdr.text_ctx.fillText(str, x * rdr.dpr, y * rdr.dpr);
				},
				_canvas_line(x1, y1, x2, y2, r, g, b, a, strokeWidth) {
					rdr.text_ctx.beginPath();
					rdr.text_ctx.moveTo(x1, y1);
					rdr.text_ctx.lineTo(x2, y2);

					rdr.text_ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, ${a/255})`;
					rdr.text_ctx.lineWidth = strokeWidth;
					rdr.text_ctx.stroke();
				},
				_canvas_arc(x, y, radius, angleStart, angleEnd, r, g, b, a, strokeWidth) {
					rdr.text_ctx.beginPath();
					rdr.text_ctx.arc(x, y, radius, -angleStart, -angleEnd - 0.001, true);

					// The 0.001 is because Firefox has some dumb bug where
					// it doesn't draw all the way to the end of the arc and
					// leaves some empty pixels. Lines don't join up with arcs
					// nicely because of it. It sucks but a little bias seems
					// to "fix" it.
                    // 
					// Bug report: https://bugzilla.mozilla.org/show_bug.cgi?id=1664959

					rdr.text_ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, ${a/255})`;
					rdr.text_ctx.lineWidth = strokeWidth;
					rdr.text_ctx.stroke();
				},
				_measure_text: (p, len, size, f, flen) => {
					const str = wasm.odinMem.loadString(p, len);
					const font = wasm.odinMem.loadString(f, flen);
					updateFont(size, font);
					const metrics = rdr.text_ctx.measureText(str);

					return metrics.width / rdr.dpr;
				},
				_get_text_height: (size, f, flen) => {
					const font = wasm.odinMem.loadString(f, flen);
					updateFont(size, font);
					return rdr.cached_height;
				},

				_gl_init_frame: (r, g, b, a) => {
					rdr.gl_ctx.viewport(0, 0, rdr.gl_ctx.canvas.width, rdr.gl_ctx.canvas.height);

					rdr.gl_ctx.clearColor(r / 255, g / 255, b / 255, 1.0);
					rdr.gl_ctx.clear(rdr.gl_ctx.COLOR_BUFFER_BIT);

					rdr.gl_ctx.uniform1f(dpr_uni, rdr.dpr);
					rdr.gl_ctx.uniform2f(resolution_uni, rdr.gl_ctx.canvas.width, rdr.gl_ctx.canvas.height);

					rdr.gl_ctx.bindBuffer(rdr.gl_ctx.ARRAY_BUFFER, rect_deets_buffer);
					rdr.gl_ctx.bindVertexArray(vao);
				},
				_gl_push_rects: (ptr, len, size, y, height) => {
					let _b = wasm.odinMem.loadBytes(ptr, len)

					rdr.gl_ctx.bufferData(rdr.gl_ctx.ARRAY_BUFFER, _b, rdr.gl_ctx.DYNAMIC_DRAW);

					rdr.gl_ctx.uniform1f(height_uni, height);
					rdr.gl_ctx.uniform1f(y_uni, y);

					rdr.gl_ctx.drawElementsInstanced(rdr.gl_ctx.TRIANGLES, idx_arr.length, rdr.gl_ctx.UNSIGNED_SHORT, 0, size);
				},

				_push_fatal(code) {
					set_error(code);
				},

				// Utils
				get_session_storage(k, klen) {
					let key = wasm.odinMem.loadString(k, klen);
					let data = sessionStorage.getItem(key);
					wasm.loaded_session_result(k, klen, ...str(data));
				},
				set_session_storage(k, klen, v, vlen) {
					let key = wasm.odinMem.loadString(k, klen);
					let val = wasm.odinMem.loadString(v, vlen);

					sessionStorage.setItem(key, val);
				},
				get_time() { return Date.now(); },
				get_system_color() { return get_system_colormode() },
				_pow(x, power) { return Math.pow(x, power); },
				change_cursor(p, len) {
					let cursor_type = wasm.odinMem.loadString(p, len);
                    self.postMessage({type: 'update-cursor', cursor: cursor_type});
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
							wasm.load_config_chunk(...bytes(e.target.result));
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

        wasm.load_build_hash(wasm.blob_hash);
	} catch (e) {
		console.error(e);
		implode();
		return;
	}

};

let update_size = (dpr, text_dims, rect_dims) => {
    rdr.dpr = dpr;

    rdr.text_canvas.width  = text_dims.width  * dpr;
    rdr.text_canvas.height = text_dims.height * dpr;
    rdr.rect_canvas.width  = rect_dims.width  * dpr;
    rdr.rect_canvas.height = rect_dims.height * dpr;

    wasm.set_dpr(rdr.dpr);
    rdr.text_ctx.textBaseline = 'top';
    updateFont(rdr.cached_size, rdr.cached_font, true);

    wakeUp();
};

let awake = false;
function wakeUp() {
    if (awake) {
        return;
    }
    awake = true;
    requestAnimationFrame(doFrame);
}

let lastTime = new Date().getTime() / 1000;
function doFrame() {
    try {
        const currentTime = new Date().getTime() / 1000;

        let animating;
        try {
            let width = rdr.text_canvas.width / rdr.dpr;
            let height = rdr.text_canvas.height / rdr.dpr;
            animating = wasm.frame(width, height, currentTime - lastTime, currentTime);
        } catch (e) {
            console.error(e);
            implode();
            return;
        }

        lastTime = currentTime;

        if (animating) {
            requestAnimationFrame(doFrame);
        } else {
            awake = false;
        }
    } catch (error) {
        console.error(error);
    }
}

self.onmessage = async (e) => {
    switch (e.data.type) {
        case 'init': {
            rdr.text_canvas = e.data.off_text;
            rdr.rect_canvas = e.data.off_rect;
            await init();

            update_size(e.data.dpr, e.data.text_dims, e.data.rect_dims);
        } break;
        case 'resize': {
            //update_size(e.data.dpr, e.data.text_dims, e.data.rect_dims);
        } break;
        default: {
            console.log("unhandled message");
        }
    }
};

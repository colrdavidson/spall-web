"use strict";

/*

let everythings_dead = false;

function implode() {
	document.getElementById("error").classList.remove("hide");
	document.getElementById("rect-display").classList.add("hide");
	document.getElementById("text-display").classList.add("hide");
}

function get_system_colormode() {
	return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function set_error(code) {
	let error_elem = document.getElementById("error-field");
	switch (code) {
		case 1: { // OutOfMemory
			error_elem.innerHTML = 
			`We're out of memory. WASM only supports up to 4 GB of memory *tops*, so files above 1-2 GB aren't always viable to load. If your trace is smaller than ~1-2 GB, and you're running out of memory, you may have a runaway function stack. Make sure all your begins and ends match! If you need bigger file support, you can grab the native version over at <a href=\"https://gravitymoth.itch.io/spall\">itch.io</a>"`;
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
		case 5: { // Native File Detected
			error_elem.innerHTML = "You're trying to use the native version auto-tracer on the web version of Spall! If you want to try auto-tracing, you can try the one that works for web <a href=\"https://github.com/colrdavidson/spall-web/tree/master/examples/auto_tracing\">here</a> or if your traces are too big to load on the web, grab the native version over at <a href=\"https://gravitymoth.itch.io/spall\">itch.io</a>";
		} break;
	}
}

async function init() {
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

		let file = fd.files[0];
		fd.value = null;
		load_file(file);
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
	if (color_ret === "" || color_ret === null) {
		sessionStorage.setItem("colormode", "auto");
		color_ret = "auto";
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
				let width = text_canvas.width / dpr;
				let height = text_canvas.height / dpr;
				animating = window.wasm.frame(width, height, currentTime - lastTime, currentTime);
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
*/

const text_container = document.querySelector('.text-container');
const rect_container = document.querySelector('.rect-container');
const text_canvas = document.getElementById('text-canvas');
const rect_canvas = document.getElementById('rect-canvas');

function get_canvas_size() {
    let dpr = window.devicePixelRatio;
    let text_dims = {
        width: text_container.getBoundingClientRect().width,
        height: text_container.getBoundingClientRect().height,
    };
    let rect_dims = {
        width: rect_container.getBoundingClientRect().width,
        height: rect_container.getBoundingClientRect().height,
    };
    return [dpr, text_dims, rect_dims];
}
let [dpr, text_dims, rect_dims] = get_canvas_size();

let worker = new Worker('spall_worker.js');
let off_text = text_canvas.transferControlToOffscreen();
let off_rect = rect_canvas.transferControlToOffscreen();
worker.postMessage({
    type: 'init',
    off_text: off_text,
    off_rect: off_rect,

    dpr: dpr,
    text_dims: text_dims,
    rect_dims: rect_dims,
}, [off_text, off_rect]);

window.addEventListener('resize', () => {
    let [dpr, text_dims, rect_dims] = get_canvas_size();
    worker.postMessage({
        type: 'resize',
        dpr: dpr,
        text_dims: text_dims,
        rect_dims: rect_dims
    });
});
window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`).addEventListener('change', () => {
    let [dpr, text_dims, rect_dims] = get_canvas_size();
    worker.postMessage({
        type: 'resize',
        dpr: dpr,
        text_dims: text_dims,
        rect_dims: rect_dims
    });
});

let cached_cursor = "";

worker.addEventListener("message", (e) => {
    switch (e.data.type) {
        case 'update-cursor': {
            let cursor_type = e.data.cursor;
            if (cursor_type !== cached_cursor) {
                document.body.style.cursor = cursor_type;
                cached_cursor = cursor_type;
            }
        } break;
        default: {
            console.log("unhandled message");
        }
    }
});

//init();

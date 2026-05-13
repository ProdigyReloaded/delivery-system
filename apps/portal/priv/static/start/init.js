var statusElement = document.getElementById("status"),
	progressElement = document.getElementById("progress"),
	spinnerElement = document.getElementById("spinner"),
	toggleOutputElement = document.getElementById("toggle-output"),
	Module = {
		print: function () {
			var e = document.getElementById("output"); return e && (e.value = ""), (...t) => {
				var n = t.join(" "); console.log(n), e && (e.value += n + "\n", e.scrollTop = e.scrollHeight)
			}
		}(),
		canvas: (() => {
			var e = document.getElementById("canvas"); return e.addEventListener("webglcontextlost", (e => { alert("WebGL context lost. You will need to reload the page."), e.preventDefault() }), !1), e
		}
		)(),
		setStatus: e => {
			if (Module.setStatus.last ??= { time: Date.now(), text: "" }, e !== Module.setStatus.last.text) {
				var t = e.match(/([^(]+)\((\d+(\.\d+)?)\/(\d+)\)/), n = Date.now();
				t && n - Module.setStatus.last.time < 30 || (
					Module.setStatus.last.time = n,
					Module.setStatus.last.text = e,
					t ? (e = t[1], progressElement.value = 100 * parseInt(t[2]), progressElement.max = 100 * parseInt(t[4]), progressElement.hidden = !1, spinnerElement.hidden = !1) : (progressElement.value = null, progressElement.max = null, progressElement.hidden = !0, e || (spinnerElement.style.display = "none")),
					statusElement.innerHTML = e
				)
			}
		},
		totalDependencies: 0,
		monitorRunDependencies: e => {
			this.totalDependencies = Math.max(this.totalDependencies, e), Module.setStatus(e ? "Preparing... (" + (this.totalDependencies - e) + "/" + this.totalDependencies + ")" : "All downloads complete.")
		},
		// Emscripten loader.js and dosbox.js fetch companion assets (the
		// rs-6.03.17.data VFS blob and dosbox.wasm) via a bare relative
		// filename. The page is served at /start (no trailing slash), so
		// the browser resolves those to / and 404s. Forcing locateFile to
		// prepend /start/ fixes it.  TODO add this to em-dosbox build pipeline
		locateFile: (path) => "/start/" + path
	};
Module.setStatus("Downloading..."),
	window.onerror = e => {
		Module.setStatus("Exception thrown, see JavaScript console"),
			spinnerElement.style.display = "none",
			Module.setStatus = e => {
				e && console.error("[post-exception status] " + e)
			}
	}

// Handle console toggler button:
toggleOutputElement.addEventListener('change', (e) => {
	const output = document.querySelector('#output');
	output.classList.toggle('invisible', !e.target.checked);
});

// em-dosbox registers document-level capture-phase handlers for
// keydown/keypress/keyup and calls preventDefault() on every key, so
// an ordinary <input> elsewhere on the page gets no keystrokes *and*
// any JS keydown listener attached to that input never fires (the
// event is preventDefault'd at document capture before it reaches the
// input). Instead of shielding at window capture (which breaks
// listeners on the input itself), expose pauseKeyboard() /
// resumeKeyboard() helpers that walk emscripten's JSEvents.eventHandlers
// and temporarily detach the key listeners. Call pauseKeyboard() when
// a real <input> takes focus; resumeKeyboard() on blur or unmount.
//
// This is so that while paused, DOSBox simply doesn't see keys, and
// every other listener in the page works normally.
window.ProdigyDOSBox = {
	_savedHandlers: [],
	pauseKeyboard: function () {
		if (typeof JSEvents === 'undefined' || !JSEvents.eventHandlers) return;
		for (var i = 0; i < JSEvents.eventHandlers.length; i++) {
			var h = JSEvents.eventHandlers[i];
			if (h.eventTypeString === 'keydown' ||
				h.eventTypeString === 'keypress' ||
				h.eventTypeString === 'keyup') {
				h.target.removeEventListener(h.eventTypeString, h.eventListenerFunc, h.useCapture);
				this._savedHandlers.push(h);
			}
		}
	},
	resumeKeyboard: function () {
		while (this._savedHandlers.length) {
			var h = this._savedHandlers.pop();
			h.target.addEventListener(h.eventTypeString, h.eventListenerFunc, h.useCapture);
		}
	}
};

// Warn before navigating away / closing the tab while a TCS WebSocket
// (the DOS client's connection to the Prodigy server) is open.
// Wrap WebSocket construction so every socket whose URL points at the
// TCS endpoint increments an open-count; beforeunload bails if the
// count is non-zero. Modern browsers render their own generic prompt
// text regardless of what is set - the hook still fires reliably.
// Must run before dosbox.js so the wrapper is in place when em-dosbox
// opens its socket.
(function installTcsBeforeUnloadGuard() {
	var Native = window.WebSocket;
	if (!Native) return;

	var openTcsCount = 0;

	function isTcsUrl(url) {
		return typeof url === 'string' && /\/tcs(\?|#|$)/.test(url);
	}

	function WrappedWebSocket(url, protocols) {
		var ws = protocols !== undefined ? new Native(url, protocols) : new Native(url);

		if (isTcsUrl(url)) {
			openTcsCount++;
			ws.addEventListener('close', function dec() {
				if (openTcsCount > 0) openTcsCount--;
			}, { once: true });
		}

		return ws;
	}

	// Preserve prototype + static readyState constants so code that
	// does `ws instanceof WebSocket` or reads `WebSocket.OPEN` still
	// works after replacing the global.
	WrappedWebSocket.prototype = Native.prototype;
	WrappedWebSocket.CONNECTING = Native.CONNECTING;
	WrappedWebSocket.OPEN = Native.OPEN;
	WrappedWebSocket.CLOSING = Native.CLOSING;
	WrappedWebSocket.CLOSED = Native.CLOSED;

	window.WebSocket = WrappedWebSocket;

	window.addEventListener('beforeunload', function (e) {
		if (openTcsCount > 0) {
			e.preventDefault();
			// Chrome still requires returnValue; Firefox honors
			// preventDefault alone. Text is ignored in practice.
			e.returnValue = '';
		}
	});
})();


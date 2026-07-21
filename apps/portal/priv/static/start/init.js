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
		locateFile: (path) => "/start/" + path,
		// Persistent client storage: before the emulator runs, mount IDBFS
		// over the client's C: drive so its mutable CACHE.DAT / STAGE.DAT
		// survive page reloads. Implementation in the block below.
		preRun: [function () { __prodigyPersistPreRun(); }]
	};
Module.setStatus("Downloading..."),
	window.onerror = e => {
		Module.setStatus("Exception thrown, see JavaScript console"),
			spinnerElement.style.display = "none",
			Module.setStatus = e => {
				e && console.error("[post-exception status] " + e)
			}
	}

// ===== Persistent client storage (IDBFS overlay of mutable files) =====
//
// The client image loads into MEMFS, which is wiped every reload — which is
// why nothing persisted before. DOSBox auto-mounts the FS root as C: (from
// loader.js's ['./PRODIGY.BAT']); that launch argument is snapshotted at
// dosbox.js load time, so preRun can't repoint it. Instead we leave C: as
// the MEMFS root and persist ONLY the client's mutable files: on boot, mount
// IDBFS at /persist, load it, and overlay any saved copies onto the root; on
// a timer and on unload, copy the current files back and syncfs to IndexedDB.
// This is also the better design — a new client bundle refreshes RS.EXE etc.
// while the user's CACHE.DAT / STAGE.DAT carry forward. Module.FS / IDBFS are
// exposed by the emulator's expose-runtime pre-js.
//
// Client-version guard: bump __PRODIGY_CLIENT_VERSION whenever the shipped
// client image (rs-<version>.data) changes. If the persisted cache was written
// under a different version, it is NOT overlaid — the client starts fresh from
// the new image, avoiding stale/incompatible cache across an upgrade.
var __PRODIGY_MUTABLE = ["CACHE.DAT", "STAGE.DAT"];
var __PRODIGY_CLIENT_VERSION = "6.03.17";
var __PRODIGY_VERSION_FILE = "/persist/.client_version";

function __prodigyPersistPreRun() {
	var FS = Module.FS, IDBFS = Module.IDBFS;
	if (!FS || !IDBFS) { console.error("[persist] FS/IDBFS not exposed — skipping"); return; }
	try { FS.mkdir("/persist"); } catch (e) {}
	FS.mount(IDBFS, {}, "/persist");
	// Block startup until the persisted filesystem has loaded.
	Module.addRunDependency("prodigy-idbfs");
	FS.syncfs(true, function (err) {
		if (err) console.error("[persist] IDBFS load failed:", err);
		var savedVer = null;
		try { savedVer = new TextDecoder().decode(FS.readFile(__PRODIGY_VERSION_FILE)); } catch (e) {}
		if (savedVer && savedVer !== __PRODIGY_CLIENT_VERSION) {
			console.log("[persist] client version changed (" + savedVer + " -> " +
				__PRODIGY_CLIENT_VERSION + ") — starting fresh, not overlaying old cache");
		} else {
			var restored = 0;
			__PRODIGY_MUTABLE.forEach(function (f) {
				try { FS.writeFile("/" + f, FS.readFile("/persist/" + f)); restored++; } catch (e) {}
			});
			console.log(restored
				? "[persist] restored " + restored + " file(s) from IndexedDB"
				: "[persist] first run — no saved state, using image defaults");
		}
		__prodigyInstallSyncTimers();
		Module.removeRunDependency("prodigy-idbfs");
	});
}

// Copy the client's current mutable files from C:\ (MEMFS root) into IDBFS,
// stamp the client version, and flush to IndexedDB. Runs on a timer and on
// unload; also exposed as window.__prodigyFlush() for manual triggering.
function __prodigyInstallSyncTimers() {
	var FS = Module.FS;
	var flushing = false;
	var flush = function () {
		if (flushing) return;
		flushing = true;
		var saved = 0;
		__PRODIGY_MUTABLE.forEach(function (f) {
			try { FS.writeFile("/persist/" + f, FS.readFile("/" + f)); saved++; } catch (e) {}
		});
		try { FS.writeFile(__PRODIGY_VERSION_FILE, new TextEncoder().encode(__PRODIGY_CLIENT_VERSION)); } catch (e) {}
		FS.syncfs(false, function () {
			flushing = false;
			console.log("[persist] flushed " + saved + " file(s) to IndexedDB");
		});
	};
	setInterval(flush, 10000);
	window.addEventListener("beforeunload", flush);
	window.__prodigyFlush = flush;
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


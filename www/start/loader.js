  var Module = typeof Module != 'undefined' ? Module : {};

  Module['expectedDataFileDownloads'] ??= 0;
  Module['expectedDataFileDownloads']++;
  (() => {
    // Do not attempt to redownload the virtual filesystem data when in a pthread or a Wasm Worker context.
    var isPthread = typeof ENVIRONMENT_IS_PTHREAD != 'undefined' && ENVIRONMENT_IS_PTHREAD;
    var isWasmWorker = typeof ENVIRONMENT_IS_WASM_WORKER != 'undefined' && ENVIRONMENT_IS_WASM_WORKER;
    if (isPthread || isWasmWorker) return;
    var isNode = typeof process === 'object' && typeof process.versions === 'object' && typeof process.versions.node === 'string';
    async function loadPackage(metadata) {

      var PACKAGE_PATH = '';
      if (typeof window === 'object') {
        PACKAGE_PATH = window['encodeURIComponent'](window.location.pathname.substring(0, window.location.pathname.lastIndexOf('/')) + '/');
      } else if (typeof process === 'undefined' && typeof location !== 'undefined') {
        // web worker
        PACKAGE_PATH = encodeURIComponent(location.pathname.substring(0, location.pathname.lastIndexOf('/')) + '/');
      }
      var PACKAGE_NAME = '/src/em-dosbox/src/rs-6.03.17.data';
      var REMOTE_PACKAGE_BASE = 'rs-6.03.17.data';
      var REMOTE_PACKAGE_NAME = Module['locateFile']?.(REMOTE_PACKAGE_BASE, '') ?? REMOTE_PACKAGE_BASE;
      var REMOTE_PACKAGE_SIZE = metadata['remote_package_size'];

      async function fetchRemotePackage(packageName, packageSize) {
        if (isNode) {
          var fsPromises = require('fs/promises');
          var contents = await fsPromises.readFile(packageName);
          return contents.buffer;
        }
        Module['dataFileDownloads'] ??= {};
        try {
          var response = await fetch(packageName);
        } catch (e) {
          throw new Error(`Network Error: ${packageName}`, {e});
        }
        if (!response.ok) {
          throw new Error(`${response.status}: ${response.url}`);
        }

        const chunks = [];
        const headers = response.headers;
        const total = Number(headers.get('Content-Length') ?? packageSize);
        let loaded = 0;

        Module['setStatus']?.('Downloading data...');
        const reader = response.body.getReader();

        while (1) {
          var {done, value} = await reader.read();
          if (done) break;
          chunks.push(value);
          loaded += value.length;
          Module['dataFileDownloads'][packageName] = {loaded, total};

          let totalLoaded = 0;
          let totalSize = 0;

          for (const download of Object.values(Module['dataFileDownloads'])) {
            totalLoaded += download.loaded;
            totalSize += download.total;
          }

          Module['setStatus']?.(`Downloading data... (${totalLoaded}/${totalSize})`);
        }

        const packageData = new Uint8Array(chunks.map((c) => c.length).reduce((a, b) => a + b, 0));
        let offset = 0;
        for (const chunk of chunks) {
          packageData.set(chunk, offset);
          offset += chunk.length;
        }
        return packageData.buffer;
      }

      var fetchedCallback;
      var fetched = Module['getPreloadedPackage']?.(REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE);

      if (!fetched) {
        // Note that we don't use await here because we want to execute the
        // the rest of this function immediately.
        fetchRemotePackage(REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE)
          .then((data) => {
            if (fetchedCallback) {
              fetchedCallback(data);
              fetchedCallback = null;
            } else {
              fetched = data;
            }
          });
      }

    async function runWithFS(Module) {

      function assert(check, msg) {
        if (!check) throw new Error(msg);
      }

      /** @constructor */
      function DataRequest(start, end, audio) {
        this.start = start;
        this.end = end;
        this.audio = audio;
      }
      DataRequest.prototype = {
        requests: {},
        open: function(mode, name) {
          this.name = name;
          this.requests[name] = this;
          Module['addRunDependency'](`fp ${this.name}`);
        },
        send: function() {},
        onload: function() {
          var byteArray = this.byteArray.subarray(this.start, this.end);
          this.finish(byteArray);
        },
        finish: async function(byteArray) {
          var that = this;
          // canOwn this data in the filesystem, it is a slice into the heap that will never change
          Module['FS_createDataFile'](this.name, null, byteArray, true, true, true);
          Module['removeRunDependency'](`fp ${that.name}`);
          this.requests[this.name] = null;
        }
      };

      var files = metadata['files'];
      for (var i = 0; i < files.length; ++i) {
        new DataRequest(files[i]['start'], files[i]['end'], files[i]['audio'] || 0).open('GET', files[i]['filename']);
      }

      function processPackageData(arrayBuffer) {
        assert(arrayBuffer, 'Loading data file failed.');
        assert(arrayBuffer.constructor.name === ArrayBuffer.name, 'bad input to processPackageData');
        var byteArray = new Uint8Array(arrayBuffer);
        var curr;
        // Reuse the bytearray from the XHR as the source for file reads.
          DataRequest.prototype.byteArray = byteArray;
          var files = metadata['files'];
          for (var i = 0; i < files.length; ++i) {
            DataRequest.prototype.requests[files[i].filename].onload();
          }          Module['removeRunDependency']('datafile_/src/em-dosbox/src/rs-6.03.17.data');

      }
      Module['addRunDependency']('datafile_/src/em-dosbox/src/rs-6.03.17.data');

      Module['preloadResults'] ??= {};

      Module['preloadResults'][PACKAGE_NAME] = {fromCache: false};
      if (fetched) {
        processPackageData(fetched);
        fetched = null;
      } else {
        fetchedCallback = processPackageData;
      }

    }
    if (Module['calledRun']) {
      runWithFS(Module);
    } else {
      (Module['preRun'] ??= []).push(runWithFS); // FS is not initialized yet, wait for it
    }

    }
    loadPackage({"files": [{"filename": "/CACHE.DAT", "start": 0, "end": 61440}, {"filename": "/CLUB.BAT", "start": 61440, "end": 61768}, {"filename": "/CONFIG.SM", "start": 61768, "end": 61954}, {"filename": "/DRIVER.SCR", "start": 61954, "end": 86519}, {"filename": "/EGA320.SCR", "start": 86519, "end": 98673}, {"filename": "/EGA640.SCR", "start": 98673, "end": 110333}, {"filename": "/HUFFMAN.DAT", "start": 110333, "end": 114421}, {"filename": "/INS_ICON.TRX", "start": 114421, "end": 114459}, {"filename": "/KEYS.TRX", "start": 114459, "end": 115483}, {"filename": "/LOG_KEYS.TRX", "start": 115483, "end": 115681}, {"filename": "/MTRES.EXE", "start": 115681, "end": 123483}, {"filename": "/MTSHUT.EXE", "start": 123483, "end": 125759}, {"filename": "/NOT_ENUF.BAT", "start": 125759, "end": 126764}, {"filename": "/PRODIGY.BAT", "start": 126764, "end": 126827}, {"filename": "/RELOAD.BAT", "start": 126827, "end": 127141}, {"filename": "/RS.EXE", "start": 127141, "end": 314162}, {"filename": "/STAGE.DAT", "start": 314162, "end": 514226}, {"filename": "/STARTUTL.EXE", "start": 514226, "end": 521245}, {"filename": "/TLFD0000", "start": 521245, "end": 521312}, {"filename": "/VAN.Y", "start": 521312, "end": 521421}, {"filename": "/VDIPLP.TTX", "start": 521421, "end": 592974}, {"filename": "/VGA640.SCR", "start": 592974, "end": 617539}, {"filename": "/WAIT.BAT", "start": 617539, "end": 617863}, {"filename": "/WAITICON.TRX", "start": 617863, "end": 617935}, {"filename": "/XTG00010.DAT", "start": 617935, "end": 618935}, {"filename": "/dosbox.conf", "start": 618935, "end": 619000}, {"filename": "/xtg00010", "start": 619000, "end": 620000}], "remote_package_size": 620000});

  })();

Module['arguments'] = [ './PRODIGY.BAT' ];

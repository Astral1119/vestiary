import AppKit
import WebKit

// Runtime diagnostics and evidence collection for web wallpaper audits.
func webAuditDiagnosticsBootstrap() -> String {
    #"""
    (function () {
        'use strict';
        const limit = 96;
        const state = window.__frescoAudit = {
            schemaVersion: 1,
            console: [],
            network: [],
            mediaErrors: [],
            webgl: [],
            indexedDB: { available: Boolean(window.indexedDB), databases: [], requests: [] }
        };
        const boundedPush = function (array, value) {
            if (array.length < limit) array.push(value);
        };
        const text = function (value) {
            try {
                if (typeof value === 'string') return value.slice(0, 2048);
                if (value instanceof Error) return (value.name + ': ' + value.message).slice(0, 2048);
                const encoded = JSON.stringify(value);
                return String(encoded === undefined ? value : encoded).slice(0, 2048);
            } catch (_) {
                return String(value).slice(0, 2048);
            }
        };
        const errorText = function (error) {
            return error ? text(error.name || 'Error') + ': ' + text(error.message || error) : '';
        };
        const now = function () { return Math.round(performance.now()); };

        for (const level of ['debug', 'info', 'log', 'warn', 'error']) {
            const original = console[level];
            if (typeof original !== 'function') continue;
            console[level] = function () {
                boundedPush(state.console, {
                    level: level,
                    timeMilliseconds: now(),
                    arguments: Array.from(arguments).slice(0, 12).map(text)
                });
                return original.apply(console, arguments);
            };
        }

        if (typeof window.fetch === 'function') {
            const originalFetch = window.fetch;
            window.fetch = function (input, init) {
                const record = {
                    api: 'fetch',
                    method: text(init && init.method || input && input.method || 'GET').toUpperCase(),
                    url: text(input && input.url || input),
                    startedMilliseconds: now()
                };
                boundedPush(state.network, record);
                try {
                    return originalFetch.apply(this, arguments).then(function (response) {
                        record.finishedMilliseconds = now();
                        record.ok = response.ok;
                        record.status = response.status;
                        record.type = response.type;
                        record.responseURL = text(response.url);
                        return response;
                    }, function (error) {
                        record.finishedMilliseconds = now();
                        record.error = errorText(error);
                        throw error;
                    });
                } catch (error) {
                    record.finishedMilliseconds = now();
                    record.error = errorText(error);
                    throw error;
                }
            };
        }

        if (window.XMLHttpRequest) {
            const open = XMLHttpRequest.prototype.open;
            const send = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function (method, url) {
                this.__frescoAuditRequest = {
                    api: 'xhr', method: text(method).toUpperCase(), url: text(url)
                };
                return open.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function () {
                const request = this.__frescoAuditRequest || { api: 'xhr', method: 'GET', url: '' };
                request.startedMilliseconds = now();
                boundedPush(state.network, request);
                const finish = function () {
                    if (request.finishedMilliseconds !== undefined) return;
                    request.finishedMilliseconds = now();
                    request.status = this.status;
                    request.responseURL = text(this.responseURL);
                };
                const fail = function (event) {
                    finish.call(this);
                    request.error = event.type;
                };
                this.addEventListener('load', finish);
                this.addEventListener('error', fail);
                this.addEventListener('abort', fail);
                this.addEventListener('timeout', fail);
                return send.apply(this, arguments);
            };
        }

        document.addEventListener('error', function (event) {
            const target = event.target;
            if (!(target instanceof HTMLMediaElement)) return;
            boundedPush(state.mediaErrors, {
                tag: target.tagName.toLowerCase(),
                url: text(target.currentSrc || target.src),
                code: target.error ? target.error.code : null,
                message: target.error ? text(target.error.message) : '',
                networkState: target.networkState,
                readyState: target.readyState
            });
        }, true);

        if (window.indexedDB) {
            const openDatabase = indexedDB.open.bind(indexedDB);
            indexedDB.open = function (name, version) {
                const record = { name: text(name), version: version === undefined ? null : version };
                if (state.indexedDB.requests.length < 32) state.indexedDB.requests.push(record);
                const request = openDatabase.apply(indexedDB, arguments);
                request.addEventListener('success', function () {
                    record.resultVersion = request.result.version;
                    record.objectStores = Array.from(request.result.objectStoreNames).slice(0, 32);
                });
                request.addEventListener('error', function () {
                    record.error = errorText(request.error);
                });
                return request;
            };
        }
        if (window.indexedDB && typeof indexedDB.databases === 'function') {
            indexedDB.databases().then(function (databases) {
                state.indexedDB.databases = databases.slice(0, 32).map(function (database) {
                    return { name: text(database.name), version: database.version };
                });
            }, function (error) {
                state.indexedDB.error = errorText(error);
            });
        }

        const contextIDs = new WeakMap();
        const contextRecords = [];
        let nextContextID = 1;
        const getContext = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function (kind) {
            const context = getContext.apply(this, arguments);
            const requested = String(kind || '').toLowerCase();
            if (!/^webgl2?$/.test(requested) && requested !== 'experimental-webgl') return context;
            if (!context) {
                boundedPush(state.webgl, { event: 'context', requested: requested, available: false });
                return context;
            }
            if (contextIDs.has(context)) return context;
            const id = nextContextID++;
            contextIDs.set(context, id);
            const record = {
                id: id,
                event: 'context',
                requested: requested,
                available: true,
                actual: typeof WebGL2RenderingContext !== 'undefined' &&
                    context instanceof WebGL2RenderingContext ? 'webgl2' : 'webgl',
                drawingBufferWidth: context.drawingBufferWidth,
                drawingBufferHeight: context.drawingBufferHeight,
                shaders: [],
                programs: []
            };
            contextRecords.push({ context: context, canvas: this, record: record });
            boundedPush(state.webgl, record);
            const shaderSource = context.shaderSource.bind(context);
            const compileShader = context.compileShader.bind(context);
            const linkProgram = context.linkProgram.bind(context);
            context.shaderSource = function (shader, source) {
                shader.__frescoAuditSourceLength = String(source || '').length;
                return shaderSource(shader, source);
            };
            context.compileShader = function (shader) {
                const result = compileShader(shader);
                if (record.shaders.length < 32) record.shaders.push({
                    type: context.getShaderParameter(shader, context.SHADER_TYPE),
                    sourceLength: shader.__frescoAuditSourceLength || 0,
                    compiled: Boolean(context.getShaderParameter(shader, context.COMPILE_STATUS)),
                    log: text(context.getShaderInfoLog(shader) || '')
                });
                return result;
            };
            context.linkProgram = function (program) {
                const result = linkProgram(program);
                if (record.programs.length < 16) record.programs.push({
                    linked: Boolean(context.getProgramParameter(program, context.LINK_STATUS)),
                    log: text(context.getProgramInfoLog(program) || ''),
                    activeAttributes: context.getProgramParameter(program, context.ACTIVE_ATTRIBUTES),
                    activeUniforms: context.getProgramParameter(program, context.ACTIVE_UNIFORMS)
                });
                return result;
            };
            this.addEventListener('webglcontextlost', function (event) {
                boundedPush(state.webgl, { event: 'contextlost', id: id });
            });
            this.addEventListener('webglcontextrestored', function () {
                boundedPush(state.webgl, { event: 'contextrestored', id: id });
            });
            return context;
        };

        const storageSnapshot = function (storage) {
            if (!storage) return { available: false, keys: [] };
            try {
                const keys = [];
                for (let index = 0; index < Math.min(storage.length, 32); index++) {
                    keys.push(text(storage.key(index)));
                }
                return { available: true, length: storage.length, keys: keys };
            } catch (error) {
                return { available: false, keys: [], error: errorText(error) };
            }
        };
        const mediaCapabilities = function () {
            const element = document.createElement('video');
            const types = [
                'audio/ogg; codecs="vorbis"',
                'audio/ogg; codecs="opus"',
                'video/webm; codecs="vp8, vorbis"',
                'video/webm; codecs="vp9, opus"',
                'video/mp4; codecs="avc1.42E01E, mp4a.40.2"'
            ];
            const support = {};
            for (const type of types) support[type] = element.canPlayType(type);
            return support;
        };
        const canvasEvidence = function (entry) {
            const gl = entry.context;
            const width = Math.max(0, Math.min(gl.drawingBufferWidth, 512));
            const height = Math.max(0, Math.min(gl.drawingBufferHeight, 512));
            if (!width || !height || gl.isContextLost()) {
                return { id: entry.record.id, contextLost: gl.isContextLost(), width: width, height: height };
            }
            try {
                const pixels = new Uint8Array(width * height * 4);
                gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
                let hash = 2166136261;
                const colors = new Set();
                let nonzeroAlpha = 0;
                const stride = Math.max(4, Math.floor(pixels.length / 4096 / 4) * 4);
                for (let index = 0; index < pixels.length; index += stride) {
                    const color = (pixels[index] >> 4) << 12 |
                        (pixels[index + 1] >> 4) << 8 |
                        (pixels[index + 2] >> 4) << 4 | (pixels[index + 3] >> 4);
                    colors.add(color);
                    if (pixels[index + 3]) nonzeroAlpha++;
                    for (let offset = 0; offset < 4; offset++) {
                        hash ^= pixels[index + offset];
                        hash = Math.imul(hash, 16777619);
                    }
                }
                return {
                    id: entry.record.id,
                    contextLost: false,
                    width: width,
                    height: height,
                    uniqueQuantizedColors: colors.size,
                    nonzeroAlphaSamples: nonzeroAlpha,
                    sampleHash: (hash >>> 0).toString(16).padStart(8, '0')
                };
            } catch (error) {
                return { id: entry.record.id, error: errorText(error), width: width, height: height };
            }
        };
        window.__frescoAuditSnapshot = function () {
            return {
                schemaVersion: state.schemaVersion,
                console: state.console.slice(),
                network: state.network.slice(),
                storage: {
                    local: storageSnapshot(window.localStorage),
                    session: storageSnapshot(window.sessionStorage),
                    indexedDB: state.indexedDB
                },
                fonts: document.fonts ? Array.from(document.fonts).slice(0, 64).map(function (font) {
                    return { family: text(font.family), style: font.style, weight: font.weight,
                        status: font.status };
                }) : [],
                media: {
                    canPlayType: mediaCapabilities(),
                    errors: state.mediaErrors.slice(),
                    elements: Array.from(document.querySelectorAll('audio,video')).slice(0, 32)
                        .map(function (element) {
                            return {
                                tag: element.tagName.toLowerCase(),
                                url: text(element.currentSrc || element.src),
                                errorCode: element.error ? element.error.code : null,
                                errorMessage: element.error ? text(element.error.message) : '',
                                networkState: element.networkState,
                                readyState: element.readyState
                            };
                        })
                },
                webgl: {
                    events: state.webgl.slice(),
                    canvases: contextRecords.slice(0, 16).map(canvasEvidence)
                }
            };
        };
    })();
    """#
}

func auditRenderMetrics(_ image: NSImage) -> [String: Any]? {
    guard let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data) else { return nil }
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    guard width > 0, height > 0 else { return nil }

    let stepX = max(1, width / 96)
    let stepY = max(1, height / 54)
    var luminance: [Double] = []
    var opaque = 0
    var colors = Set<Int>()
    for y in stride(from: 0, to: height, by: stepY) {
        for x in stride(from: 0, to: width, by: stepX) {
            guard let rawColor = bitmap.colorAt(x: x, y: y),
                  let color = rawColor.usingColorSpace(.deviceRGB) else { continue }
            let alpha = Double(color.alphaComponent)
            if alpha > 0.02 { opaque += 1 }
            let red = Double(color.redComponent)
            let green = Double(color.greenComponent)
            let blue = Double(color.blueComponent)
            luminance.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            let quantized = Int(red * 15) << 8 | Int(green * 15) << 4 | Int(blue * 15)
            colors.insert(quantized)
        }
    }
    guard !luminance.isEmpty else { return nil }
    let mean = luminance.reduce(0, +) / Double(luminance.count)
    let variance = luminance.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        / Double(luminance.count)
    let deviation = sqrt(variance)
    let opaqueFraction = Double(opaque) / Double(luminance.count)
    let nonBlank = opaqueFraction > 0.01 && (colors.count >= 8 || deviation >= 0.015)
    return [
        "width": width,
        "height": height,
        "sampleCount": luminance.count,
        "uniqueQuantizedColors": colors.count,
        "meanLuminance": mean,
        "luminanceDeviation": deviation,
        "opaqueFraction": opaqueFraction,
        "nonBlank": nonBlank,
    ]
}

func auditAssetRecords(properties: [String: Any], root: URL,
                       activity: [String: Any]) -> [[String: Any]] {
    var records: [[String: Any]] = []
    for (name, rawDefinition) in properties {
        guard let definition = rawDefinition as? [String: Any],
              let type = (definition["type"] as? String)?.lowercased(),
              type == "file" || type == "directory",
              let rawPath = definition["value"] as? String, !rawPath.isEmpty else { continue }
        let path = (rawPath as NSString).expandingTildeInPath
        let url = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path).standardizedFileURL
            : root.appendingPathComponent(path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        var record: [String: Any] = [
            "property": name,
            "type": type,
            "path": url.path,
            "exists": exists,
            "isDirectory": exists && isDirectory.boolValue,
        ]
        record["active"] = activity[name] ?? NSNull()
        records.append(record)
    }
    return records.sorted {
        ($0["property"] as? String ?? "") < ($1["property"] as? String ?? "")
    }
}

final class WebWallpaperAudit: NSObject, WKNavigationDelegate {
    private let wallpaperPath: String
    private let reportURL: URL
    private let snapshotURL: URL
    private var host: WebHost?
    private var auditWindow: NSWindow?
    private var audioTimer: Timer?
    private var timeoutTimer: Timer?
    private var pageLogs: [String] = []
    private var navigationErrors: [String] = []
    private var contentProcessTerminated = false
    private var attempts = 0
    private let started = Date()

    init(wallpaperPath: String, reportPath: String, snapshotPath: String) {
        self.wallpaperPath = wallpaperPath
        reportURL = URL(fileURLWithPath: reportPath)
        snapshotURL = URL(fileURLWithPath: snapshotPath)
    }

    func run() -> Never {
        guard case .web(let index, let root, let properties)? = resolveWallpaper(wallpaperPath),
              let screen = NSScreen.main else {
            writeEarlyFailure("wallpaper did not resolve to a web project")
        }

        let frame = NSRect(x: -12_000, y: -12_000, width: 960, height: 540)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.orderBack(nil)
        auditWindow = window

        let host = WebHost(
            screen: screen, index: index, root: root, properties: properties,
            attachTo: window, auditDiagnostics: true)
        host.onPageLog = { [weak self] in self?.pageLogs.append($0) }
        host.webView.navigationDelegate = self
        self.host = host

        let syntheticAudio = (0..<128).map { index in
            0.15 + 0.65 * abs(sin(Double(index) * .pi / 31.0))
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            self?.host?.push(audio: syntheticAudio)
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 18, repeats: false) {
            [weak self] _ in
            self?.finish(pageState: ["readyState": "timeout"], metrics: nil,
                         snapshotError: "audit timed out")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.sample()
        }
        NSApplication.shared.run()
        fatalError("application run loop returned")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        navigationErrors.append(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationErrors.append(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessTerminated = true
        navigationErrors.append("web content process terminated")
    }

    private func sample() {
        guard let host else { return }
        attempts += 1
        let propertiesJSON = jsonString(host.scopedProperties)
        let source = """
        JSON.stringify({
            readyState: document.readyState,
            title: document.title || '',
            url: location.href,
            bodyTextLength: document.body ? document.body.innerText.length : 0,
            canvasCount: document.querySelectorAll('canvas').length,
            diagnostics: (function () {
                try {
                    return window.__frescoAuditSnapshot ? window.__frescoAuditSnapshot() : null;
                } catch (error) {
                    return { snapshotError: String(error && error.stack || error) };
                }
            })(),
            propertyActivity: (function (definitions) {
                const names = Object.keys(definitions).filter(function (name) {
                    return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name);
                });
                const values = names.map(function (name) { return definitions[name]; });
                const activity = {};
                for (const name of Object.keys(definitions)) {
                    const definition = definitions[name] || {};
                    const type = String(definition.type || '').toLowerCase();
                    if (type !== 'file' && type !== 'directory') continue;
                    if (!definition.condition) {
                        activity[name] = true;
                        continue;
                    }
                    try {
                        activity[name] = new Function(...names,
                            'return !!(' + definition.condition + ');')(...values);
                    } catch (_) {
                        activity[name] = null;
                    }
                }
                return activity;
            })(\(propertiesJSON)),
            resourceFailures: window.__weResourceFailures || [],
            brokenImages: Array.from(document.images).filter(function (image) {
                return image.src && image.src !== 'file:///' && image.complete &&
                    image.naturalWidth === 0;
            }).map(function (image) { return image.currentSrc || image.src; }),
            brokenVideos: Array.from(document.querySelectorAll('video')).filter(function (video) {
                return (video.currentSrc || video.src) && video.error;
            }).map(function (video) { return video.currentSrc || video.src; }),
            fixtureCleanupScheduled: (function () {
                if (typeof window.__frescoAuditFixtureCleanup !== 'function') return false;
                setTimeout(window.__frescoAuditFixtureCleanup, 0);
                return true;
            })()
        })
        """
        host.webView.evaluateJavaScript(source) { [weak self, weak host] value, error in
            guard let self, let host else { return }
            var pageState: [String: Any] = [:]
            if let json = value as? String, let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                pageState = object
            }
            if let error { pageState["evaluationError"] = error.localizedDescription }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = host.webView.bounds
            host.webView.takeSnapshot(with: configuration) { [weak self] image, snapshotError in
                guard let self else { return }
                var metrics: [String: Any]?
                if let image {
                    metrics = auditRenderMetrics(image)
                    self.writeSnapshot(image)
                }
                let nonBlank = metrics?["nonBlank"] as? Bool == true
                let ready = pageState["readyState"] as? String == "complete"
                if (!nonBlank || !ready) && self.attempts < 3
                    && !self.contentProcessTerminated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.sample()
                    }
                    return
                }
                self.finish(
                    pageState: pageState, metrics: metrics,
                    snapshotError: snapshotError?.localizedDescription)
            }
        }
    }

    private func finish(pageState: [String: Any], metrics: [String: Any]?,
                        snapshotError: String?) -> Never {
        audioTimer?.invalidate()
        timeoutTimer?.invalidate()
        let resourceFailures = pageState["resourceFailures"] as? [[String: Any]] ?? []
        let isSentinelURL: (String) -> Bool = { rawURL in
            let component = URL(string: rawURL)?.lastPathComponent.lowercased() ?? ""
            return component == "null" || component == "undefined" || component == "destroy"
        }
        let requiredLocalResourceFailures = resourceFailures.filter {
            let rawURL = $0["url"] as? String ?? ""
            guard rawURL.hasPrefix("file:"), !isSentinelURL(rawURL) else { return false }
            let tag = $0["tag"] as? String ?? ""
            if ["img", "script", "video", "iframe", "object", "embed"].contains(tag) {
                return true
            }
            if tag == "source" { return $0["parentTag"] as? String == "video" }
            if tag == "link" {
                return ($0["rel"] as? String ?? "").split(separator: " ")
                    .contains("stylesheet")
            }
            return false
        }
        let brokenImages = pageState["brokenImages"] as? [String] ?? []
        let brokenVideos = pageState["brokenVideos"] as? [String] ?? []
        let propertyActivity = pageState["propertyActivity"] as? [String: Any] ?? [:]
        let assets = host.map {
            auditAssetRecords(
                properties: $0.scopedProperties, root: $0.scopedRoot,
                activity: propertyActivity)
        } ?? []
        var failureReasons: [String] = []
        if (metrics?["opaqueFraction"] as? Double ?? 0) <= 0.01 {
            failureReasons.append("transparent render")
        }
        if pageState["readyState"] as? String != "complete" {
            failureReasons.append("document did not finish loading")
        }
        if !requiredLocalResourceFailures.isEmpty {
            failureReasons.append("required local resource failure")
        }
        if brokenImages.contains(where: { $0.hasPrefix("file:") && !isSentinelURL($0) }) {
            failureReasons.append("broken local image")
        }
        if brokenVideos.contains(where: { $0.hasPrefix("file:") && !isSentinelURL($0) }) {
            failureReasons.append("broken local video")
        }
        if assets.contains(where: {
            $0["exists"] as? Bool != true && $0["active"] as? Bool != false
        }) {
            failureReasons.append("selected property asset missing")
        }
        if contentProcessTerminated { failureReasons.append("web content process terminated") }
        if snapshotError != nil || metrics == nil { failureReasons.append("snapshot unavailable") }
        if !navigationErrors.isEmpty { failureReasons.append("navigation failure") }

        var warnings: [String] = []
        if !pageLogs.isEmpty || !resourceFailures.isEmpty
            || !brokenImages.isEmpty || !brokenVideos.isEmpty {
            warnings.append("page diagnostics")
        }
        if metrics?["nonBlank"] as? Bool != true {
            warnings.append("uniform render")
        }
        if assets.contains(where: {
            $0["exists"] as? Bool != true && $0["active"] as? Bool == false
        }) {
            warnings.append("inactive property asset missing")
        }
        let verdict = failureReasons.isEmpty ? (warnings.isEmpty ? "pass" : "warning") : "fail"
        var report: [String: Any] = [
            "schemaVersion": 1,
            "wallpaperPath": wallpaperPath,
            "snapshotPath": snapshotURL.path,
            "verdict": verdict,
            "failureReasons": Array(Set(failureReasons)).sorted(),
            "warnings": warnings,
            "attempts": attempts,
            "durationMilliseconds": Int(Date().timeIntervalSince(started) * 1000),
            "page": pageState,
            "pageLogs": pageLogs,
            "navigationErrors": navigationErrors,
            "contentProcessTerminated": contentProcessTerminated,
            "assets": assets,
        ]
        if let metrics { report["render"] = metrics }
        if let snapshotError { report["snapshotError"] = snapshotError }
        writeReport(report)
        host?.invalidate()
        auditWindow?.orderOut(nil)
        print("web audit \(verdict): \(reportURL.path)")
        exit(verdict == "fail" ? 1 : 0)
    }

    private func writeSnapshot(_ image: NSImage) {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: snapshotURL, options: .atomic)
    }

    private func writeReport(_ report: [String: Any]) {
        try? FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: reportURL, options: .atomic)
    }

    private func writeEarlyFailure(_ reason: String) -> Never {
        writeReport([
            "schemaVersion": 1,
            "wallpaperPath": wallpaperPath,
            "snapshotPath": snapshotURL.path,
            "verdict": "fail",
            "failureReasons": [reason],
        ])
        fputs("web audit failed: \(reason)\n", stderr)
        exit(1)
    }
}

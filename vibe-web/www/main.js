import init, { VibeApp } from './pkg/vibe_web.js';

const FALLBACK_SHADERS = [
    'abyssal_choir',
    'aurora',
    'cathedral_of_noise',
    'cluster',
    'cymatics',
    'deep_sea',
    'default',
    'driving_arctic',
    'driving_city',
    'driving_game',
    'driving_sunset',
    'dream_engine',
    'event_horizon',
    'ferrofluid_oracle',
    'evil_mandelbulb',
    'grass',
    'infinite_reliquary',
    'kintsugi_planet',
    'lantern_tide',
    'liquid',
    'mandelbrot_light',
    'monolith',
    'nebula',
    'neural_bloom',
    'osint_hud',
    'paper_moon',
    'plasma',
    'pokemon_grass',
    'pokemon_grass_3d',
    'prismatic_loom',
    'singularity',
    'solar_system',
    'solar_system_vivid',
    'starfield',
    'stormveil',
    'tesseract',
    'vortex',
    'waveform',
];
let SHADERS = FALLBACK_SHADERS;

function showError(msg) {
    let el = document.getElementById('error-overlay');
    if (!el) {
        el = document.createElement('div');
        el.id = 'error-overlay';
        el.style.cssText = 'position:fixed;top:10px;left:10px;right:10px;background:rgba(200,0,0,0.92);color:#fff;padding:14px 16px;font:13px monospace;z-index:9999;white-space:pre-wrap;border-radius:8px;max-height:50vh;overflow:auto;';
        document.body.appendChild(el);
    }
    el.textContent += msg + '\n';
    console.error('[vibe]', msg);
}

// ── Audio routing ──
// One AudioContext is created lazily on first user gesture. All sources route
// through the same `analyser` so the visualizer doesn't need to care where the
// signal came from. File and tab modes ALSO connect to ctx.destination so the
// user hears the audio; mic mode does not (to avoid feedback loops).

class AudioRouter {
    constructor() {
        this.ctx = null;
        this.analyser = null;
        this.freqData = null;
        this.currentSource = null; // MediaStream/MediaElement source node
        this.currentStream = null; // Active MediaStream (for stop())
        this.mode = null;          // 'mic' | 'file' | 'tab'
        this.onModeChange = () => {};
    }

    async _ensureCtx() {
        if (this.ctx) return;
        this.ctx = new AudioContext();
        this.analyser = this.ctx.createAnalyser();
        // fftSize=1024 → 512 freq bins; we forward the first 256 to the shader,
        // matching native vibe's bar count.
        this.analyser.fftSize = 1024;
        this.analyser.smoothingTimeConstant = 0.6;
        this.freqData = new Float32Array(this.analyser.frequencyBinCount);
    }

    async _stop() {
        if (this.currentSource) {
            try { this.currentSource.disconnect(); } catch {}
            this.currentSource = null;
        }
        if (this.currentStream) {
            for (const t of this.currentStream.getTracks()) t.stop();
            this.currentStream = null;
        }
    }

    async useMic(deviceId) {
        await this._ensureCtx();
        await this._stop();
        const constraints = {
            audio: {
                echoCancellation: false,
                noiseSuppression: false,
                autoGainControl: false,
                ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
            },
        };
        const stream = await navigator.mediaDevices.getUserMedia(constraints);
        const src = this.ctx.createMediaStreamSource(stream);
        src.connect(this.analyser);
        this.currentSource = src;
        this.currentStream = stream;
        this.mode = 'mic';
        this.onModeChange();
    }

    async useFile(file) {
        await this._ensureCtx();
        await this._stop();
        const audioEl = document.getElementById('audio-el');
        audioEl.src = URL.createObjectURL(file);
        audioEl.style.display = 'block';
        // createMediaElementSource is one-shot per element, so cache on the el.
        if (!audioEl._mediaSource) {
            audioEl._mediaSource = this.ctx.createMediaElementSource(audioEl);
        }
        audioEl._mediaSource.connect(this.analyser);
        // Also route to speakers so the user hears it.
        audioEl._mediaSource.connect(this.ctx.destination);
        this.currentSource = audioEl._mediaSource;
        this.mode = 'file';
        audioEl.play().catch(e => showError(`Could not autoplay: ${e.message}`));
        this.onModeChange();
    }

    async useTabAudio() {
        await this._ensureCtx();
        await this._stop();
        // Chrome's getDisplayMedia requires video: true even when we only want audio.
        // The user picks a tab/window and ticks "Share audio" in the picker.
        const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
        const audioTracks = stream.getAudioTracks();
        if (audioTracks.length === 0) {
            for (const t of stream.getTracks()) t.stop();
            throw new Error("No audio in the shared stream. Tick 'Share audio' in the picker.");
        }
        // Drop the video track (we don't need it).
        for (const t of stream.getVideoTracks()) t.stop();
        const audioOnly = new MediaStream(audioTracks);
        const src = this.ctx.createMediaStreamSource(audioOnly);
        src.connect(this.analyser);
        // Route to destination too so audio passes through (otherwise the tab is muted to you).
        src.connect(this.ctx.destination);
        this.currentSource = src;
        this.currentStream = audioOnly;
        this.mode = 'tab';
        this.onModeChange();
    }

    getLinearFrequencies() {
        if (!this.analyser) return null;
        this.analyser.getFloatFrequencyData(this.freqData);
        // dBFS [-100..0] → linear [0..1]
        const out = new Float32Array(this.freqData.length);
        for (let i = 0; i < this.freqData.length; i++) {
            out[i] = Math.max(0, (this.freqData[i] + 100) / 100);
        }
        return out;
    }
}

// ── BPM detection (spectral-flux peak-picking + autocorrelation) ──
//
// Algorithm (lightweight, runs on every ~16ms tick):
//   1. Spectral flux: sum of positive bin-to-bin energy increases between
//      this frame's bass-range (0-200 Hz roughly) and the previous frame's.
//   2. Maintain a rolling 4-second window of flux samples (~240 at 60fps).
//   3. Find peaks above a moving average × threshold.
//   4. Compute median inter-peak interval, convert to BPM.
//   5. Clamp to [60, 200] and smooth with EMA.
class BpmDetector {
    constructor() {
        this.prevBass = null;
        this.flux = [];        // rolling window of {t, v}
        this.peaks = [];       // timestamps of detected peaks
        this.windowSec = 4.0;
        this.bpm = 0;
        this.smoothed = 0;
    }

    update(linearFreqs, nowSec) {
        if (!linearFreqs || linearFreqs.length === 0) return this.smoothed;

        // Take the lower ~1/16 of bins as the "bass" region for beat detection.
        // For fftSize=1024 @ 48kHz that's roughly 0..1500 Hz.
        const bassBins = Math.max(8, Math.floor(linearFreqs.length / 16));
        const bass = new Float32Array(bassBins);
        for (let i = 0; i < bassBins; i++) bass[i] = linearFreqs[i];

        let flux = 0;
        if (this.prevBass) {
            for (let i = 0; i < bassBins; i++) {
                const d = bass[i] - this.prevBass[i];
                if (d > 0) flux += d;
            }
        }
        this.prevBass = bass;

        this.flux.push({ t: nowSec, v: flux });
        // Drop entries older than windowSec.
        while (this.flux.length > 0 && nowSec - this.flux[0].t > this.windowSec) {
            this.flux.shift();
        }

        if (this.flux.length < 30) return this.smoothed;

        // Threshold = mean × 1.8 over the window.
        let sum = 0;
        for (const s of this.flux) sum += s.v;
        const mean = sum / this.flux.length;
        const threshold = mean * 1.8;

        // Peak detection: local maxima above threshold with min gap 200 ms (=300 BPM cap).
        const minGapSec = 0.20;
        this.peaks = [];
        for (let i = 1; i < this.flux.length - 1; i++) {
            const cur = this.flux[i];
            if (cur.v < threshold) continue;
            const prev = this.flux[i - 1].v;
            const next = this.flux[i + 1].v;
            if (cur.v > prev && cur.v >= next) {
                const lastPeak = this.peaks[this.peaks.length - 1];
                if (!lastPeak || cur.t - lastPeak >= minGapSec) {
                    this.peaks.push(cur.t);
                }
            }
        }

        if (this.peaks.length < 4) return this.smoothed;

        const intervals = [];
        for (let i = 1; i < this.peaks.length; i++) {
            intervals.push(this.peaks[i] - this.peaks[i - 1]);
        }
        intervals.sort((a, b) => a - b);
        const median = intervals[Math.floor(intervals.length / 2)];
        let bpm = 60 / median;

        // Wrap doubled/halved estimates into a sensible musical range.
        while (bpm > 200) bpm /= 2;
        while (bpm < 60) bpm *= 2;
        if (bpm < 60 || bpm > 200) return this.smoothed;

        this.bpm = bpm;
        // EMA smoothing toward target.
        const alpha = 0.15;
        if (this.smoothed === 0) this.smoothed = bpm;
        else this.smoothed = this.smoothed * (1 - alpha) + bpm * alpha;
        return this.smoothed;
    }
}

async function loadShader(app, name) {
    try {
        const resp = await fetch(`shaders/${name}.wgsl`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status} for ${name}.wgsl`);
        const code = await resp.text();
        app.set_shader(code);
        history.replaceState(null, '', `#${name}`);
    } catch (e) {
        showError(`Shader '${name}' failed to load: ${e.message || e}`);
    }
}

async function discoverShaders() {
    try {
        const resp = await fetch('shaders/');
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const html = await resp.text();
        const doc = new DOMParser().parseFromString(html, 'text/html');
        const names = [...doc.querySelectorAll('a')]
            .map(a => {
                try {
                    const url = new URL(a.getAttribute('href'), location.href);
                    return decodeURIComponent(url.pathname.split('/').pop() || '');
                } catch {
                    return '';
                }
            })
            .filter(name => name.endsWith('.wgsl'))
            .map(name => name.replace(/\.wgsl$/, ''))
            .filter((name, idx, all) => name && all.indexOf(name) === idx)
            .sort((a, b) => a.localeCompare(b));
        if (names.length > 0) return names;
    } catch (e) {
        console.warn('[vibe] shader autodiscovery failed, using fallback list:', e.message);
    }
    return FALLBACK_SHADERS;
}

function populatePicker(initial) {
    const sel = document.getElementById('shader-picker');
    const names = SHADERS.includes(initial) ? SHADERS : [initial, ...SHADERS];
    for (const name of names) {
        const opt = document.createElement('option');
        opt.value = name; opt.textContent = name;
        if (name === initial) opt.selected = true;
        sel.appendChild(opt);
    }
    return sel;
}

function pickInitialShader() {
    const hash = (location.hash || '').replace(/^#/, '');
    if (hash) return hash;
    return SHADERS[0];
}

async function refreshDeviceList() {
    const sel = document.getElementById('device-picker');
    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const inputs = devices.filter(d => d.kind === 'audioinput');
        sel.innerHTML = '<option value="">Default</option>';
        for (const d of inputs) {
            const opt = document.createElement('option');
            opt.value = d.deviceId;
            opt.textContent = d.label || `Audio input ${d.deviceId.slice(0, 8)}`;
            sel.appendChild(opt);
        }
    } catch (e) {
        console.warn('[vibe] enumerateDevices failed:', e.message);
    }
}

async function main() {
    if (!navigator.gpu) {
        document.getElementById('no-webgpu').style.display = 'flex';
        return;
    }

    await init();

    const canvas = document.getElementById('vibe-canvas');
    const dpr = devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.floor(window.innerWidth * dpr));
    canvas.height = Math.max(1, Math.floor(window.innerHeight * dpr));

    const app = await VibeApp.create('vibe-canvas');
    app.resize(canvas.width, canvas.height);

    SHADERS = await discoverShaders();
    const initial = pickInitialShader();
    await loadShader(app, initial);

    const picker = populatePicker(initial);
    picker.addEventListener('change', e => loadShader(app, e.target.value));

    const sens = document.getElementById('sensitivity');
    sens.addEventListener('input', e => app.set_sensitivity(parseFloat(e.target.value)));
    app.set_sensitivity(parseFloat(sens.value));

    const audio = new AudioRouter();
    const bpmDetector = new BpmDetector();
    const sourceLabel = document.getElementById('audio-source');
    const bpmLabel = document.getElementById('bpm-num');
    audio.onModeChange = () => {
        sourceLabel.textContent = audio.mode || 'no audio';
    };

    document.getElementById('src-mic-btn').addEventListener('click', async () => {
        try {
            const deviceId = document.getElementById('device-picker').value || undefined;
            await audio.useMic(deviceId);
            // Labels are only populated after first getUserMedia grant.
            refreshDeviceList();
        } catch (e) {
            showError(`Mic failed: ${e.message}`);
        }
    });

    document.getElementById('src-file-btn').addEventListener('click', () => {
        document.getElementById('file-input').click();
    });
    document.getElementById('file-input').addEventListener('change', async e => {
        const f = e.target.files?.[0];
        if (!f) return;
        try { await audio.useFile(f); } catch (err) { showError(`File audio failed: ${err.message}`); }
    });

    document.getElementById('src-tab-btn').addEventListener('click', async () => {
        try { await audio.useTabAudio(); } catch (e) { showError(`Tab audio failed: ${e.message}`); }
    });

    document.getElementById('device-picker').addEventListener('change', () => {
        // If mic is the current source, restart with the new device.
        if (audio.mode === 'mic') {
            audio.useMic(document.getElementById('device-picker').value || undefined)
                .catch(e => showError(`Device switch failed: ${e.message}`));
        }
    });

    refreshDeviceList();
    navigator.mediaDevices?.addEventListener?.('devicechange', refreshDeviceList);

    window.addEventListener('resize', () => {
        const d = devicePixelRatio || 1;
        canvas.width = Math.max(1, Math.floor(window.innerWidth * d));
        canvas.height = Math.max(1, Math.floor(window.innerHeight * d));
        app.resize(canvas.width, canvas.height);
    });

    canvas.addEventListener('mousemove', e => {
        app.set_mouse(e.clientX / canvas.clientWidth, e.clientY / canvas.clientHeight);
    });
    canvas.addEventListener('click', e => {
        app.on_click(e.clientX / canvas.clientWidth, e.clientY / canvas.clientHeight);
    });

    window.addEventListener('hashchange', () => {
        const name = pickInitialShader();
        picker.value = name;
        loadShader(app, name);
    });

    // Keyboard shader cycling (matches the native Super+[ / Super+] flow):
    //   ArrowLeft  / [ — previous shader
    //   ArrowRight / ] — next shader
    //   r              — random shader
    //   f              — toggle fullscreen
    function cycleShader(delta) {
        const cur = picker.value;
        // If current shader is off-list (e.g. arrived via URL hash), pretend
        // we're one before the start so the first cycle step lands at index 0.
        let i = SHADERS.indexOf(cur);
        if (i === -1) i = delta > 0 ? -1 : 0;
        const next = SHADERS[(i + delta + SHADERS.length) % SHADERS.length];
        picker.value = next;
        loadShader(app, next);
    }
    window.addEventListener('keydown', e => {
        if (e.target?.tagName === 'INPUT' || e.target?.tagName === 'SELECT' || e.target?.tagName === 'TEXTAREA') return;
        switch (e.key) {
            case 'ArrowRight':
            case ']':
                e.preventDefault(); cycleShader(+1); break;
            case 'ArrowLeft':
            case '[':
                e.preventDefault(); cycleShader(-1); break;
            case 'r':
            case 'R': {
                e.preventDefault();
                const r = SHADERS[Math.floor(Math.random() * SHADERS.length)];
                picker.value = r; loadShader(app, r);
                break;
            }
            case 'f':
            case 'F':
                e.preventDefault();
                if (document.fullscreenElement) document.exitFullscreen();
                else document.documentElement.requestFullscreen();
                break;
        }
    });

    window.vibe = { app, loadShader, audio, bpmDetector, cycleShader };

    let frameCount = 0;
    let renderErrorCount = 0;
    let lastBpmWrite = 0;
    function frame(now) {
        try {
            const freqs = audio.getLinearFrequencies();
            if (freqs) {
                app.set_frequencies(freqs);
                const bpm = bpmDetector.update(freqs, now / 1000);
                // Only push BPM uniform every ~250ms to avoid GPU queue spam.
                if (now - lastBpmWrite > 250) {
                    app.set_bpm(bpm);
                    bpmLabel.textContent = bpm > 0 ? bpm.toFixed(1) : '--';
                    lastBpmWrite = now;
                }
            }
            app.render();
            frameCount++;
        } catch (e) {
            renderErrorCount++;
            if (renderErrorCount < 5) showError(`Render error frame ${frameCount}: ${e}`);
        }
        requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
}

main().catch(e => showError(`Fatal: ${e}`));

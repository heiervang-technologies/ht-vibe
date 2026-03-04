import init, { VibeApp } from './pkg/vibe_web.js';

function showError(msg) {
    let el = document.getElementById('error-overlay');
    if (!el) {
        el = document.createElement('div');
        el.id = 'error-overlay';
        el.style.cssText = 'position:fixed;top:10px;left:10px;right:10px;background:rgba(200,0,0,0.9);color:#fff;padding:16px;font:14px monospace;z-index:9999;white-space:pre-wrap;border-radius:8px;max-height:50vh;overflow:auto;';
        document.body.appendChild(el);
    }
    el.textContent += msg + '\n';
    console.error('[vibe]', msg);
}

function showStatus(msg) {
    let el = document.getElementById('status-overlay');
    if (!el) {
        el = document.createElement('div');
        el.id = 'status-overlay';
        el.style.cssText = 'position:fixed;bottom:10px;left:10px;background:rgba(0,0,0,0.7);color:#0f0;padding:8px 12px;font:12px monospace;z-index:9999;border-radius:4px;';
        document.body.appendChild(el);
    }
    el.textContent = msg;
    console.log('[vibe]', msg);
}

// ── Audio capture via Web Audio API ──

let audioCtx = null;
let analyser = null;
let freqData = null;

async function initAudio() {
    try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        audioCtx = new AudioContext();
        const source = audioCtx.createMediaStreamSource(stream);
        analyser = audioCtx.createAnalyser();
        analyser.fftSize = 512;
        analyser.smoothingTimeConstant = 0.7;
        source.connect(analyser);
        freqData = new Float32Array(analyser.frequencyBinCount);
        showStatus('Audio capture active');
        return true;
    } catch (e) {
        console.warn('[vibe] Audio capture unavailable:', e.message);
        return false;
    }
}

function getFrequencies() {
    if (!analyser || !freqData) return null;
    analyser.getFloatFrequencyData(freqData);
    // Convert from dBFS (-100..0) to linear (0..1)
    const linear = new Float32Array(freqData.length);
    for (let i = 0; i < freqData.length; i++) {
        linear[i] = Math.max(0, (freqData[i] + 100) / 100);
    }
    return linear;
}

// ── Main ──

async function main() {
    showStatus('Starting...');

    if (!navigator.gpu) {
        showError('WebGPU not supported in this browser');
        const el = document.getElementById('no-webgpu');
        if (el) el.style.display = 'flex';
        return;
    }
    showStatus('WebGPU available, initializing WASM...');

    await init();
    showStatus('WASM loaded, creating VibeApp...');

    const canvas = document.getElementById('vibe-canvas');
    canvas.width = window.innerWidth * devicePixelRatio;
    canvas.height = window.innerHeight * devicePixelRatio;

    const app = await new VibeApp('vibe-canvas');
    showStatus(`VibeApp created (${canvas.width}x${canvas.height}), rendering fallback...`);

    app.resize(canvas.width, canvas.height);

    // Verify pipeline with fallback shader
    for (let i = 0; i < 5; i++) {
        app.render();
    }
    showStatus('Fallback rendered OK, loading custom shader...');

    // Load and apply the custom shader
    const resp = await fetch('shaders/default.wgsl');
    const shaderCode = await resp.text();
    app.set_shader(shaderCode);
    showStatus(`Shader loaded (${shaderCode.length} chars), starting audio...`);

    // Start audio capture (non-blocking, works without mic permission too)
    const hasAudio = await initAudio();
    if (!hasAudio) {
        showStatus('Rendering without audio (click page to enable mic)');
        // Retry audio on user interaction
        document.addEventListener('click', async () => {
            if (!audioCtx) {
                const ok = await initAudio();
                if (ok) showStatus('Audio enabled!');
            }
        }, { once: true });
    }

    // Input handlers
    window.addEventListener('resize', () => {
        canvas.width = window.innerWidth * devicePixelRatio;
        canvas.height = window.innerHeight * devicePixelRatio;
        app.resize(canvas.width, canvas.height);
    });

    canvas.addEventListener('mousemove', (e) => {
        app.set_mouse(e.clientX / canvas.clientWidth, e.clientY / canvas.clientHeight);
    });
    canvas.addEventListener('click', (e) => {
        app.on_click(e.clientX / canvas.clientWidth, e.clientY / canvas.clientHeight);
    });

    // Render loop
    let frameCount = 0;
    function frame() {
        try {
            // Feed frequency data to GPU each frame
            const freqs = getFrequencies();
            if (freqs) {
                app.set_frequencies(freqs);
            }

            app.render();
            frameCount++;
            if (frameCount === 1) showStatus('First frame rendered');
            if (frameCount === 60) {
                const statusEl = document.getElementById('status-overlay');
                if (statusEl) statusEl.remove();
            }
        } catch (e) {
            showError(`Render error (frame ${frameCount}): ${e}`);
        }
        requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
}

main().catch(e => showError(`Fatal: ${e}`));

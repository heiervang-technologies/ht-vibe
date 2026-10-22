// ---------------------------------------------------------------------------
// CONDUCTOR — turns music into cortical organization.
//
// Owns every read of freqs / iTime / iBPM / iMouse*. Parts downstream receive
// everything through arguments, so this file is the single source of musical
// truth.
//
//   org.x  form phase, wraps mod 4: 0 tunnel, 1 spiral, 2 lattice, 3 cobweb lace
//   org.y  cortical wave speed (~0.05 .. 1.5)
//   org.z  defect density 0..1
//   org.w  excitability 0..1 (0 = Eigengrau rest, 1 = full form)
//
// The form sequence advances on phrase boundaries (16 beats) and morphs during
// the last bar of each phrase, so changes land where a listener expects them.
// The spectrum's brightness bends the morph locally: bright music leans toward
// the lattice/lace side of the cycle, dark music toward tunnel/spiral.
// Clicking the screen is pressing on the eyelid: a pressure phosphene that
// floods the field with defects and slowly fades.
// ---------------------------------------------------------------------------

const CD_BEATS_PER_PHRASE: f32 = 16.0;
const CD_FALLBACK_BPM: f32 = 96.0;

fn cd_band(lo: f32, hi: f32) -> f32 {
    let n = arrayLength(&freqs);
    if (n == 0u) {
        return 0.0;
    }
    let nf = f32(n);
    let a = u32(clamp(lo * nf, 0.0, nf - 1.0));
    let b = max(u32(clamp(hi * nf, 0.0, nf)), a + 1u);
    var s = 0.0;
    for (var i = a; i < b; i = i + 1u) {
        s = s + freqs[i];
    }
    return s / f32(b - a);
}

// Smoothed-looking bands in 0..1. Vibe already eases freqs between frames;
// the soft knee keeps loud masters from pinning everything at 1.
fn cd_bands() -> vec3f {
    let raw = vec3f(cd_band(0.0, 0.08), cd_band(0.08, 0.45), cd_band(0.45, 1.0));
    return clamp(raw / (raw + vec3f(0.35)) * 1.35, vec3f(0.0), vec3f(1.0));
}

fn cd_bpm() -> f32 {
    return select(CD_FALLBACK_BPM, clamp(iBPM, 50.0, 200.0), iBPM > 1.0);
}

// Beats elapsed since start (continuous).
fn cd_beats() -> f32 {
    return iTime * cd_bpm() / 60.0;
}

// Sharp-attack, slow-release pulse on every beat, 0..1.
fn cd_beat_pulse() -> f32 {
    let f = fract(cd_beats());
    return exp(-f * 6.0);
}

// Seconds since the last click, or a large number if there is none.
fn cd_since_click() -> f32 {
    if (iMouseClick.x < 0.0) {
        return 1e4;
    }
    return max(iTime - iMouseClick.z, 0.0);
}

// Pressure phosphene envelope: blooms over ~0.4 s, fades over ~6 s.
fn cd_pressure() -> f32 {
    let s = cd_since_click();
    return smoothstep(0.0, 0.4, s) * exp(-s / 2.5);
}

// Gaze offset in contract uv units: the field drifts a little toward the
// pointer, as if the eye were following it.
fn cd_gaze() -> vec2f {
    let m = clamp(iMouse, vec2f(0.0), vec2f(1.0)) - vec2f(0.5);
    let aspect = iResolution.x / max(iResolution.y, 1.0);
    return vec2f(m.x * aspect, -m.y) * 0.18;
}

fn cd_org(bands: vec3f) -> vec4f {
    let bass = bands.x;
    let mid = bands.y;
    let treble = bands.z;
    let level = dot(bands, vec3f(0.5, 0.3, 0.2));
    let press = cd_pressure();

    // Form phase: one form per phrase, morphing through the final bar.
    let phrase = cd_beats() / CD_BEATS_PER_PHRASE;
    let morph = smoothstep(0.75, 1.0, fract(phrase));
    var phase = floor(phrase) + morph;
    // Spectral brightness leans the cycle; the lean is bounded so the
    // phrase structure always wins.
    let centroid = (mid * 0.5 + treble) / max(bass + mid + treble, 1e-3);
    phase = phase + 0.32 * (centroid - 0.45) * smoothstep(0.03, 0.2, level);

    // Wave speed: mids drive lateral travel, each beat gives a small shove.
    let speed = 0.06 + 1.15 * pow(mid, 1.2) + 0.25 * bass * cd_beat_pulse();

    // Defects: treble births pinwheels; pressure floods the field with them.
    let defects = clamp(pow(treble, 0.8) * 0.85 + press * 0.9, 0.0, 1.0);

    // Excitability: silence relaxes into Eigengrau; a slow breath (~11 s)
    // keeps even steady music from becoming wall-to-wall pattern.
    let breath = 0.5 + 0.5 * sin(iTime * 0.57);
    let drive = smoothstep(0.02, 0.4, level) * mix(0.72, 1.0, breath);
    let excite = clamp(max(drive + 0.18 * bass * cd_beat_pulse(), press), 0.0, 1.0);

    return vec4f(phase - 4.0 * floor(phase / 4.0), speed, defects, excite);
}

@fragment
fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    // Contract uv: centered, aspect-correct, half-height = 1, +y up.
    let half_h = max(iResolution.y, 1.0) * 0.5;
    var uv = (pos.xy - iResolution.xy * 0.5) / half_h;
    uv.y = -uv.y;
    uv = uv - cd_gaze();

    let bands = cd_bands();
    let org = cd_org(bands);
    // perceive() returns linear light; vibe presents to a UNORM surface
    // (Bgra8Unorm/Rgba8Unorm), so the sRGB encode happens here, once.
    let lin = clamp(perceive(uv, iTime, org, bands), vec3f(0.0), vec3f(1.0));
    var col = select(1.055 * pow(lin, vec3f(1.0 / 2.4)) - 0.055, lin * 12.92, lin <= vec3f(0.0031308));

    // Triangular dither: the dark end of this piece lives in the bottom few
    // code values, where 8-bit banding would otherwise show.
    let h = fract(sin(dot(pos.xy, vec2f(12.9898, 78.233))) * 43758.5453);
    let h2 = fract(sin(dot(pos.xy, vec2f(39.3468, 11.135))) * 24634.6345);
    col = col + (h + h2 - 1.0) / 255.0;

    return vec4f(max(col, vec3f(0.0)), 1.0);
}

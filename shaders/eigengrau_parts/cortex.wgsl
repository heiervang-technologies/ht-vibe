// ════════════════════════════════════════════════════════════════════════════
// eigengrau_parts/cortex.wgsl — P1: CORTEX CORE (V1 Retinocortical Planforms)
// ════════════════════════════════════════════════════════════════════════════
//
// Mathematical model:
//   1. Inverse Retinocortical Conformal Map (Schwartz 1977):
//      Maps centered retinal coordinates uv -> (r, theta) onto the primary
//      visual cortex sheet x = (u, v) via regularized complex logarithm:
//        u = ln(sqrt(r^2 + r0^2) / r0),   v = theta
//      Because w = u + i*v = ln(z) is holomorphic (conformal), equilateral
//      waves in (u, v) map to angle-preserving structures at every retinal
//      eccentricity from fovea to periphery. All azimuthal wavevector modes
//      use exact integer harmonics m in Z with smooth foveal regularization
//      r^2 / (r^2 + r0^2), guaranteeing C^inf continuity at r = 0 and zero
//      seam at theta = +/-pi.
//
//   2. Bressloff-Cowan V1 Equivariant Planforms (Bressloff et al. 2001):
//      Evaluates coupled cortical standing/travelling waves across the four
//      Kluver form-constant symmetry classes on the 4-phase cycle (org.x mod 4):
//        0 : Tunnel / Funnel (continuous concentric rings + radial fluting)
//        1 : Logarithmic Spirals (continuous chiral vortex arms + parastichy)
//        2 : Hexagonal Lattice (conformal D6 honeycomb triad k1 + k2 + k3 = 0)
//        3 : Cobweb Filigree (radial spokes + scalloped catenary spiderweb lace)
//
//   3. Hypercolumn Orientation Complex Field & Branch-Cut-Free Dislocations:
//      A complex order parameter Z(u, v) = X + iY models V1 orientation
//      preference columns phi = 0.5 * arg(Z) in [0, pi) radians. Zeros where
//      |Z| -> 0 form topological pinwheel singularities (charge +/-1/2).
//      Phase dislocations are coupled into the planform waves via the smooth
//      normalized complex field (X, Y) / sqrt(|Z|^2 + eps^2) rather than
//      fractional atan2 angles, producing genuine forked wavefront dislocations
//      at pinwheel cores with C^inf smoothness and zero branch-cut seams.
//
// Public API:
//   fn cortex(uv: vec2f, t: f32, org: vec4f) -> vec4f
//     Inputs:
//       uv   : centered aspect-corrected visual field coords, half-height = 1
//       t    : cortical time in seconds (supports delayed t - dt for afterimages)
//       org  : conductor organization vector:
//              org.x = form phase (wraps mod 4: 0 tunnel, 1 spiral, 2 lattice, 3 cobweb)
//              org.y = cortical wave speed (~0.05 .. 1.5)
//              org.z = defect density (0 .. 1)
//              org.w = excitability (0 = Eigengrau rest, 1 = full form)
//     Outputs:
//       vec4f(activity, orientation, defect, edge):
//         .x activity    : V1 neural firing activity in [0, 1]
//         .y orientation : hypercolumn orientation angle in [0, pi) radians
//         .z defect      : topological pinwheel & phase-dislocation core intensity in [0, 1]
//         .w edge        : scale-invariant nodal/filament contour filigree strength in [0, 1]
// ════════════════════════════════════════════════════════════════════════════

const CX_PI: f32 = 3.141592653589793;
const CX_TAU: f32 = 6.283185307179586;

// ──── Cyclic 4-phase weights (wraps smoothly mod 4: 0->1->2->3->0) ────
fn cx_phase_weights(phase_in: f32) -> vec4f {
    let p = phase_in - 4.0 * floor(phase_in * 0.25);
    let d0 = min(abs(p - 0.0), 4.0 - abs(p - 0.0));
    let d1 = min(abs(p - 1.0), 4.0 - abs(p - 1.0));
    let d2 = min(abs(p - 2.0), 4.0 - abs(p - 2.0));
    let d3 = min(abs(p - 3.0), 4.0 - abs(p - 3.0));

    let w0 = max(0.0, 1.0 - d0 * 0.95);
    let w1 = max(0.0, 1.0 - d1 * 0.95);
    let w2 = max(0.0, 1.0 - d2 * 0.95);
    let w3 = max(0.0, 1.0 - d3 * 0.95);

    let s = vec4f(
        w0 * w0 * (3.0 - 2.0 * w0),
        w1 * w1 * (3.0 - 2.0 * w1),
        w2 * w2 * (3.0 - 2.0 * w2),
        w3 * w3 * (3.0 - 2.0 * w3)
    );
    return s / max(s.x + s.y + s.z + s.w, 1e-4);
}

// ──── Branch-cut-free complex wave dislocation helpers ────
// Couples a carrier phase `theta` with the complex pinwheel unit phasor `z_hat = (cx, sy)`
// by strength `k_disloc` in [0, 1] using single-valued trigonometric addition:
//   (1 - k) * cos(theta) + k * (cos(theta)*cx - sin(theta)*sy)
// This creates genuine topological fork dislocations around pinwheel zeros |Z| = 0
// with C^inf continuity and ZERO branch-cut discontinuities anywhere.
fn cx_disloc_cos(theta: f32, z_hat: vec2f, k_disloc: f32) -> f32 {
    let c = cos(theta);
    let s = sin(theta);
    return mix(c, c * z_hat.x - s * z_hat.y, k_disloc);
}

fn cx_disloc_sin(theta: f32, z_hat: vec2f, k_disloc: f32) -> f32 {
    let c = cos(theta);
    let s = sin(theta);
    return mix(s, s * z_hat.x + c * z_hat.y, k_disloc);
}

// // ──── Hypercolumn Orientation Order Parameter Z(u, v) = X + iY ────
// Synthesizes the complex V1 orientation column map on the cortical cylinder.
// Uses low-order integer azimuthal winding numbers m in Z so topological zeros
// Z(u, v) = 0 form a sparse constellation of distinct, localized pinwheel
// singularities rather than global noise, with zero seam at theta = +/-pi.
// Returns vec4f(X, Y, grad_mag, jacobian).
fn cx_hypercolumn_field(u: f32, v: f32, flow: f32, defect_drive: f32, az_env: f32) -> vec4f {
    let ku = 2.0 + defect_drive * 0.9;
    let drift = flow * (0.16 + defect_drive * 0.10);

    // Four low-order cylindrical modes (integer m = 1, 2, -2, 3) for sparse, clean pinwheels
    let p1 =  ku * 0.92 * u + 1.0 * v - drift * 0.75 + 0.40;
    let p2 = -ku * 0.85 * u + 2.0 * v + drift * 0.60 + 1.95;
    let p3 =  ku * 1.08 * u - 2.0 * v + drift * 0.45 + 3.10;
    let p4 = -ku * 0.76 * u + 3.0 * v - drift * 0.80 + 4.55;

    let higher = (0.30 + 0.70 * defect_drive) * az_env;

    // Complex order parameter Z = X + iY
    let x_raw = cos(p1) * 0.44 + cos(p2) * 0.38 * az_env
              + cos(p3) * 0.32 * higher + cos(p4) * 0.24 * higher;
    let y_raw = sin(p1) * 0.44 + sin(p2) * 0.38 * az_env
              - sin(p3) * 0.32 * higher + sin(p4) * 0.24 * higher;

    // Analytic local cortical gradient for scale-invariant pinwheel core localization
    let dx_du = -ku * (0.92 * sin(p1) * 0.44 - 0.85 * sin(p2) * 0.38 + 1.08 * sin(p3) * 0.32);
    let dy_du =  ku * (0.92 * cos(p1) * 0.44 - 0.85 * cos(p2) * 0.38 - 1.08 * cos(p3) * 0.32);
    let dx_dv = -1.0 * sin(p1) * 0.44 - 2.0 * sin(p2) * 0.38 + 2.0 * sin(p3) * 0.32;
    let dy_dv =  1.0 * cos(p1) * 0.44 + 2.0 * cos(p2) * 0.38 + 2.0 * cos(p3) * 0.32;

    let grad_mag = sqrt(max(dx_du * dx_du + dy_du * dy_du + dx_dv * dx_dv + dy_dv * dy_dv, 0.08));
    // Topological Jacobian J = dX/du * dY/dv - dX/dv * dY/du (signed pinwheel charge density)
    let jacobian = (dx_du * dy_dv - dx_dv * dy_du) / (grad_mag * grad_mag + 0.15);

    return vec4f(x_raw, y_raw, grad_mag, jacobian);
}

// ──── Bressloff-Cowan V1 Planform Evaluator ────
// Evaluates the 4 Kluver form-constant families on cortical coordinates (u, v).
// Dislocations are gated by `local_disloc`, which is non-zero ONLY in the immediate
// neighborhood of topological pinwheel cores |Z| -> 0, so patterns remain razor-crisp
// globally while visibly breaking/rejoining at localized pinwheel defects.
// Returns vec2f(activity_field, filigree_field).
fn cx_eval_planforms(
    u: f32,
    v: f32,
    flow: f32,
    weights: vec4f,
    local_disloc: f32,
    z_hat: vec2f,
    az_env: f32
) -> vec2f {
    // ── Form 0: TUNNEL / FUNNEL (Crisp Rings x Spokes Polar Checkerboard Funnel) ──
    // Concentric depth rings crossed by 16 radial funnel spokes (m = 8 pairs).
    // Saturating the ring and spoke cosines with `inverseSqrt(w^2 + 0.14)` squares off
    // the polar tiles so contours trace crisp concentric tunnel hoops and straight
    // radial spokes rather than rounded ovals, closing into bullseye rings at the fovea.
    let q_tun = 11.0;
    let u_tun = q_tun * u - flow * 2.1;
    let ring_wave  = cx_disloc_cos(u_tun, z_hat, local_disloc);
    let spoke_wave = cos(8.0 * v);
    let rw = ring_wave * inverseSqrt(ring_wave * ring_wave + 0.12);
    let sw = spoke_wave * inverseSqrt(spoke_wave * spoke_wave + 0.12);
    let checker = rw * sw;
    let tunnel_act  = mix(rw * 0.85, 0.72 * checker + 0.30 * rw, az_env) + 0.12;
    let tunnel_lace = clamp(
        max(exp(-abs(ring_wave) * 5.2) * 0.90, exp(-abs(spoke_wave) * 5.5) * 0.85 * az_env),
        0.0,
        1.0
    );

    // ── Form 1: LOGARITHMIC SPIRALS (10 Regular Constant-Pitch Log-Spiral Arms) ──
    // Exact constant-pitch logarithmic spiral w = cos(q_sp * u + 10 * v - flow).
    // Using the phase-locked Chebyshev harmonic (2*w_main^2 - 1) keeps all 10 spiral
    // arms razor-clean through local pinwheel Y-forks with zero detached bubbles.
    let q_sp = 10.5;
    let sp_main  = q_sp * u + 10.0 * v - flow * 2.2;
    let w_main   = cx_disloc_cos(sp_main, z_hat, local_disloc);
    let w_sin    = cx_disloc_sin(sp_main, z_hat, local_disloc);
    let w_harm   = 2.0 * w_main * w_main - 1.0;
    let spiral_act  = (0.88 * w_main + 0.14 * w_harm) * mix(0.68, 1.0, az_env);
    let spiral_lace = clamp(exp(-abs(w_sin) * 5.2) * 0.92, 0.0, 1.0);

    // ── Form 2: HEXAGONAL LATTICE (Conformal D6 Honeycomb Triad k1 + k2 + k3 = 0) ──
    // Hexagonal symmetry requires the phason sum h1 + h2 + h3 = 0 identically.
    // Localized dislocations enter via smooth cortical strain (u_hex, v_hex) so
    // phase closure holds everywhere while rows shift across local pinwheels.
    let q_hex = 11.547005;
    let u_hex = u + 0.14 * (z_hat.x * cos(4.0 * v) + z_hat.y * sin(4.0 * v)) * local_disloc;
    let v_hex = v + 0.10 * (z_hat.y * cos(q_hex * 0.5 * u) - z_hat.x * sin(q_hex * 0.5 * u)) * local_disloc;
    let h1 =  q_hex * u_hex - flow * 1.50;
    let h2 = -0.5 * q_hex * u_hex + 10.0 * v_hex + 0.75 * flow * 1.50;
    let h3 = -0.5 * q_hex * u_hex - 10.0 * v_hex + 0.75 * flow * 1.50;
    let hex_sum = (cos(h1) + (cos(h2) + cos(h3)) * az_env) / (1.0 + 2.0 * az_env);
    let hex_cell = smoothstep(0.08, 0.52, hex_sum);
    let hex_wall = exp(-abs(hex_sum + 0.24) * 9.0) * az_env;
    let lattice_lace = clamp(exp(-abs(hex_sum - 0.22) * 8.0) * 0.90 + hex_wall * 0.85, 0.0, 1.0);
    let lattice_act  = max(hex_cell, hex_wall * 0.88) * 1.48 - 0.52;

    // ── Form 3: COBWEB FILIGREE (Radial Spokes + Scalloped Catenary Spiderweb Lace) ──
    // 12 radial spoke threads + concentric rings that festoon/sag inward between spokes.
    let q_cob = 11.5;
    let spoke_c12 = cos(12.0 * v);
    let spoke_c24 = cos(24.0 * v);
    let u_catenary = q_cob * u + 0.46 * spoke_c12 * az_env - flow * 1.6;
    let ring_cat   = cx_disloc_cos(u_catenary, z_hat, local_disloc);
    let rib_thread  = pow(max(0.0, spoke_c12), 7.0) * az_env;
    let cat_thread  = exp(-abs(ring_cat) * 5.0);
    let diag_arch   = exp(-abs(cos(0.5 * q_cob * u + 6.0 * v - flow * 0.8) * cos(0.5 * q_cob * u - 6.0 * v - flow * 0.8)) * 6.5) * az_env;
    let cobweb_lace = clamp(max(rib_thread * 0.92, cat_thread * 0.88) + diag_arch * 0.38 + pow(max(0.0, spoke_c24), 10.0) * 0.25 * az_env, 0.0, 1.0);
    let cobweb_act  = cobweb_lace * 1.55 - 0.60;

    let psi = weights.x * tunnel_act
            + weights.y * spiral_act
            + weights.z * lattice_act
            + weights.w * cobweb_act;

    let lace = weights.x * tunnel_lace
             + weights.y * spiral_lace
             + weights.z * lattice_lace
             + weights.w * cobweb_lace;

    return vec2f(psi, lace);
}

// ──── Primary Public Entrypoint ────
fn cortex(uv: vec2f, t: f32, org: vec4f) -> vec4f {
    // 1. Unpack conductor organization vector:
    //    org.x = form phase (mod 4: 0 tunnel, 1 spiral, 2 lattice, 3 cobweb)
    //    org.y = cortical wave speed (~0.05 .. 1.5)
    //    org.z = defect density (0 .. 1)
    //    org.w = excitability (0 .. 1)
    let form_phase   = org.x;
    let wave_speed   = clamp(org.y, 0.02, 2.5);
    let defect_drive = clamp(org.z, 0.0, 1.0);
    let excite       = clamp(org.w, 0.0, 1.0);

    // Effective cortical phase clock driven by wave_speed
    let flow = t * (0.36 + wave_speed * 0.80);

    // 2. Gentle cortical precession so the field rotates organically
    let precess = t * 0.030 + 0.10 * sin(t * 0.08);
    let cp = cos(precess);
    let sp = sin(precess);
    let p = vec2f(cp * uv.x - sp * uv.y, sp * uv.x + cp * uv.y);

    // 3. Inverse Retinocortical Log-Polar Map: p -> (r, theta) -> cortical (u, v)
    let r2 = dot(p, p);
    let r  = sqrt(r2);
    let v  = atan2(p.y, p.x);

    // Regularized foveal radius r0 prevents log(0) singularity at fixation center
    let r0 = 0.038;
    let u_base = log(sqrt(r2 + r0 * r0) / r0);

    // Smooth foveal envelope for m != 0 azimuthal modes so r -> 0 is C^inf pinch-free
    let az_env = r2 / (r2 + r0 * r0 * 1.8);

    // 4. V1 Orientation Hypercolumn Complex Field Z(u, v) = X + iY & Pinwheel Singularities
    let hc = cx_hypercolumn_field(u_base, v, flow, defect_drive, az_env);
    let z_xy   = hc.xy;
    let z_mag2 = dot(z_xy, z_xy);
    let z_grad = hc.z;
    let z_jac  = hc.w;

    // Smooth normalized complex phasor z_hat = (X, Y) / sqrt(|Z|^2 + eps^2)
    // Vanishes smoothly right at pinwheel singularity cores |Z| = 0, unit length elsewhere.
    let z_hat = z_xy * inverseSqrt(z_mag2 + 0.008);

    // Orientation preference angle in [0, pi) radians (unoriented axis).
    // Doubling orientation in perception.wgsl (2.0 * orientation = atan2(Y, X) + PI)
    // is 2*pi-periodic and has ZERO color seam across the +/-pi branch cut!
    let z_arg = atan2(z_xy.y, z_xy.x);
    let orientation = z_arg * 0.5 + CX_PI * 0.5;

    // Strictly Localized Pinwheel Defect Cores & Dislocation Envelope:
    // `norm_mag2` is normalized so it is < 1 ONLY within the tight core radius of a
    // true topological zero Z(u, v) = 0, and >> 5 everywhere else. This guarantees
    // pinwheels act as sparse, localized dislocation events rather than global wobble.
    let norm_mag2 = z_mag2 / (z_grad * z_grad * 0.009 + 0.003);
    let pinwheel_core = exp(-norm_mag2 * 2.2);
    let pinwheel_halo = exp(-norm_mag2 * 0.75) * clamp(abs(z_jac) * 1.4, 0.25, 1.0);
    let defect = clamp((pinwheel_core * 0.85 + pinwheel_halo * 0.35) * smoothstep(0.02, 0.90, defect_drive), 0.0, 1.0);

    // Local dislocation coupling: strictly zero over >90% of the field, rising to ~0.95
    // only around pinwheel singularity cores so wavefronts visibly fork and rejoin locally.
    let local_disloc = exp(-norm_mag2 * 0.65) * (0.20 + 0.80 * defect_drive) * az_env;

    // 5. Evaluate Bressloff-Cowan Planforms
    let weights = cx_phase_weights(form_phase);

    // Cut intracortical hypercolumn turbulence by ~75% for tunnel & spiral so their
    // rings and constant-pitch arms stay razor-crisp; keep organic warp for lattice/lace.
    let warp_scale = 0.22 * (weights.x + weights.y) + 0.95 * (weights.z + weights.w);
    let u = u_base + (0.015 + 0.020 * defect_drive) * warp_scale * z_xy.x * az_env;

    let plan_c = cx_eval_planforms(u, v, flow, weights, local_disloc, z_hat, az_env);
    let psi    = plan_c.x;

    // 6. Scale-Invariant Cortical Filigree / Nodal Contour Ridge (`edge`)
    // Evaluated analytically in a single pass so 3x/pixel afterimage calls stay ultra-fast.
    let dist_nodal = abs(psi - 0.12);
    let ridge_grad = exp(-dist_nodal * dist_nodal * 28.0);
    let edge = clamp(max(plan_c.y * 0.88, ridge_grad * 0.78) + pinwheel_core * 0.30, 0.0, 1.0);

    // 7. V1 Firing Activity (`activity` in [0, 1])
    let hyper_ripple = 0.032 * warp_scale * (z_hat.x * cos(14.0 * u) - z_hat.y * sin(14.0 * u)) * az_env;
    let gain = 2.1 + 0.75 * excite;
    let raw_drive = (psi + hyper_ripple - 0.10) * gain;
    let firing = 1.0 / (1.0 + exp(-raw_drive));

    // Gentle foveal calm + peripheral readiness
    let foveal_env = 0.84 + 0.16 * smoothstep(0.0, 0.05, r);
    let activity = clamp(firing * foveal_env, 0.0, 1.0);

    return vec4f(activity, orientation, defect, edge);
}

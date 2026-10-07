#if canImport(Metal)
    /// The shared effects library for the intense visualizers: the pieces every lit, 3-D-looking Metal picture needs,
    /// so a new shader composes them instead of re-deriving them (narduk-libs #1656). Compiled right after
    /// `IntenseShaderCommon` into the one Intense library by `IntenseRenderer`. Every helper is prefixed `fx` so
    /// per-look helpers never collide with it. Reference consumer: `LiquidSplash/LiquidSplashShader.swift`.
    ///
    /// - 3-D value noise (`fxHash31`, `fxNoise3`, `fxFbm3`) and `fxCylinder`, the sample position that makes a field
    ///   seamless around a core and stream outward with `travel`.
    /// - `fxRidge`: thin bright filaments with dark gaps out of a noise value.
    /// - `fxNormal` and `fxLight`: a finite-difference normal and its diffuse + specular terms, the "lit, not flat" rule.
    /// - `fxBall`: a shaded sphere for droplets, beads and planets.
    /// - `fxZoomLayer` and `fxCell`: a grid of things that fly out of the center and grow, continuous across two layers.
    /// - `fxSegment`, `fxBeam`, `fxRoundBox`, `fxStars`: stroke distance, a neon stroke profile, a rounded-box SDF and a
    ///   twinkling far starfield (the Metal ports of the Canvas looks).
    /// - `fxFlash`, `fxTonemap`, `fxVignette`: the finish, with the flash capped at the A11 ration.
    enum IntenseEffects {
        static let source = #"""
            // ---- 3-D noise -------------------------------------------------------------------------------------

            static float fxHash31(float3 p) {
                p = fract(p * float3(0.1031, 0.1030, 0.0973));
                p += dot(p, p.yxz + 33.33);
                return fract((p.x + p.y) * p.z);
            }

            // Smooth 3-D value noise in 0...1.
            static float fxNoise3(float3 p) {
                float3 i = floor(p);
                float3 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                float n000 = fxHash31(i);
                float n100 = fxHash31(i + float3(1, 0, 0));
                float n010 = fxHash31(i + float3(0, 1, 0));
                float n110 = fxHash31(i + float3(1, 1, 0));
                float n001 = fxHash31(i + float3(0, 0, 1));
                float n101 = fxHash31(i + float3(1, 0, 1));
                float n011 = fxHash31(i + float3(0, 1, 1));
                float n111 = fxHash31(i + float3(1, 1, 1));
                float x00 = mix(n000, n100, f.x);
                float x10 = mix(n010, n110, f.x);
                float x01 = mix(n001, n101, f.x);
                float x11 = mix(n011, n111, f.x);
                return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
            }

            // Fractal sum of `octaves` (1...5) halving noise layers, like the 2-D `fbm`: in 0...1, centred near 0.45,
            // so `fxRidge` finds filaments where it crosses 0.5. Three octaves is the cost sweet spot.
            static float fxFbm3(float3 p, int octaves) {
                float v = 0.0;
                float a = 0.5;
                for (int i = 0; i < 5; i++) {
                    if (i >= octaves) break;
                    v += a * fxNoise3(p);
                    p = p * 2.07 + float3(11.3, 7.9, 3.1);
                    a *= 0.5;
                }
                return v;
            }

            // The sample position for a field that must be seamless around a core and stream outward: the direction
            // is a point on a circle (no seam in angle), the radius runs along the third axis and `travel` slides the
            // field outward. `scale` sets the strand count; `stream` how fast they move (0.35 is calm liquid).
            static float3 fxCylinder(float2 p, float scale, float travel, float stream) {
                float r = length(p) + 1e-4;
                float2 dir = p / r;
                return float3(dir * scale * 1.5, r * scale * 0.55 - travel * stream);
            }

            // Thin bright filaments with dark gaps: 1 where a 0...1 field crosses 0.5, falling to 0 outside `thin`
            // (0.8 is thin liquid strands, 0.6 wide ribbons).
            static float fxRidge(float f, float thin) {
                float ridge = 1.0 - abs(f * 2.0 - 1.0);
                return pow(smoothstep(thin, 1.0, ridge), 2.2);
            }

            // ---- Lighting --------------------------------------------------------------------------------------

            // A surface normal from three field samples (`f0` at p, `fx` at p + (e, 0), `fy` at p + (0, e)).
            // Smaller `relief` means stronger relief; 5 reads as glossy liquid, 8 as a fine skin.
            static float3 fxNormal(float f0, float fx, float fy, float e, float relief) {
                return normalize(float3(-(fx - f0) / e, -(fy - f0) / e, relief));
            }

            // Diffuse (x, with a 0.35 ambient floor) and white specular (y) for a normal lit from `light`, as seen from
            // straight ahead. `shininess` 28 is a tight liquid highlight, 8 a broad satin one.
            static float2 fxLight(float3 n, float3 light, float shininess) {
                float diff = 0.35 + 0.65 * max(dot(n, light), 0.0);
                float spec = pow(max(dot(reflect(-light, n), float3(0.0, 0.0, 1.0)), 0.0), shininess);
                return float2(diff, spec);
            }

            // The default key light: upper left, toward the viewer.
            static float3 fxKeyLight() {
                return normalize(float3(-0.45, 0.55, 0.7));
            }

            // A shaded ball of `tint`: `rel` is the pixel's offset from the center in radii (outside 1 draws nothing).
            // Diffuse body, a tight white specular and a bright palette rim, soft edged.
            static float3 fxBall(float2 rel, float3 light, float3 tint) {
                float d2 = dot(rel, rel);
                if (d2 > 1.0) return float3(0.0);
                float d = sqrt(d2);
                float z = sqrt(max(1.0 - d2, 0.0));
                float3 n = float3(rel, z);
                float2 lit = fxLight(n, light, 24.0);
                float diff = 0.25 + 0.75 * max(dot(n, light), 0.0);
                float rim = smoothstep(0.55, 1.0, d);
                float body = 1.0 - smoothstep(0.9, 1.0, d);
                float3 col = tint * (0.12 + 0.5 * diff) * (1.0 - 0.7 * rim) + tint * rim * 1.3 + float3(1.0) * lit.y * 1.3;
                return col * body;
            }

            // ---- Things that fly toward the viewer ------------------------------------------------------------

            struct FxZoomLayer {
                float2 q;      // the layer's own space: contents at q appear at q * scale on screen, so they grow
                float scale;   // 1 -> 2 across the cycle
                float fade;    // 0 at both ends of the cycle, so a layer wraps invisibly
            };

            // A space that zooms out of the center over `zoom` in 0...1 (use fract(travel * rate + offset)); two
            // layers with offsets 0 and 0.5 make a continuous flight. Everything placed on a grid in `q` flies
            // outward and grows as it nears the viewer.
            static FxZoomLayer fxZoomLayer(float2 p, float zoom) {
                FxZoomLayer layer;
                layer.scale = exp2(zoom);
                layer.q = p / layer.scale;
                layer.fade = sin(zoom * 3.14159265);
                return layer;
            }

            // One grid cell of size `cs` in a layer space. Returns false for an empty cell (a hash above `density`),
            // else the cell's jittered center in `center` and its 0...1 hash in `h` (use it for size, hue, phase).
            static bool fxCell(float2 q, float cs, float seed, float density, thread float2 &center, thread float &h) {
                float2 id = floor(q / cs);
                h = hash21(id + seed);
                if (h > density) return false;
                float h2 = hash21(id * 1.73 + seed + 5.1);
                float h3 = hash21(id * 0.61 + seed + 9.7);
                center = (id + 0.5 + (float2(h2, h3) - 0.5) * 0.5) * cs;
                return true;
            }

            // ---- Strokes, shapes and stars (the Metal ports of the Canvas looks) -------------------------------

            // Distance from `p` to the segment a-b.
            static float fxSegment(float2 p, float2 a, float2 b) {
                float2 pa = p - a;
                float2 ba = b - a;
                float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
                return length(pa - ba * h);
            }

            // A neon stroke at distance `d` from its center line: x is the hot core (a tight gaussian of half-width
            // `width`), y the soft halo that bleeds well past it.
            static float2 fxBeam(float d, float width) {
                float core = exp(-d * d / (width * width));
                float halo = exp(-d / (width * 3.5)) * 0.35;
                return float2(core, halo);
            }

            // Signed distance to a rounded box of half-size `h` and corner radius `r` (negative inside).
            static float fxRoundBox(float2 p, float2 h, float r) {
                float2 q = abs(p) - h + r;
                return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            }

            // A dim far starfield: points that twinkle, in cells of `1/scale` of the space. Returns 0 ... 1.
            static float fxStars(float2 p, float scale, float seed, float time) {
                float2 sp = p * scale;
                float2 id = floor(sp);
                float h = hash21(id + seed);
                float2 c = id + 0.5 + (float2(hash21(id + seed + 3.1), hash21(id + seed + 7.7)) - 0.5) * 0.8;
                float star = exp(-dot(sp - c, sp - c) * 60.0) * step(0.88, h) * (0.3 + 0.7 * hash21(id + seed + 1.3));
                return star * (0.5 + 0.5 * sin(time * 1.5 + h * 40.0));
            }

            // ---- The finish ------------------------------------------------------------------------------------

            // The only full-screen brightness jump a shader may add: the CPU-rationed flash (3/s, 0.55 cap,
            // red-safe), at most 0.35 of it.
            static float3 fxFlash(float3 col, constant IntenseUniforms &u, float k) {
                return col + u.flashColor.rgb * u.extra.x * min(k, 0.35);
            }

            // Compress additive light so stacked layers never clip to white (k 1.4 is bright, 1.0 restrained).
            static float3 fxTonemap(float3 col, float k) {
                return 1.0 - exp(-col * k);
            }

            // Darken toward the corners; `p` is the centered, aspect-corrected position (|p| about 1 at the edge).
            static float3 fxVignette(float3 col, float2 p, float k) {
                return col * (1.0 - k * dot(p, p));
            }
            """#
    }
#endif

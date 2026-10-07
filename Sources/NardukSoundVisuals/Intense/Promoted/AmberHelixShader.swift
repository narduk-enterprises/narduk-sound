#if canImport(Metal)
    /// A lit molecular double helix in a field of cells; the kick expands it and the snare opens its rungs. Promoted from the SoundGallery drop-in plugin `amber-helix.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum AmberHelixShader {
        static let source = #"""
            // title: Amber Helix
            // fragment: amberHelixFragment
            // Living molecular sculpture: analytic lit tubes and cells, no ray march.

            static float3 ahColor(float t, constant IntenseUniforms &u) {
                t = fract(t);
                float3 a = float3(0.10, 0.37, 0.32), b = float3(0.95, 0.31, 0.065), c = float3(1.0, 0.82, 0.38);
                if (u.extra.y > 0.5) { a = u.c0.rgb; b = u.c1.rgb; c = u.c2.rgb; }
                return t < 0.5 ? mix(a, b, t * 2.0) : mix(b, c, t * 2.0 - 1.0);
            }

            static float2 ahRotate(float2 p, float a) {
                return float2(cos(a)*p.x-sin(a)*p.y, sin(a)*p.x+cos(a)*p.y);
            }

            static void ahTube(thread float3 &col, float2 p, float2 a, float2 b, float r,
                               float3 tint, float light, float px) {
                float2 v = b-a;
                float h = saturate(dot(p-a,v)/max(dot(v,v),0.00001));
                float2 q = p-a-h*v;
                float d = length(q);
                float aa = max(px*1.2,0.001);
                float coverage = 1.0-smoothstep(r-aa,r+aa,d);
                if (coverage > 0.0) {
                    float z = sqrt(max(1.0-d*d/(r*r),0.0));
                    float3 n = normalize(float3(q/r,z+0.001));
                    float diffuse = max(dot(n,normalize(float3(-0.5,0.7,1.0))),0.0);
                    float spec = pow(max(dot(n,normalize(float3(-0.28,0.4,1.0))),0.0),22.0);
                    float3 body = tint*(0.16+0.75*diffuse)*light;
                    body += tint*spec*1.7 + tint*pow(1.0-z,3.0)*0.25;
                    col = mix(col,body,coverage);
                }
            }

            fragment float4 amberHelixFragment(IntenseVertexOut in [[stage_in]],
                constant IntenseUniforms &u [[buffer(0)]], constant float *spectrum [[buffer(1)]],
                constant float *wave [[buffer(2)]]) {
                float intensity = saturate(u.extra.z), t = u.resTime.z*(0.3+0.7*intensity);
                float kick = sqrt(saturate(u.env.x))*intensity, snare = sqrt(saturate(u.env.y))*intensity, hat = sqrt(saturate(u.env.z))*intensity;
                float bass = sqrt(saturate(bandAt(spectrum,0.07)))*intensity, drop = u.misc.y*intensity;
                float energy = sqrt(saturate(u.wobble.z))*intensity, travel = u.misc.z;
                float px = 2.0/max(u.resTime.y,1.0);
                float2 p = (in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                p *= 1.0-0.10*kick-0.06*bass;
                float2 q = ahRotate(p,-0.57+0.13*sin(t*0.2)+0.12*energy*sin(u.resTime.w*1.5708)+0.08*snare);
                float haze = exp(-q.x*q.x*2.2);
                float3 col = ahColor(0.03,u)*(0.012+0.09*haze);
                col += ahColor(0.64,u)*exp(-dot(p-float2(-0.5,0.3),p-float2(-0.5,0.3))*1.4)*0.04;
                // Two distant strands pull the music through the whole volume.
                for (int layer=0;layer<2;layer++) {
                    float f=float(layer), sign=layer==0?-1.0:1.0;
                    float y=q.y+sign*0.3;
                    float x=sign*0.95+(0.22+0.13*bass)*sin(y*4.3-travel*0.8+f*2.1);
                    float dd=abs(q.x-x), width=max(px*1.3,0.012);
                    float packet=pow(0.5+0.5*sin(y*7.0-u.resTime.w*3.14159+f*1.8),8.0);
                    col+=ahColor(0.12+f*0.68,u)*(exp(-dd/width)*0.32+exp(-dd/0.09)*0.05)*(0.2+energy+packet*snare);
                }
                // Out-of-focus suspended cells behind the helix. Hats light their rims.
                for (int i=0;i<28;i++) {
                    float f=float(i), seed=hash11(f+17.0);
                    float2 c=float2((hash11(f+3.0)-0.5)*3.6,fract(seed+t*(0.015+seed*0.015)+travel*0.035)*2.8-1.4);
                    c.x += 0.1*sin(t*0.4+f);
                    float r=(0.022+seed*0.05)*(1.0+0.8*snare), d=length(p-c);
                    float rim=exp(-pow((d-r)/max(px*1.5,0.007),2.0));
                    col += ahColor(seed,u)*(rim*(0.08+hat*0.45)+exp(-d*d/(r*r*3.0))*0.028);
                }
                // Two depth passes keep the dark, rear backbone behind the cross links.
                for (int pass=0;pass<2;pass++) {
                    for (int i=0;i<34;i++) {
                        float y=(float(i)-16.5)*0.092;
                        float localBand=sqrt(saturate(bandAt(spectrum,float(i)/34.0)))*intensity;
                        float phase=y*(5.1+0.8*bass)+t*0.3+travel*0.85;
                        float unzip=snare*exp(-pow((y+1.5-(1.0-snare)*3.0)/0.4,2.0));
                        float radius=0.38+0.13*bass+0.10*kick+0.16*drop+0.07*localBand+0.23*unzip;
                        float sway=(0.06+0.11*snare+0.07*drop)*sin(y*3.2-u.resTime.w*1.5708);
                        float nextPhase=(y+0.092)*(5.1+0.8*bass)+t*0.3+travel*0.85;
                        float2 a=float2(sway+radius*cos(phase),y);
                        float2 b=float2(sway-radius*cos(phase),y);
                        if(pass==0) {
                            float band=bandAt(spectrum,float(i)/34.0);
                            float3 tint=ahColor(0.25+0.65*band,u);
                            ahTube(col,q,a,b,0.011+0.010*localBand,tint,0.65+0.45*localBand,px);
                            // A bright messenger travels up the rungs on the beat grid.
                            float travel=0.5+0.5*sin(u.resTime.w*1.57-y*2.0);
                            float2 bead=mix(a,b,travel);
                            ahTube(col,q,bead,bead+float2(0.0001,0),0.029+0.025*snare,ahColor(0.94,u),1.4,px);
                        }
                        for(int strand=0;strand<2;strand++) {
                            float sign=strand==0?1.0:-1.0, z=sin(phase)*sign;
                            if((pass==0 && z>0.0)||(pass==1 && z<=0.0)) continue;
                            float2 c=strand==0?a:b;
                            float2 next=float2((0.06+0.11*snare+0.07*drop)*sin((y+0.092)*3.2-u.resTime.w*1.5708)+radius*cos(nextPhase)*sign,y+0.092);
                            float pulse=exp(-pow((y-(fract(u.resTime.w*0.125)*3.8-1.9))/0.20,2.0));
                            float r=(0.037+0.009*(z+1.0))*(1.0+0.4*kick+0.4*pulse+0.2*localBand);
                            float3 tint=ahColor(strand==0?0.77:0.14,u);
                            ahTube(col,q,c,next,r*0.64,tint,0.65+0.32*z,px);
                            ahTube(col,q,c,c+float2(0.0001,0),r,tint,0.85+0.35*z+0.6*localBand,px);
                            float core=exp(-dot(q-c,q-c)/(r*r*0.12));
                            col += ahColor(0.97,u)*core*(0.25+0.9*hat+0.8*pulse);
                            float aura=exp(-length(q-c)/(r*1.8));
                            col += tint*aura*(0.06+0.12*kick+0.16*unzip);
                        }
                    }
                }
                col=fxTonemap(fxFlash(col,u,0.12),1.45);
                return float4(saturate(fxVignette(col,p,0.075)),1.0);
            }
            """#
    }
#endif

#if canImport(Metal)
    /// A banded planet over rippling rings that the bass sets rolling. Promoted from the SoundGallery drop-in plugin `tidal-observatory.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum TidalObservatoryShader {
        static let source = #"""
            // title: Tidal Observatory
            // fragment: tidalObservatoryFragment
            // A gas giant and its solid icy rings. Analytic ray intersections, no ray march.

            static float3 toColor(float t, constant IntenseUniforms &u) {
                t=saturate(t);
                float3 a=float3(0.045,0.13,0.29),b=float3(0.2,0.58,0.66),c=float3(1.0,0.68,0.37);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                return t<0.5?mix(a,b,t*2.0):mix(b,c,t*2.0-1.0);
            }
            static float toSphere(float3 ro,float3 rd,float3 center,float r) {
                float3 oc=ro-center; float b=dot(oc,rd),h=b*b-dot(oc,oc)+r*r;
                return h>0.0?-b-sqrt(h):1e5;
            }
            static float3 toPlanet(float3 p,float3 n,float t,float bass,float snare,float kick,float beat,float energy,
                                   float3 light,constant IntenseUniforms &u) {
                float longitude=atan2(n.z,n.x)+t*0.13+beat*0.16;
                float3 q=float3(cos(longitude),n.y*2.0,sin(longitude));
                float clouds=fxFbm3(q*4.0+float3(t*0.03,0,0),4);
                float lat=n.y+(0.06+0.075*bass)*sin(longitude*3.0+n.y*8.0)+0.12*(clouds-0.5);
                float stripes=0.5+0.5*sin(lat*24.0+clouds*4.0);
                float fine=0.5+0.5*sin(lat*48.0+clouds*6.0);
                float diffuse=max(dot(n,light),0.0);
                float3 color=toColor(0.16+0.76*(0.75*stripes+0.25*fine),u);
                color*=0.045+1.0*pow(diffuse,0.75);
                // Broad polar aurora changes latitude with bass; a local snare arc.
                float aurora=exp(-pow((abs(n.y)-(0.68-0.09*bass))/0.065,2.0));
                color+=toColor(0.48,u)*aurora*(.45+.35*sin(longitude*6.0+t)+1.1*snare);
                float storm=pow(0.5+0.5*sin(longitude*8.0+n.y*5.0-beat*1.5708),18.0);
                color+=toColor(.93,u)*storm*exp(-n.y*n.y*3.0)*(.12*energy+.65*kick);
                float rim=pow(1.0-max(n.z,0.0),3.0);
                color+=toColor(0.40,u)*rim*(0.17+0.28*diffuse);
                return color;
            }
            fragment float4 tidalObservatoryFragment(IntenseVertexOut in [[stage_in]],
                constant IntenseUniforms &u [[buffer(0)]],constant float *spectrum [[buffer(1)]],
                constant float *wave [[buffer(2)]]) {
                float intensity=saturate(u.extra.z),t=u.resTime.z*(0.35+0.65*intensity);
                float kick=sqrt(saturate(u.env.x))*intensity,snare=sqrt(saturate(u.env.y))*intensity,hat=sqrt(saturate(u.env.z))*intensity;
                float bass=sqrt(saturate(bandAt(spectrum,0.06)))*intensity,drop=u.misc.y*intensity;
                float energy=sqrt(saturate(u.wobble.z))*intensity,travel=u.misc.z;
                float px=2.0/max(u.resTime.y,1.0);
                float2 p=(in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                float roll=.09*sin(travel*.23)+.055*snare;
                p=float2(cos(roll)*p.x-sin(roll)*p.y,sin(roll)*p.x+cos(roll)*p.y);
                p*=1.0-.09*kick-.09*drop;
                float3 col=toColor(0.04,u)*0.026;
                float mist=fxFbm3(float3(p*1.3,t*0.015),3);
                col+=toColor(0.26,u)*pow(mist,3.0)*0.12;
                // Fixed stars with a continuous drift, never a reseeded blinking field.
                float2 starGrid=p*23.0+float2(travel*0.18,t*0.018),id=floor(starGrid),f=fract(starGrid)-0.5;
                float seed=hash21(id),size=max(px*23.0*1.3,0.032);
                if(seed>0.965)col+=toColor(fract(seed*17.0),u)*exp(-dot(f,f)/(size*size))*(0.25+1.1*hat);
                float3 ro=float3(0,0,4.2-0.22*drop),rd=normalize(float3(p, -2.6));
                float3 center=float3(-0.13,0.035,0),light=normalize(float3(-0.7,0.6,0.8));
                float radius=0.78+0.045*kick+0.035*bass;
                float hit=toSphere(ro,rd,center,radius);
                float angle=-0.42+0.18*sin(travel*0.25)+0.22*drop+0.10*snare;
                float3 ringNormal=normalize(float3(sin(angle)*0.7,cos(angle)*0.7,0.40));
                float denom=dot(rd,ringNormal),ringHit=1e5;
                if(abs(denom)>0.0001)ringHit=dot(center-ro,ringNormal)/denom;
                float3 rp=ro+rd*ringHit-center;
                float az=atan2(rp.y,rp.x);
                float tidal=.065*snare*sin(az*5.0-u.resTime.w*1.5708)+.035*bass*sin(az*3.0+travel);
                float rr=length(rp)+tidal;
                float outer=1.73+.14*bass+.12*drop;
                bool ring=ringHit>0.0&&rr>1.03&&rr<outer;
                if(hit<1e4&&hit>0.0){
                    float3 point=ro+rd*hit,n=normalize(point-center);
                    col=toPlanet(point,n,t,bass,snare,kick,u.resTime.w,energy,light,u);
                    // Ring shadow projected onto the giant along the same key light.
                    float sh=dot(center-point,ringNormal)/dot(light,ringNormal);
                    float sr=length(point+light*sh-center);
                    if(sh>0.0&&sr>1.03&&sr<1.73)col*=0.5;
                } else {
                    float closest=length(cross(center-ro,rd));
                    col+=toColor(0.45,u)*exp(-max(closest-radius,0.0)/0.032)*0.13;
                }
                if(ring&&ringHit<hit){
                    float x=(rr-1.03)/(outer-1.03);
                    // Twelve broad icy lanes, derivative-filtered at distant edges.
                    float freq=12.0, phase=x*freq-.6*kick*sin(az*2.0+travel)-.8*snare;
                    float footprint=max(fwidth(phase),px);
                    float grooves=0.5+0.5*cos(phase*6.28318)*exp(-footprint*footprint*7.0);
                    float gap=1.0-0.88*exp(-pow((x-0.62)/0.025,2.0));
                    float bands=bandAt(spectrum,x*0.85);
                    float wavefront=exp(-pow((x-(1.0-kick))/.075,2.0))*kick;
                    float3 material=toColor(0.30+0.65*x,u)*(.25+.58*grooves+.36*bands);
                    material+=toColor(.48,u)*wavefront*1.1;
                    float sectorBurst=pow(.5+.5*sin(az*11.0-travel*2.0+x*8.0),20.0);
                    material+=toColor(.95,u)*sectorBurst*grooves*(.16+.8*hat+.7*drop);
                    float shadowHit=toSphere(center+rp+light*0.015,light,center,radius);
                    float shadow=shadowHit>0.0&&shadowHit<1e4?0.18:1.0;
                    float azimuth=atan2(rp.y,rp.x);
                    float messenger=pow(0.5+0.5*cos(azimuth-u.resTime.w*0.28),18.0);
                    material+=toColor(0.95,u)*messenger*(0.15+0.65*kick);
                    material*=shadow*gap;
                    float aa=max(fwidth(rr)*1.3,px);
                    float coverage=smoothstep(1.03,1.03+aa,rr)*(1.0-smoothstep(outer-aa,outer,rr));
                    col=mix(col,material,coverage);
                }
                // Two solid shepherd moons follow the musical beat, not random particles.
                for(int j=0;j<2;j++){
                    float fj=float(j),orbit=t*0.06+travel*0.38+fj*3.1;
                    float3 mc=float3(1.65*cos(orbit),0.8*sin(orbit)+0.26,0.55+fj*0.5);
                    float r=0.10-fj*0.025,mh=toSphere(ro,rd,mc,r);
                    float occluder=ring?min(hit,ringHit):hit;
                    if(mh>0.0&&mh<occluder){
                        float3 n=normalize(ro+rd*mh-mc);
                        float craters=fxNoise3(n*13.0)*0.3+0.7;
                        col=toColor(0.85-fj*0.3,u)*(0.08+0.8*max(dot(n,light),0.0))*craters;
                    }
                }
                col=fxTonemap(fxFlash(col,u,0.1),1.5);
                return float4(saturate(fxVignette(col,p,0.055)),1.0);
            }
            """#
    }
#endif

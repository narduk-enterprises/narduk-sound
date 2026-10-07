#if canImport(Metal)
    /// A thought engine tearing out of its casing: fractured chrome, molten cores and snapping nerve cables. Promoted from the SoundGallery drop-in plugin `astra-unbound.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum AstraUnboundShader {
        static let source = #"""
            // title: Astra Unbound
            // fragment: astraUnboundFragment
            // A thought engine tearing out of its casing: fractured chrome, molten reasoning,
            // snapping nerve cables and a storm of rejected hypotheses. Tuned for heavy bass.
            // Geometry carries the impact. Full-frame flash is only the gallery's rationed one.

            struct AuDrive {
                float t, beat, travel, kick, snare, hat, bass, mid, high, energy, drop, intensity;
                float growl, split, kickHit, snareHit, bodyScale;
            };

            static float2 auRotate(float2 p, float angle) {
                float c=cos(angle),s=sin(angle);
                return float2(c*p.x-s*p.y,s*p.x+c*p.y);
            }

            static float3 auColor(float t, constant IntenseUniforms &u) {
                float3 a=float3(0.025,0.75,1.0), b=float3(0.66,0.035,0.94), c=float3(1.0,0.33,0.045);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                float x=fract(t)*3.0,f=fract(x);f=f*f*(3.0-2.0*f);
                return x<1.0?mix(a,b,f):(x<2.0?mix(b,c,f):mix(c,a,f));
            }

            static float3 auLocal(float3 p, thread const AuDrive &d) {
                // Accumulated travel provides continuous rotation across changing energy levels.
                p.xz=auRotate(p.xz,d.travel*.36+d.t*.13);
                p.yz=auRotate(p.yz,.38+d.travel*.17+d.snare*.62*sin(d.beat*.785398));
                p.xy=auRotate(p.xy,.18*sin(d.travel*.24)+.12*d.growl);
                return p/d.bodyScale;
            }

            static float2 auMap(float3 world, thread const AuDrive &d) {
                float3 p=auLocal(world,d);
                float stretch=1.0+.15*d.growl;
                p*=float3(stretch,1.0/stretch,1.0);
                // Eight triangular armor plates: the octant gaps are real empty space.
                float3 q=abs(p)-d.split;
                float panel=abs((q.x+q.y+q.z-1.08)*.5773503)-.064;
                panel=max(panel,.055-min(q.x,min(q.y,q.z)));
                float2 hit=float2(panel,1.0);
                // The exposed heart is a rounded, faceted crystal. Its growl changes its shape.
                float3 core=p;
                core+=sin(core.yzx*5.0+d.travel*.8)*(.024+.032*d.mid);
                float heart=(abs(core.x)+abs(core.y)+abs(core.z)-(.48+.12*d.bass+.065*d.kick))*.5773503-.035;
                if(heart<hit.x)hit=float2(heart,2.0);
                // A twelve-edge cage buckles around the heart; cut rings never close into a disc.
                for(int axis=0;axis<3;axis++){
                    float3 v=axis==0?p:(axis==1?p.yzx:p.zxy);
                    v.xy=auRotate(v.xy,float(axis)*.51+d.travel*.18);
                    float radius=.71+.075*d.growl+.08*d.kick;
                    float rail=length(float2(length(v.xy)-radius,v.z))-(.022+.010*d.bass);
                    float cut=.10-abs(v.x);
                    rail=max(rail,cut);
                    if(rail<hit.x)hit=float2(rail,3.0+float(axis)*.1);
                }
                // Angular folding is distance preserving; mild core warp/stretch are bounded.
                hit.x*=.70*d.bodyScale;
                return hit;
            }

            static float3 auNormal(float3 p, float e, thread const AuDrive &d) {
                const float3 a=float3(1,-1,-1),b=float3(-1,-1,1),c=float3(-1,1,-1),f=float3(1,1,1);
                return normalize(a*auMap(p+a*e,d).x+b*auMap(p+b*e,d).x+c*auMap(p+c*e,d).x+f*auMap(p+f*e,d).x);
            }

            static float auLine(float distance,float width,float px) {
                float w=max(width,px*1.3);
                return exp(-distance*distance/(w*w));
            }

            static float3 auThoughts(float2 p,float px,thread const AuDrive &d,
                                     constant IntenseUniforms &u,constant float *spectrum) {
                float r=max(length(p),.01),a=atan2(p.y,p.x);
                float3 col=float3(0);
                // Two depths of elastic, branching conductors, with local spectrum assignments.
                for(int layer=0;layer<2;layer++){
                    float f=float(layer),count=7.0+f*4.0;
                    float angle=a+.16*d.travel*(f==0.0?1.0:-1.0);
                    float sector=floor((angle+12.566371)*count/6.2831853);
                    float seed=hash11(sector+f*17.0);
                    float band=sqrt(saturate(bandAt(spectrum,seed*.86+.04)))*d.intensity;
                    float twist=(.38+.32*band)*sin(r*(3.4+f)-d.travel*.85+seed*8.0);
                    twist+=.24*d.snare*sin(r*7.0+seed*5.0);
                    float phase=angle*count+twist*3.0+r*(1.2+f*.8);
                    float distance=abs(sin(phase))*r/count;
                    float split=abs(abs(sin(phase))-(.16+.35*band)*smoothstep(.7,2.0,r))*r/count;
                    float line=auLine(distance,.006+.004*band,px);
                    float branch=auLine(split,.0035,px)*.32;
                    float halo=exp(-distance/max(.024,.013+.028*band));
                    float travel=pow(.5+.5*cos(r*10.0-d.beat*6.2831853+seed*8.0),12.0);
                    float mask=smoothstep(.30,.66,r)*exp(-max(r-1.25,0.0)*1.35);
                    float3 tint=auColor(seed*.7+f*.3,u);
                    col+=tint*mask*((line+branch)*(.13+.44*band+travel*(.65+.8*d.snare))+.045*halo)*(1.0-f*.35);
                    // Hat ticks are tiny nodes riding the conductors, never a screen-wide flash.
                    float node=pow(.5+.5*sin(r*25.0+seed*30.0-d.travel*2.0),24.0);
                    col+=auColor(seed+.35,u)*line*node*mask*d.hat*.95;
                }
                return col;
            }

            fragment float4 astraUnboundFragment(IntenseVertexOut in [[stage_in]],
                constant IntenseUniforms &u [[buffer(0)]],constant float *spectrum [[buffer(1)]],
                constant float *wave [[buffer(2)]]) {
                AuDrive d;
                d.intensity=saturate(u.extra.z);d.t=u.resTime.z*(.3+.7*d.intensity);
                d.beat=u.resTime.w;d.travel=u.misc.z;
                d.kick=saturate(u.env.x)*d.intensity;
                d.kickHit=pow(saturate(u.env.x),1.65)*d.intensity;
                d.snare=pow(saturate(u.env.y),.8)*d.intensity;
                d.snareHit=pow(saturate(u.env.y),1.8)*d.intensity;
                d.hat=sqrt(saturate(u.env.z))*d.intensity;
                d.bass=sqrt(saturate((bandAt(spectrum,.025)+bandAt(spectrum,.07)+bandAt(spectrum,.13))/3.0))*d.intensity;
                d.mid=sqrt(saturate((bandAt(spectrum,.25)+bandAt(spectrum,.44))*.5))*d.intensity;
                d.high=sqrt(saturate(bandAt(spectrum,.8)))*d.intensity;
                d.energy=sqrt(saturate(u.wobble.z))*d.intensity;d.drop=saturate(u.misc.y)*d.intensity;
                // A half-time growl stretches the solid heart. No multiplying elapsed time by level.
                d.growl=sin(d.beat*3.14159265)*d.bass*(.45+.55*d.mid);
                // Sharp attack, then a visible recoil trough: sustained bass cannot hold it open.
                float rawKick=saturate(u.env.x);
                float recoil=4.0*rawKick*(1.0-rawKick)*d.intensity;
                d.bodyScale=.82+.40*d.kickHit-.10*recoil+.09*d.bass+.055*d.growl;
                d.split=.008+.035*d.bass+.52*d.kickHit+.16*d.drop+.24*d.snareHit;
                float px=2.0/max(u.resTime.y,1.0);
                float2 screen=(in.uv-.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                float2 p=screen;
                // A punch, a recoil, and a torsional snap, all bounded; no random whole-frame jitter.
                p*=1.0-.025*d.kickHit;
                p=auRotate(p,.07*sin(d.travel*.3)+.12*d.snare*sin(d.beat*1.570796));
                p+=float2(.012*sin(d.t*17.0),.017*cos(d.t*13.0))*d.kick;
                float r=length(p);
                float3 col=auColor(.16,u)*(.008+.038*exp(-r*r*1.4));
                col+=auColor(.48,u)*.025*fxFbm3(float3(p*1.7,d.travel*.025),3);
                col+=auThoughts(p,px,d,u,spectrum);
                float3 ro=float3(.12*sin(d.travel*.19),.06*cos(d.travel*.2),5.2);
                const float focal=2.25;
                float3 rd=normalize(float3(p,-focal));
                float distance=0.0,glow=0.0;float2 hit=float2(1,0);bool found=false;
                for(int i=0;i<60;i++){
                    float3 point=ro+rd*distance;
                    hit=auMap(point,d);
                    float nearCore=max(length(point)-.44,0.0);
                    glow+=exp(-nearCore*8.0)*.008;
                    if(hit.x<max(.0014,distance*px*.22)){found=true;break;}
                    distance+=max(hit.x,.0025);
                    if(distance>9.0)break;
                }
                col+=auColor(.02,u)*glow*(.8+d.bass);
                if(found){
                    float3 point=ro+rd*distance,local=auLocal(point,d);
                    float3 n=auNormal(point,max(.002,distance*px*.26),d);
                    float3 light=normalize(float3(-.5,.75,.9)),view=-rd;
                    float diffuse=max(dot(n,light),0.0),back=max(dot(n,normalize(float3(.7,-.3,-.5))),0.0);
                    float spec=pow(max(dot(n,normalize(light+view)),0.0),36.0);
                    float fresnel=pow(1.0-max(dot(n,view),0.0),3.0);
                    float3 reflection=reflect(rd,n);
                    float strip=pow(saturate(1.0-abs(reflection.y-.25)*1.3),12.0);
                    float hue=.17+.14*local.y+.10*sign(local.x);
                    float3 base=auColor(hue,u);
                    float3 surface=base*(.09+.34*diffuse+.22*back)+auColor(hue+.32,u)*(1.1*spec+.65*strip+.5*fresnel);
                    if(hit.y<1.5){
                        // Etched circuits on armor: broad lanes with derivative-filtered fine edges.
                        float3 q=abs(local)-d.split;
                        float seam=min(q.x,min(q.y,q.z))-.055;
                        float edge=exp(-max(seam,0.0)/max(.018,px*distance*1.3));
                        float circuit=abs(sin((q.x-q.y+q.z*.5)*15.0));
                        float trace=1.0-smoothstep(.07,.16+fwidth(circuit),circuit);
                        float packet=pow(.5+.5*sin(q.y*12.0-d.beat*6.2831853),8.0);
                        surface+=auColor(.71+sign(local.y)*.1,u)*(edge*(.65+2.6*d.kickHit+1.3*d.snareHit)+trace*(.12+.75*packet+.65*d.hat));
                    }else if(hit.y<2.5){
                        float veins=fxRidge(fxFbm3(local*7.0+float3(0,d.travel*.6,0),3),.65);
                        float face=.5+.5*sin(local.x*12.0+local.y*9.0-d.travel*2.0);
                        surface=auColor(.02+face*.45,u)*(.45+1.25*veins+.9*diffuse+2.2*d.kickHit+1.0*d.snareHit)+auColor(.75,u)*spec;
                    }else{
                        surface=auColor((hit.y-3.0)*2.3+d.travel*.015,u)*(.75+.65*diffuse+1.6*d.kickHit)+auColor(.8,u)*spec;
                    }
                    float ao=.55+.45*saturate(auMap(point+n*.12,d).x/.08);
                    col=surface*ao+auColor(.05,u)*glow*.6;
                }
                // Fifty-six fragments: twenty-four orbiting pieces plus thirty-two impact ejecta. A perspective depth test
                // lets nearer pieces cross the machine while rear pieces stay behind it.
                for(int j=0;j<56;j++){
                    float f=float(j),seed=hash11(f*7.13+4.0);
                    bool ejecta=j>=24;
                    float impact=max(d.kick,d.snare);
                    float age=1.0-impact;
                    float cycle=ejecta?age:fract(d.travel*(.075+seed*.035)+seed);
                    float a=f*2.399963+d.travel*(.12+seed*.12);
                    float radius=ejecta?
                        .55+age*(3.5+seed*2.0+d.drop*2.0):
                        .8+cycle*cycle*(2.5+2.0*d.drop);
                    radius+=.30*d.kickHit;
                    float z=sin(f*4.1+d.travel*.17)*(ejecta?1.8:1.15);
                    float3 center=float3(cos(a)*radius,sin(a)*radius*.8,z);
                    center.xy+=float2(sin(f+d.travel),cos(f*2.0-d.travel))*.08*d.mid;
                    float forward=ro.z-center.z;
                    float2 projection=(center.xy-ro.xy)*focal/forward;
                    float2 relative=auRotate(p-projection,d.travel*.8+f);
                    float size=max(px*1.4,(.018+.036*seed+.018*d.hat+(ejecta?.026*impact:0.0))*focal/forward);
                    float diamond=(abs(relative.x)*.7+abs(relative.y))/size;
                    float coverage=1.0-smoothstep(.75,1.0+px/size,diamond);
                    float depth=(center.z-ro.z)/rd.z;
                    if(coverage>0.0&&(!found||depth<distance)){
                        float fade=ejecta?impact:smoothstep(.0,.12,cycle)*(1.0-smoothstep(.78,1.0,cycle));
                        float facet=relative.x>0.0?.38:1.0;
                        float3 shard=auColor(seed,u)*(facet+.95*d.hat+.80*d.snareHit+(ejecta?1.5*impact:0.0));
                        col=mix(col,shard,coverage*fade);
                    }
                    if(ejecta&&impact>.025&&(!found||depth<distance)){
                        float2 radial=normalize(projection+float2(.0001,0));
                        float2 delta=p-projection;
                        float along=dot(delta,radial),across=dot(delta,float2(-radial.y,radial.x));
                        float tail=exp(-pow(across/max(px*1.3,size*.32),2.0));
                        tail*=exp(-abs(along)/(.025+.15*age))*(1.0-smoothstep(-px,px,along));
                        col+=auColor(seed+.12,u)*tail*impact*(.6+1.1*d.drop);
                    }
                }
                // Local snare ruptures propagate outward as staggered broken arcs, not a flash.
                if(d.snare>.01){
                    float a=atan2(p.y,p.x),front=.25+(1.0-d.snare)*2.7;
                    float ragged=.035*sin(a*9.0+d.travel)+.025*sin(a*17.0);
                    float wavefront=auLine(r-front-ragged,.013+.015*d.snare,px);
                    float breaks=pow(.5+.5*sin(a*7.0+d.travel*.3),3.0);
                    col+=auColor(.73,u)*wavefront*breaks*d.snare*2.8;
                }
                // A separate kick compression wave gives the downbeat a strong spatial hit.
                float kickFront=.20+(1.0-d.kick)*2.5;
                float kickArc=auLine(r-kickFront,.018+.024*d.kickHit,px);
                float lobes=.3+.7*pow(.5+.5*sin(atan2(p.y,p.x)*5.0+d.travel),2.0);
                col+=auColor(.025,u)*kickArc*lobes*d.kick*2.5;
                // Short, localized discharge at the center; never a full-frame oscillator.
                float discharge=exp(-r*r/.032)*(d.kickHit+d.snareHit*.8);
                col+=auColor(.77,u)*discharge*1.8;
                col=fxTonemap(col,1.25);
                // Use the complete permitted flash allowance after tonemapping so it remains visible.
                col=fxFlash(col,u,.35);
                return float4(saturate(fxVignette(col,screen,.055)),1.0);
            }
            """#
    }
#endif

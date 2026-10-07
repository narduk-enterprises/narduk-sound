#if canImport(Metal)
    /// Liquid-metal ribbons weaving through the dark, lit and twisted by the spectrum. Promoted from the SoundGallery drop-in plugin `mercury-loom.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum MercuryLoomShader {
        static let source = #"""
            // title: Mercury Loom
            // fragment: mercuryLoomFragment
            // Three broad, twisting metal ribbons: 56 bounded SDF steps and studio lighting.

            struct MlDrive {float t;float beat;float bass;float kick;float snare;float drop;float energy;float travel;float3 bands;};
            static float3 mlColor(float t,constant IntenseUniforms &u){
                t=fract(t);float3 a=float3(0.08,0.12,0.40),b=float3(0.80,0.14,0.30),c=float3(0.95,0.67,0.37);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                return t<0.5?mix(a,b,t*2.0):mix(b,c,t*2.0-1.0);
            }
            static float2 mlMap(float3 p,thread const MlDrive &d){
                float2 result=float2(100.0,0);
                for(int j=0;j<3;j++){
                    float f=float(j),phase=f*2.0944;
                    float angle=p.y*(1.10+0.85*d.bass)+d.t*0.15+d.travel*0.65+phase+0.34*sin(d.beat*1.5708)*d.energy;
                    float radius=0.38+0.22*d.drop+0.19*d.kick+0.10*d.bands[j];
                    float2 center=radius*float2(cos(angle),sin(angle));
                    center.x+=0.18*d.snare*sin(p.y*3.0-d.beat*1.5708+phase);
                    float2 q=p.xz-center;
                    float twist=angle+(0.50+0.65*d.bands[j])*sin(p.y*1.5+d.travel*0.5+phase)+d.snare*0.75*sin(p.y*2.0+phase);
                    q=float2(cos(twist)*q.x-sin(twist)*q.y,sin(twist)*q.x+cos(twist)*q.y);
                    float2 box=abs(q)-float2(0.24+0.09*d.bands[j]+0.045*sin(p.y*2.0+phase),0.028);
                    float sd=(length(max(box,0.0))+min(max(box.x,box.y),0.0)-0.018)*0.44;
                    sd=max(sd,abs(p.y)-1.65);
                    if(sd<result.x)result=float2(sd,f);
                }
                return result;
            }
            fragment float4 mercuryLoomFragment(IntenseVertexOut in [[stage_in]],constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]],constant float *wave [[buffer(2)]]){
                float intensity=saturate(u.extra.z),px=2.0/max(u.resTime.y,1.0);
                MlDrive d;d.t=u.resTime.z*(0.3+0.7*intensity);d.beat=u.resTime.w;d.bass=sqrt(saturate(bandAt(spectrum,0.05)))*intensity;
                d.kick=sqrt(saturate(u.env.x))*intensity;d.snare=sqrt(saturate(u.env.y))*intensity;d.drop=u.misc.y*intensity;
                d.energy=sqrt(saturate(u.wobble.z))*intensity;d.travel=u.misc.z;
                d.bands=sqrt(saturate(float3(bandAt(spectrum,0.1),bandAt(spectrum,0.4),bandAt(spectrum,0.75))))*intensity;
                float2 p=(in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                p*=1.0-0.08*d.kick;
                float angle=-0.58+0.24*sin(d.travel*0.24)+0.18*d.snare;float2 q=float2(cos(angle)*p.x-sin(angle)*p.y,sin(angle)*p.x+cos(angle)*p.y);
                float3 ro=float3(0.12*sin(d.travel*0.3),0,4.1),rd=normalize(float3(q*1.10,-2.8));
                float3 col=mlColor(0.05,u)*(0.025+0.06*exp(-dot(p,p)*1.7));
                // Broad caustic shadows separate the sculpture from its backdrop.
                col+=mlColor(0.56,u)*0.045*exp(-pow(q.x-0.25,2.0)*5.0);
                // Colored filaments orbit behind the sculpture; each listens to its own band.
                for(int j=0;j<5;j++) {
                    float f=float(j), side=j%2==0?-1.0:1.0;
                    float path=side*(0.65+f*0.12)+sin(q.y*(2.3+f*0.15)+d.travel*0.8+f)*(.10+.18*d.bands[j%3]);
                    float dd=abs(q.x-path),width=max(px*1.3,0.009);
                    float packet=pow(.5+.5*sin(q.y*6.0-d.beat*3.14159+f),10.0);
                    col+=mlColor(f*.19,u)*(exp(-dd/width)*.38+exp(-dd/.055)*.045)*(d.energy*.45+packet*(d.snare+.4*d.drop));
                }
                float dist=0.0;float2 hit=float2(1,0);bool found=false;
                for(int i=0;i<56;i++){
                    hit=mlMap(ro+rd*dist,d);if(hit.x<max(0.001,px*dist*0.22)){found=true;break;}
                    dist+=max(hit.x,0.002);if(dist>6.5)break;
                }
                if(found){
                    float3 v=ro+rd*dist;float e=max(0.002,px*dist*0.28);
                    float3 n=normalize(float3(mlMap(v+float3(e,0,0),d).x-mlMap(v-float3(e,0,0),d).x,
                        mlMap(v+float3(0,e,0),d).x-mlMap(v-float3(0,e,0),d).x,
                        mlMap(v+float3(0,0,e),d).x-mlMap(v-float3(0,0,e),d).x));
                    float3 reflection=reflect(rd,n);
                    float strip1=pow(saturate(1.0-abs(reflection.x+0.34)*1.3),8.0);
                    float strip2=pow(saturate(1.0-abs(reflection.y-0.3)*2.2),10.0);
                    float diffuse=max(dot(n,normalize(float3(-0.6,0.7,1.0))),0.0);
                    float fresnel=pow(1.0-max(dot(n,-rd),0.0),3.0);
                    float hue=0.12+hit.y*0.31+v.y*0.055;
                    col=mlColor(hue,u)*(0.20+0.62*diffuse+1.5*strip1);
                    col+=mlColor(hue+0.26,u)*(strip2*1.2+fresnel*0.65);
                    float band=bandAt(spectrum,saturate((v.y+1.65)/3.3));
                    float bead=pow(0.5+0.5*sin(v.y*5.0-d.beat*1.5708+hit.y),18.0);
                    col+=mlColor(0.93,u)*bead*(0.20+0.7*band+0.9*sqrt(saturate(u.env.z))*intensity);
                    // Wavelength-sized folds catch musical light, without changing the whole-frame exposure.
                    float folds=pow(.5+.5*sin(v.y*14.0+d.travel*3.0+hit.y*2.0),10.0);
                    col+=mlColor(hue+.4,u)*folds*(.08+.30*d.snare+.16*d.drop);
                    float ao=saturate(mlMap(v+n*0.17,d).x/0.10)*0.45+0.55;col*=ao;
                }
                col=fxTonemap(fxFlash(col,u,0.10),1.35);
                return float4(saturate(fxVignette(col,p,0.07)),1.0);
            }
            """#
    }
#endif

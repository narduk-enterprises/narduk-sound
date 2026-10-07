#if canImport(Metal)
    /// A little robot dancing between two speakers: it bobs on the beat and its chest shows the spectrum. Promoted from the SoundGallery drop-in plugin `pocket-automaton.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum PocketAutomatonShader {
        static let source = #"""
            // title: Pocket Automaton
            // fragment: pocketAutomatonFragment
            // A ceramic robot dancing on a lit plinth. 56 SDF steps; no texture assets.

            struct PaDrive {float t;float beat;float kick;float snare;float bass;float drop;float hat;float energy;float travel;};
            static float3 paColor(float t,constant IntenseUniforms &u){
                t=saturate(t);float3 a=float3(0.035,0.22,0.27),b=float3(0.94,0.34,0.16),c=float3(1.0,0.88,0.61);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                return t<0.5?mix(a,b,t*2.0):mix(b,c,t*2.0-1.0);
            }
            static float paBox(float3 p,float3 b,float r){float3 q=abs(p)-b;return length(max(q,0.0))+min(max(q.x,max(q.y,q.z)),0.0)-r;}
            static float paLink(float3 p,float3 a,float3 b,float r){float3 v=b-a;return length(p-a-v*saturate(dot(p-a,v)/dot(v,v)))-r;}
            static float3 paLocal(float3 p,thread const PaDrive &d){
                p.y-=0.05+0.13*sin(d.beat*3.14159)*d.energy+0.22*d.kick;
                p.x-=0.14*sin(d.beat*1.5708)*d.energy;
                float lean=.19*sin(d.beat*3.14159)*d.energy+.10*d.snare;
                p.xy=float2(cos(lean)*p.x-sin(lean)*p.y,sin(lean)*p.x+cos(lean)*p.y);
                float turn=0.28*sin(d.beat*1.5708)*d.energy+0.12*sin(d.t*0.7);
                return float3(cos(turn)*p.x+sin(turn)*p.z,p.y,-sin(turn)*p.x+cos(turn)*p.z);
            }
            static float3 paHead(float3 p,thread const PaDrive &d){
                p.y-=.55;
                float nod=.18*d.kick-.12*d.bass;
                p.yz=float2(cos(nod)*p.y-sin(nod)*p.z,sin(nod)*p.y+cos(nod)*p.z);
                p.y+=.55;
                return p;
            }
            static float2 paMap(float3 world,thread const PaDrive &d){
                float3 p=paLocal(world,d),h=paHead(p,d);float2 result=float2(100,0);
                float head=paBox(h-float3(0,0.55,0),float3(0.40,0.22,0.22),0.12);
                float torso=paBox(p-float3(0,-0.12,0),float3(0.23+.04*d.bass,0.24,0.16),0.11);
                result=float2(min(head,torso),1);
                float visor=paBox(h-float3(0,0.56,0.265),float3(0.32,0.125,0.018),0.075);
                if(visor<result.x)result=float2(visor,2);
                for(int j=0;j<2;j++){
                    float s=j==0?-1.0:1.0;
                    float eye=length(h-float3(s*0.18,0.59,0.35))-(0.061+0.014*d.hat);
                    if(eye<result.x)result=float2(eye,3);
                    float lift=.45*sin(d.beat*1.5708+s*1.5)*d.energy+.50*d.snare+.55*d.drop;
                    float3 shoulder=float3(s*.34,.04,0),elbow=float3(s*(.51+.12*lift),-.03+.30*lift,.03);
                    float3 hand=float3(s*(.60+.18*lift),-.10+.68*lift,.10+.24*d.snare);
                    float arm=min(paLink(p,shoulder,elbow,.067),paLink(p,elbow,hand,.060));
                    float footY=-0.72+0.17*max(sin(d.beat*3.14159+s*1.5708),0.0)*d.energy;
                    float leg=paLink(p,float3(s*0.16,-0.40,0),float3(s*(0.22+.09*d.bass),footY,0.08),0.075);
                    float foot=paBox(p-float3(s*(0.22+.09*d.bass),footY-0.07,0.10),float3(0.10,0.035,0.13),0.045);
                    float ears=length(h-float3(s*0.52,0.56,0))-0.105;
                    float metal=min(min(arm,leg),min(foot,ears));
                    if(metal<result.x)result=float2(metal,4);
                    float fist=length(p-hand)-0.10;if(fist<result.x)result=float2(fist,1);
                }
                float antenna=paLink(h,float3(0,0.87,0),float3(0.04*sin(d.t),1.06,0),0.018);
                if(antenna<result.x)result=float2(antenna,4);
                float tip=length(h-float3(0.04*sin(d.t),1.08,0))-(0.055+.018*d.hat);
                if(tip<result.x)result=float2(tip,3);
                float plinth=paBox(world-float3(0,-0.96,0),float3(0.83,0.07,0.58),0.08);
                if(plinth<result.x)result=float2(plinth,5);
                // Stationary speaker cabinets give the dancing figure an audible-looking stage.
                for(int j=0;j<2;j++){
                    float s=j==0?-1.0:1.0;
                    float cabinet=paBox(world-float3(s*1.24,-.30,-.48),float3(.25,.53,.15),.055);
                    if(cabinet<result.x)result=float2(cabinet,6);
                    for(int k=0;k<2;k++){
                        float cy=-.57+float(k)*.49;
                        float cone=length(world-float3(s*1.24,cy,-.39-.04*float(k)))-(.19+.047*d.kick);
                        if(cone<result.x)result=float2(cone,7);
                    }
                }
                return result;
            }
            fragment float4 pocketAutomatonFragment(IntenseVertexOut in [[stage_in]],constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]],constant float *wave [[buffer(2)]]){
                float intensity=saturate(u.extra.z),px=2.0/max(u.resTime.y,1.0);
                PaDrive d;d.t=u.resTime.z*(0.3+0.7*intensity);d.beat=u.resTime.w;d.kick=sqrt(saturate(u.env.x))*intensity;
                d.snare=sqrt(saturate(u.env.y))*intensity;d.bass=sqrt(saturate(bandAt(spectrum,0.06)))*intensity;d.drop=u.misc.y*intensity;
                d.hat=sqrt(saturate(u.env.z))*intensity;d.energy=sqrt(saturate(u.wobble.z))*intensity;d.travel=u.misc.z;
                float2 p=(in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                float3 ro=float3(0.40+0.15*sin(d.travel*.18),0.42,4.2),target=float3(0,0.02,0);
                float3 fw=normalize(target-ro),right=normalize(cross(fw,float3(0,1,0))),up=cross(right,fw);
                float3 rd=normalize(fw*2.8+right*p.x+up*p.y);
                float3 col=paColor(0.03,u)*(0.08+0.23*exp(-dot(p,p)*1.4));
                // Stage pools use geometry and steady light rather than a pulsing screen wash.
                col+=paColor(0.5,u)*0.06*exp(-pow(p.x+0.9,2.0)*2.0-pow(p.y+0.5,2.0)*4.0);
                float dist=0;float2 hit=float2(1,0);bool found=false;
                for(int i=0;i<56;i++){
                    hit=paMap(ro+rd*dist,d);if(hit.x<max(0.0015,dist*px*0.25)){found=true;break;}
                    dist+=max(hit.x*0.88,0.002);if(dist>7.0)break;
                }
                if(found){
                    float3 v=ro+rd*dist;float e=max(0.002,dist*px*0.28);
                    float3 n=normalize(float3(paMap(v+float3(e,0,0),d).x-paMap(v-float3(e,0,0),d).x,
                        paMap(v+float3(0,e,0),d).x-paMap(v-float3(0,e,0),d).x,
                        paMap(v+float3(0,0,e),d).x-paMap(v-float3(0,0,e),d).x));
                    float3 light=normalize(float3(-0.65,1,1)),q=paLocal(v,d);
                    float diff=max(dot(n,light),0.0),spec=pow(max(dot(n,normalize(light-rd)),0.0),30.0);
                    float ao=0.55+0.45*saturate(paMap(v+n*0.13,d).x/0.13);
                    float fres=pow(1.0-max(dot(n,-rd),0.0),3.0);
                    float tone=hit.y==4.0?0.5:0.97;
                    col=paColor(tone,u)*(0.17+diff*0.78)*ao+paColor(0.99,u)*spec*0.60+paColor(0.1,u)*fres*0.35;
                    if(hit.y==2.0){
                        col=paColor(0.03,u)*(0.05+spec*0.35);
                        float3 face=paHead(q,d);
                        float smile=abs(face.y-(0.50-0.055*(1.0-pow(face.x/0.16,2.0))));
                        float mouth=(1.0-smoothstep(0.006,0.014,smile))*(1.0-smoothstep(0.12,0.17,abs(face.x)));
                        col+=paColor(0.9,u)*mouth*0.8;
                    }
                    if(hit.y==3.0)col=paColor(0.18,u)*(1.4+1.1*d.hat)+paColor(0.99,u)*spec;
                    if(hit.y==1.0&&q.y<0.2&&q.z>0.20){
                        float2 chest=float2(q.x,q.y+0.10);
                        float badge=1.0-smoothstep(.0,.012,max(abs(chest.x)-.21,abs(chest.y)-.115));
                        float lane=clamp(floor((chest.x+.21)/.084),0.0,4.0);
                        float amp=sqrt(saturate(bandAt(spectrum,lane*.19)))*intensity;
                        float bar=step(abs(fract((chest.x+.21)/.084)-.5),.29)*step(abs(chest.y),.015+.085*amp);
                        col=mix(col,paColor(.04,u)*.10+paColor(.6+lane*.075,u)*bar*1.35,badge);
                    }
                    if(hit.y==6.0){
                        col=paColor(.04,u)*(.15+.35*diff)+paColor(.85,u)*spec*.4;
                        float seam=exp(-pow((abs(v.x)-1.47)/.017,2.0));
                        col+=paColor(.75,u)*seam*(.25+.6*d.hat);
                    }
                    if(hit.y==7.0){
                        float cy=v.y<-.32?-.57:-.08;
                        float rr=length(float2(abs(v.x)-1.24,v.y-cy));
                        float surround=exp(-pow((rr-.145-.02*d.kick)/.014,2.0));
                        float cap=exp(-rr*rr/.003);
                        col=paColor(.06,u)*(.1+.25*diff)+paColor(.82,u)*(surround*(.8+.6*d.kick)+cap*.35);
                    }
                    if(hit.y==5.0){
                        col=paColor(0.07,u)*(0.13+diff*0.24)+paColor(0.9,u)*spec*0.4;
                        float trim=exp(-pow((v.y+0.94)/0.018,2.0));col+=paColor(0.55,u)*trim*0.6;
                    }
                }
                col=fxTonemap(fxFlash(col,u,0.08),1.3);
                return float4(saturate(fxVignette(col,p,0.055)),1.0);
            }
            """#
    }
#endif

#if canImport(Metal)
    /// A vaulted hall rushing past one bay per beat, with spectrum-raised stone blocks and swinging keystones. Promoted from the SoundGallery drop-in plugin `vaulted-engine.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum VaultedEngineShader {
        static let source = #"""
            // title: Vaulted Engine
            // fragment: vaultedEngineFragment
            // Repeating stone-and-brass arcade. 56 conservative SDF steps, no noise in the march.

            struct VeDrive { float time; float beat; float kick; float snare; float bass; float drop; float energy; float travel; float4 bands; };
            static float3 veColor(float t,constant IntenseUniforms &u) {
                t=saturate(t);float3 a=float3(0.025,0.09,0.15),b=float3(0.24,0.43,0.51),c=float3(1.0,0.62,0.20);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                return t<0.5?mix(a,b,t*2.0):mix(b,c,t*2.0-1.0);
            }
            static float veBox(float3 p,float3 b){float3 q=abs(p)-b;return length(max(q,0.0))+min(max(q.x,max(q.y,q.z)),0.0);}
            static float2 veMap(float3 p,thread const VeDrive &d) {
                float spacing=2.4,cell=floor((p.z+spacing*0.5)/spacing);
                float z=p.z-cell*spacing;
                float lane=d.bands[int(abs(cell))%4];
                float opening=1.42+0.44*d.drop+0.20*d.bass+0.14*lane*sin(cell*0.8+d.beat*1.5708);
                float column=veBox(float3(abs(p.x)-opening,p.y-0.65,z),float3(0.16+0.065*lane,1.4,0.18))-0.045;
                float plinth=veBox(float3(abs(p.x)-opening,p.y+0.59,z),float3(0.29,0.16,0.32))-0.03;
                // An upper semicircular arch meets each pair of columns.
                float arch=length(float2(length(float2(p.x,max(p.y-1.5,0.0)))-opening,z))-0.18;
                if(p.y<1.5)arch=1e3;
                float floorD=p.y+0.82;
                float2 hit=float2(min(column,min(plinth,arch)),1.0);
                if(floorD<hit.x)hit=float2(floorD,2.0);
                // Suspended, solid keystones lift on bass; they are not light beams.
                float lift=0.28*sin(d.beat*1.5708+cell*0.6)*d.energy+0.40*d.bass;
                float3 key=float3(p.x,p.y-1.95-lift,z);
                float angle=0.32*d.snare*sin(cell+1.0)+d.travel*0.35;
                key.xz=float2(cos(angle)*key.x-sin(angle)*key.z,sin(angle)*key.x+cos(angle)*key.z);
                float stone=veBox(key,float3(0.29,0.12+0.13*d.kick,0.29))-0.06;
                if(stone<hit.x)hit=float2(stone,3.0);
                // An organ of solid spectrum-driven blocks rises outside the nave.
                float h=0.25+1.15*lane+0.40*d.drop;
                float organ=veBox(float3(abs(p.x)-opening-0.47,p.y+0.79-h,z),float3(0.19,h,0.43))-0.025;
                if(organ<hit.x)hit=float2(organ,4.0);
                return hit;
            }
            fragment float4 vaultedEngineFragment(IntenseVertexOut in [[stage_in]],constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]],constant float *wave [[buffer(2)]]) {
                float intensity=saturate(u.extra.z),px=2.0/max(u.resTime.y,1.0);
                VeDrive d;d.time=u.resTime.z*(0.3+0.7*intensity);d.beat=u.resTime.w;
                d.kick=sqrt(saturate(u.env.x))*intensity;d.snare=sqrt(saturate(u.env.y))*intensity;
                d.bass=sqrt(saturate(bandAt(spectrum,0.08)))*intensity;d.drop=u.misc.y*intensity;
                d.energy=sqrt(saturate(u.wobble.z))*intensity;d.travel=u.misc.z;
                d.bands=sqrt(saturate(float4(bandAt(spectrum,.07),bandAt(spectrum,.25),bandAt(spectrum,.50),bandAt(spectrum,.78))))*intensity;
                float2 uv=(in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                float roll=0.055*sin(d.beat*1.5708)*d.energy;
                uv=float2(cos(roll)*uv.x-sin(roll)*uv.y,sin(roll)*uv.x+cos(roll)*uv.y);
                float3 ro=float3(0.18*sin(d.travel*0.42),0.28+0.11*d.kick,-d.time*0.15-d.travel*1.7-0.38*d.kick);
                float3 rd=normalize(float3(uv.x,uv.y+0.18,-1.5+0.14*d.drop));
                float distance=0.0;float2 hit=float2(1,0);bool found=false;
                for(int i=0;i<56;i++){
                    hit=veMap(ro+rd*distance,d);
                    if(hit.x<max(0.0015,distance*px*0.4)){found=true;break;}
                    distance+=max(hit.x*0.72,0.003);if(distance>35.0)break;
                }
                float3 fog=veColor(0.22,u)*0.065;
                float3 col=fog+veColor(0.95,u)*0.13*exp(-dot(uv-float2(0,0.15),uv-float2(0,0.15))*5.0);
                if(found){
                    float3 p=ro+rd*distance;float e=max(0.002,distance*px*0.3);
                    float3 n=normalize(float3(veMap(p+float3(e,0,0),d).x-veMap(p-float3(e,0,0),d).x,
                        veMap(p+float3(0,e,0),d).x-veMap(p-float3(0,e,0),d).x,
                        veMap(p+float3(0,0,e),d).x-veMap(p-float3(0,0,e),d).x));
                    float3 light=normalize(float3(-0.6,0.9,0.7));float diffuse=max(dot(n,light),0.0);
                    float spec=pow(max(dot(n,normalize(light-rd)),0.0),28.0);
                    float stone=0.8+0.2*fxNoise3(p*8.0);
                    float ao=saturate(veMap(p+n*0.22,d).x/0.22)*0.5+0.5;
                    col=veColor(0.38,u)*(0.12+0.9*diffuse)*stone*ao+veColor(0.95,u)*spec*0.38;
                    float z=fract((p.z+1.2)/2.4)*2.4-1.2;
                    if(hit.y==2.0){
                        float checker=sin(p.x*2.1)*sin(p.z*2.1);
                        float tile=0.6+0.4*smoothstep(-max(fwidth(checker),0.01),max(fwidth(checker),0.01),checker);
                        col=veColor(0.16,u)*(0.12+0.22*tile)+veColor(0.75,u)*spec*0.24;
                        float track=exp(-pow((abs(p.x)-1.13)/max(0.025,px*distance),2.0));
                        float procession=0.4+0.6*pow(0.5+0.5*sin(p.z*2.0+d.beat*3.14159),3.0);
                        col+=veColor(0.96,u)*track*procession*(1.4+0.8*d.kick);
                        col+=veColor(0.75,u)*(0.12+0.18*d.energy)*exp(-p.x*p.x*2.0)*exp(-abs(z)*2.0);
                        float crossbar=exp(-pow((z+1.0-d.snare*2.0)/max(0.06,px*distance),2.0));
                        col+=veColor(0.62,u)*crossbar*d.snare*0.75*exp(-p.x*p.x*.5);
                    }else{
                        float trim=exp(-pow((abs(p.y-0.6)-0.95)/max(0.035,px*distance),2.0));
                        col+=veColor(0.97,u)*trim*(1.1+0.9*sqrt(saturate(u.env.z))*intensity);
                        float cell=floor((p.z+1.2)/2.4),band=bandAt(spectrum,fract(abs(cell)*0.17));
                        float inlay=exp(-pow(z/max(0.025,px*distance),2.0));
                        col+=veColor(0.72,u)*inlay*(0.2+1.8*band+1.0*d.snare);
                        if(hit.y==3.0)col=veColor(0.94,u)*(0.9+diffuse*0.8)+veColor(0.5,u)*spec;
                        if(hit.y==4.0){
                            float stripes=pow(0.5+0.5*sin(p.y*12.0-d.beat*1.5708),5.0);
                            col=veColor(.38+band*.55,u)*(.30+diffuse*.8)+veColor(.95,u)*stripes*(.45+.45*band);
                        }
                    }
                    col=mix(col,fog,1.0-exp(-distance*0.052));
                }
                col=fxTonemap(fxFlash(col,u,0.10),1.4);
                return float4(saturate(fxVignette(col,uv,0.06)),1.0);
            }
            """#
    }
#endif

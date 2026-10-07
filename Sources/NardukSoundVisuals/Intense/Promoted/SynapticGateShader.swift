#if canImport(Metal)
    /// Nerve filaments firing around a pulsing star-shaped gate. Promoted from the SoundGallery drop-in plugin `synaptic-gate.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum SynapticGateShader {
        static let source = #"""
            // title: Synaptic Gate
            // fragment: synapticGateFragment
            // Reference-inspired living aperture: sculpted tissue, branching cyan/amber currents.
            // Analytic height-field normal; no ray march, at most four fBm octaves per sample.

            static float3 sgColor(float t,constant IntenseUniforms &u){
                t=saturate(t);float3 a=float3(0.28,0.095,0.070),b=float3(0.08,0.72,0.78),c=float3(1.0,0.49,0.14);
                if(u.extra.y>0.5){a=u.c0.rgb;b=u.c1.rgb;c=u.c2.rgb;}
                return t<0.5?mix(a,b,t*2.0):mix(b,c,t*2.0-1.0);
            }
            static float sgRadius(float2 p,float t){
                float r=length(p),a=atan2(p.y,p.x);
                return r+0.012*sin(a*5.0+t*0.20)+0.007*sin(a*9.0-t*0.12)+0.009*sin(a*3.0+r*10.0);
            }
            static float sgHeight(float2 p,float t,float aperture){
                float r=sgRadius(p,t),a=atan2(p.y,p.x);
                float torus=sqrt(max(0.0,1.0-pow((r-(aperture+0.33))/0.32,2.0)))*0.29;
                float3 field=float3(cos(a)*4.0,sin(a)*4.0,r*7.0+t*0.08);
                float fibers=fxFbm3(field,4);
                float folds=sin(r*35.0+a*7.0+fibers*9.0)*0.012;
                return torus+(fibers-0.5)*0.14+folds;
            }
            fragment float4 synapticGateFragment(IntenseVertexOut in [[stage_in]],constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]],constant float *wave [[buffer(2)]]){
                float intensity=saturate(u.extra.z),t=u.resTime.z*(0.3+0.7*intensity),px=2.0/max(u.resTime.y,1.0);
                float kick=sqrt(saturate(u.env.x))*intensity,snare=sqrt(saturate(u.env.y))*intensity,hat=sqrt(saturate(u.env.z))*intensity;
                float bass=sqrt(saturate(bandAt(spectrum,0.07)))*intensity,drop=u.misc.y*intensity;
                float energy=sqrt(saturate(u.wobble.z))*intensity,travel=u.misc.z;
                float2 p=(in.uv-0.5)*float2(u.resTime.x/u.resTime.y,-1.0)*2.0;
                p*=1.10-.10*kick-.08*bass;p.x+=0.025*sin(t*0.3);
                float rawRadius=max(length(p),.001),rawAngle=atan2(p.y,p.x);
                float shear=.10*sin(travel*.3)+.23*snare*smoothstep(.3,1.4,rawRadius);
                p=float2(cos(shear)*p.x-sin(shear)*p.y,sin(shear)*p.x+cos(shear)*p.y);
                float pressure=.048*bass*sin(rawAngle*5.0-travel)+.065*snare*exp(-pow((rawRadius-(.42+(1.0-snare)*1.2))/.22,2.0));
                p+=p/rawRadius*pressure;
                float r=sgRadius(p,t),a=atan2(p.y,p.x),aperture=0.34+0.07*bass+0.08*kick+0.13*drop;
                float3 col=sgColor(0.45,u)*0.009;
                float3 field=float3(cos(a)*3.5,sin(a)*3.5,r*5.5-travel*0.45-t*0.04);
                float warp=fxFbm3(field,4);
                float3 branchField=float3(p*5.0,r*2.5)+float3(warp*1.7,warp*2.0,t*0.10);
                float veinNoise=fxFbm3(branchField*2.0,4);
                float veinDistance=abs(veinNoise-0.46);
                float width=max(fwidth(veinNoise)*0.55,0.0025);
                float veins=1.0-smoothstep(width,width*2.3,veinDistance);
                float glow=exp(-veinDistance*37.0);
                float outside=smoothstep(aperture,aperture+0.045,r);
                float body=outside*(1.0-smoothstep(aperture+0.55,aperture+0.78,r));
                if(body>0.001){
                    float h=sgHeight(p,t,aperture),e=max(px*1.5,0.003);
                    float3 n=normalize(float3(-(sgHeight(p+float2(e,0),t,aperture)-h)/e,
                                              -(sgHeight(p+float2(0,e),t,aperture)-h)/e,1.0));
                    float3 light=normalize(float3(-0.7,0.7,0.8));
                    float diff=max(dot(n,light),0.0);
                    float spec=pow(max(dot(n,normalize(light+float3(0,0,1))),0.0),32.0);
                    float tissue=fxFbm3(float3(p*14.0,h*8.0+t*0.05),3);
                    float3 flesh=sgColor(0.0,u)*(0.13+diff*0.58)*(0.65+tissue*0.7);
                    flesh+=sgColor(0.32,u)*spec*0.42;
                    float cleft=0.5+0.5*sin(r*29.0+a*8.0+warp*12.0);
                    flesh*=0.6+0.4*cleft;
                    col=mix(col,flesh,body);
                }
                // Uneven branching networks extend beyond the fleshy lip into deep space.
                float tendril=pow(0.5+0.5*sin(a*8.0+r*3.0+warp*10.0),6.0);
                float reach=outside*exp(-max(r-aperture-0.35,0.0)*2.9);
                float route=0.5+0.5*sin(a*3.0+warp*7.0);
                float3 current=sgColor(mix(0.48,0.98,smoothstep(0.4,0.65,route)),u);
                float band=bandAt(spectrum,abs(sin(a*0.5)));
                float signal=pow(0.5+0.5*sin(r*9.0-u.resTime.w*6.2831853+warp*4.0),8.0);
                float pulse=0.25+0.65*sqrt(saturate(band))+signal*(0.8+1.2*snare);
                col+=current*reach*(veins*(0.10+0.30*tendril)*pulse+glow*0.035);
                // Fourteen rooted bundles split into daughter fibers as they leave the lip.
                // Widths are in screen space, with a 1.2-pixel floor at every resolution.
                float sectors=(a+3.14159265)*14.0/6.2831853;
                float sector=floor(sectors),local=fract(sectors)-0.5;
                float seed=hash11(sector+8.0);
                float sectorBand=sqrt(saturate(bandAt(spectrum,seed*.9)))*intensity;
                float bend=(.11+.14*sectorBand)*sin(r*7.0+seed*15.0-travel*.5)+(.04+.09*snare)*sin(r*17.0+seed*9.0+t*.12);
                float split=smoothstep(aperture+0.1,aperture+0.9,r)*(0.12+seed*0.17+.18*sectorBand+.12*drop);
                float dd=min(abs(local-bend),min(abs(local-bend-split),abs(local-bend+split)))*r*0.4488;
                float wireWidth=max(px*1.32,0.0045+.003*kick);
                float wire=exp(-pow(dd/wireWidth,2.0));
                float sheath=exp(-pow(dd/(wireWidth*3.2),2.0));
                float rootMask=smoothstep(aperture+0.05,aperture+0.16,r)*exp(-max(r-0.90,0.0)*2.2);
                float currentFlow=0.5+0.5*pow(0.5+0.5*sin(r*7.0-u.resTime.w*6.2831853+seed*9.0),6.0);
                float3 wireColor=sgColor(seed>0.46?0.48:0.97,u);
                col*=1.0-0.34*sheath*rootMask;
                col+=wireColor*rootMask*(wire*(0.32+currentFlow*(1.5+sectorBand)+snare*.65)+sheath*(.09+.12*kick));
                // Small hat-driven nodes sit on veins; they never brighten the whole frame.
                float nodes=smoothstep(0.70,0.83,fxNoise3(branchField*6.0));
                col+=sgColor(0.98,u)*nodes*veins*reach*hat*1.7;
                float lip=exp(-pow((r-aperture-0.025)/0.04,2.0));
                col+=sgColor(0.98,u)*lip*(0.11+0.10*warp);
                // Preserve the deep, slightly textured aperture instead of a flat black disc.
                col*=0.10+0.90*smoothstep(aperture-0.018,aperture+0.04,r);
                // The drop exposes a layered throat inside the formerly closed dark aperture.
                if(drop>.01 && r<aperture){
                    for(int layer=0;layer<4;layer++){
                        float f=float(layer),rr=aperture*pow(.62,f+1.0);
                        float wobble=rr*(1.0+.055*sin(a*5.0+travel*.6+f));
                        float edge=exp(-pow((r-wobble)/max(px*1.4,rr*.06),2.0));
                        float nerve=.3+.7*pow(.5+.5*sin(a*9.0+travel+f),5.0);
                        col+=sgColor(.28+f*.2,u)*edge*nerve*drop*.35;
                    }
                }
                col=fxTonemap(fxFlash(col,u,0.06),1.65);
                return float4(saturate(fxVignette(col,p,0.07)),1.0);
            }
            """#
    }
#endif

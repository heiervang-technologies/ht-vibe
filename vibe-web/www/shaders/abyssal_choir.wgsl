// abyssal_choir.wgsl — a procession of translucent deep-sea singers.
// Bass lifts the bells, mids conduct the tentacles, treble wakes marine snow.
// Mouse changes the current; click releases a sonar pulse.

const TAU: f32 = 6.28318530718;

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p); let f = fract(p); let u = f*f*(3.0-2.0*f);
    return mix(mix(hash21(i), hash21(i+vec2<f32>(1.0,0.0)), u.x),
               mix(hash21(i+vec2<f32>(0.0,1.0)), hash21(i+vec2<f32>(1.0,1.0)), u.x), u.y);
}

fn sd_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p-a; let ba = b-a;
    let h = clamp(dot(pa,ba)/(dot(ba,ba)+0.0001),0.0,1.0);
    return length(pa-ba*h);
}

fn freq_at(x: f32) -> f32 {
    let n=arrayLength(&freqs); let u=clamp(x,0.0,0.999);
    return min(freqs[min(u32(u*f32(n)),n-1u)],1.5);
}

@fragment
fn main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let uv=(frag.xy-iResolution*0.5)/min(iResolution.x,iResolution.y);
    let suv=frag.xy/iResolution;
    let c1=iColors.color1.xyz; let c2=iColors.color2.xyz;
    let c3=iColors.color3.xyz; let c4=iColors.color4.xyz;
    let n=arrayLength(&freqs);
    let bass=(freqs[0]+freqs[min(1u,n-1u)]+freqs[min(2u,n-1u)]+freqs[min(3u,n-1u)])*.25;
    let mids=freqs[n/2u]; let treb=freqs[n-1u];

    // Deep water, moving caustic shafts, and a remote bioluminescent horizon.
    var col=mix(c1*.025,c2*.075,clamp(suv.y,0.0,1.0));
    let current=(iMouse.x-.5)*.18;
    for(var k:i32=0;k<5;k=k+1){
        let fk=f32(k);
        let x=-.75+fk*.37+sin(iTime*.08+fk*2.1)*.08;
        let ray=exp(-abs(uv.x-x-current*uv.y)*12.0)*smoothstep(-.55,.5,uv.y);
        col+=mix(c2,c3,fk*.18)*ray*(.018+mids*.018);
    }
    let haze=noise2(uv*3.2+vec2<f32>(iTime*.025,-iTime*.018));
    col+=mix(c2,c3,.5)*pow(haze,4.0)*.055;

    // Back-to-front jellyfish. Every singer owns a different frequency slice.
    for(var j:i32=0;j<8;j=j+1){
        let fj=f32(j); let seed=hash21(vec2<f32>(fj,17.3));
        let depth=.45+.55*hash21(vec2<f32>(fj,8.1));
        let scale=mix(.38,.82,depth);
        let band=freq_at(fract(fj*.173));
        let rise=fract(seed+iTime*(.018+.012*depth)+band*.025);
        var center=vec2<f32>(mix(-.72,.72,hash21(vec2<f32>(fj,2.7))),-.78+rise*1.62);
        center.x+=sin(iTime*.16+fj*2.3+center.y*2.0)*(.045+.035*depth)+current*(center.y+.3);
        center.y+=sin(iTime*.7+fj)*.018+bass*.025;
        var p=(uv-center)/(scale*.42);
        p.x+=sin(p.y*1.8+iTime*.7+fj)*.025*(1.0+mids);

        // Bell: translucent filled dome with hot scalloped rim and internal veins.
        let bellShape=length(vec2<f32>(p.x,p.y*1.12))-0.32;
        let bellMask=smoothstep(.025,-.02,bellShape)*smoothstep(.17,.04,p.y);
        let cut=smoothstep(.045,-.015,abs(p.y-.075)-(.015+.018*cos(p.x*28.0+fj)));
        let rim=exp(-abs(bellShape)*85.0)*smoothstep(.2,-.02,p.y);
        let lip=exp(-abs(p.y-.075-.014*sin(p.x*30.0))*100.0)*smoothstep(.34,.18,abs(p.x));
        let veins=pow(.5+.5*cos(atan2(p.y+.02,p.x)*9.0+fj),16.0)*bellMask;
        let body=bellMask*(.06+.13*depth)+rim*.32+lip*.25;
        col+=mix(c3,c4,.25+band*.45)*body*(.7+band);
        col+=(c4+vec3<f32>(.18))*veins*.13*(1.0+band);
        col+=mix(c2,c3,.6)*cut*.025;

        // Five long, individually curling tentacles.
        for(var t:i32=0;t<5;t=t+1){
            let ft=f32(t); let root=(ft-2.0)*.095;
            let yy=clamp((.08-p.y)/.86,0.0,1.0);
            let wave=sin(yy*7.0+iTime*(.8+.18*seed)+fj+ft)*(.035+.045*yy)*(1.0+mids*.7);
            let wave2=sin(yy*15.0-iTime*.37+ft*2.0)*.014*yy;
            let tx=root+wave+wave2;
            let d=abs(p.x-tx);
            let mask=smoothstep(.09,.13,p.y)*smoothstep(-.82,-.7,p.y);
            let thread=exp(-d*d*4200.0)*mask*(1.0-yy*.42);
            let halo=exp(-d*d*310.0)*mask*.11;
            col+=mix(c3,c4,ft*.18)*(thread*.7+halo)*(.4+band*.8);
        }
    }

    // Marine snow uses stable cells so it drifts instead of flickering.
    for(var layer:i32=0;layer<3;layer=layer+1){
        let fl=f32(layer); let sc=42.0+fl*31.0;
        let gp=uv*sc+vec2<f32>(iTime*(.12+fl*.05),-iTime*(.65+fl*.2));
        let id=floor(gp); let f=fract(gp)-.5; let h=hash21(id+fl*41.0);
        if(h>.925){
            let d=length(f-vec2<f32>(hash21(id+2.0)-.5,hash21(id+7.0)-.5));
            col+=(c4+vec3<f32>(.2))*smoothstep(.07,.0,d)*(.15+treb*.65);
        }
    }

    if(iMouseClick.z>0.0){
        let age=iTime-iMouseClick.z;
        let cp=(iMouseClick.xy-.5)*vec2<f32>(iResolution.x,iResolution.y)/min(iResolution.x,iResolution.y);
        let ring=exp(-abs(length(uv-cp)-age*.34)*90.0)*exp(-age*.75);
        col+=mix(c3,c4,.6)*ring*1.3;
    }
    col*=1.0-smoothstep(.35,1.0,length(uv))*.48;
    col=vec3<f32>(1.0)-exp(-col*1.55);
    col=pow(max(col,vec3<f32>(0.0)),vec3<f32>(.88));
    return vec4<f32>(col,1.0);
}

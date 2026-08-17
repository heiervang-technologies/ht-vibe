// infinite_reliquary.wgsl — an impossible stained-glass geometry with no center.
// Pure 2D inversion/folding: a hyperbolic tunnel that rebuilds itself to music.

const TAU:f32=6.28318530718;
fn rot(p:vec2<f32>,a:f32)->vec2<f32>{let c=cos(a);let s=sin(a);return vec2<f32>(c*p.x-s*p.y,s*p.x+c*p.y);}
fn hash21(p:vec2<f32>)->f32{return fract(sin(dot(p,vec2<f32>(127.1,311.7)))*43758.5453);}

@fragment fn main(@builtin(position) frag:vec4<f32>)->@location(0) vec4<f32>{
    let uv=(frag.xy-iResolution*.5)/min(iResolution.x,iResolution.y);
    let c1=iColors.color1.xyz;let c2=iColors.color2.xyz;let c3=iColors.color3.xyz;let c4=iColors.color4.xyz;
    let n=arrayLength(&freqs);let bass=(freqs[0]+freqs[min(1u,n-1u)]+freqs[min(2u,n-1u)])*.333;let mids=freqs[n/2u];let treb=freqs[n-1u];
    var click=0.0;if(iMouseClick.z>0.0){let age=iTime-iMouseClick.z;click=exp(-age*.9)*sin(age*7.0);}
    let mouse=(iMouse-.5)*.22;
    var p=uv*1.32+mouse;var scale=1.0;var trap=10.0;var edge=10.0;var orbit=0.0;var cell=0.0;
    let spin=iTime*(.055+mids*.012)+click*.08;
    // Repeated circle inversions create genuine nested non-Euclidean motion.
    for(var i:i32=0;i<10;i=i+1){let fi=f32(i);
        p=rot(p,spin*(select(1.0,-1.0,(i%2)==1))+.17*sin(fi*2.3));
        p=abs(p)-vec2<f32>(.34+.025*sin(iTime*.2+fi),.27+.02*cos(iTime*.17+fi));
        if(p.x<p.y){p=p.yx;}
        let d=max(dot(p,p),.055);p=p/d-vec2<f32>(.82+.025*bass,.18*sin(iTime*.13+fi));
        scale*=d;trap=min(trap,length(p)/max(scale,.0001));
        edge=min(edge,abs(abs(p.x)-abs(p.y))/max(scale,.0001));
        orbit+=exp(-abs(length(p)-.72)*15.0)/(1.0+fi*.35);
        cell+=atan2(p.y,p.x)*(.04+fi*.003);
    }
    let radial=length(uv);let angle=atan2(uv.y,uv.x);
    let glass=sin(cell*7.0-log(max(trap,.00001))*2.4+iTime*.12);
    let tone=.5+.5*glass;var glass_col=mix(c2,c3,tone);glass_col=mix(glass_col,c4,.5+.5*sin(cell*3.0+orbit));
    let lead=exp(-edge*240.0)+exp(-trap*95.0);
    let facets=.72+.28*sin(log(max(trap,.00001))*18.0+angle*6.0);
    var col=c1*.035+glass_col*(.12+.22*facets)+c1*lead*.7;
    col+=(c4+vec3<f32>(.22))*lead*(.16+treb*.32);
    // Cathedral rose window and audio-driven radial lancets.
    let band=min(freqs[min(u32(fract(angle/TAU+.5)*f32(n)),n-1u)],1.5);
    let rose=exp(-abs(radial-(.31+band*.035))*75.0)*pow(.5+.5*cos(angle*24.0),12.0);
    let arch=exp(-abs(fract(-log(max(radial,.002))*2.1+iTime*.08)-.5)*18.0);
    col+=mix(c3,c4,band)*rose*(.3+band*.7)+c2*arch*.025;
    // Sparse motes moving toward the viewer sell infinite depth.
    let z=fract(iTime*.11-log(max(radial,.002))*.8);let sectors=floor(angle/TAU*90.0);
    let mote=step(.93,hash21(vec2<f32>(sectors,floor(z*18.0))))*exp(-abs(fract(z*18.0)-.5)*28.0);
    col+=(c4+vec3<f32>(.25))*mote*pow(1.0-radial,3.0)*(.08+treb*.3);
    col*=1.0-smoothstep(.38,1.0,radial)*.55;col=vec3<f32>(1.0)-exp(-col*1.75);
    let grain=hash21(floor(frag.xy)+fract(iTime)*91.0)-.5;col+=grain*.01;
    return vec4<f32>(pow(max(col,vec3<f32>(0.0)),vec3<f32>(.88)),1.0);
}

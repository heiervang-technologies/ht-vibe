// paper_moon.wgsl — a quiet hand-cut world with musical weather.
// A deliberately flat, tactile counterpoint to Vibe's 3D spectacle.

fn hash21(p:vec2<f32>)->f32{return fract(sin(dot(p,vec2<f32>(127.1,311.7)))*43758.5453);}
fn noise2(p:vec2<f32>)->f32{let i=floor(p);let f=fract(p);let u=f*f*(3.0-2.0*f);return mix(mix(hash21(i),hash21(i+vec2<f32>(1.0,0.0)),u.x),mix(hash21(i+vec2<f32>(0.0,1.0)),hash21(i+vec2<f32>(1.0,1.0)),u.x),u.y);}
fn mountain(x:f32,seed:f32,rough:f32)->f32{
    var y=sin(x*.7+seed)*.16+sin(x*1.7+seed*2.1)*.075;
    y+=sin(x*3.9+seed*.7)*.035*rough+sin(x*8.3+seed)*.016*rough;return y;
}

@fragment fn main(@builtin(position) frag:vec4<f32>)->@location(0) vec4<f32>{
    let uv=(frag.xy-iResolution*.5)/min(iResolution.x,iResolution.y);let suv=frag.xy/iResolution;
    let c1=iColors.color1.xyz;let c2=iColors.color2.xyz;let c3=iColors.color3.xyz;let c4=iColors.color4.xyz;
    let n=arrayLength(&freqs);let bass=(freqs[0]+freqs[min(1u,n-1u)]+freqs[min(2u,n-1u)])*.333;let mids=freqs[n/2u];let treb=freqs[n-1u];
    let par=(iMouse-.5)*vec2<f32>(.09,.055);
    var col=mix(c1*.12,mix(c2,c3,.32)*.28,smoothstep(0.0,1.0,suv.y));
    // Fibrous paper grain and faint horizontal deckle lines.
    let fiber=noise2(frag.xy*vec2<f32>(.035,.17))+noise2(frag.yx*.009);
    col*=.91+fiber*.12;col+=c2*.018*sin(frag.y*.38);

    // Oversized moon with layered paper craters.
    let moon_pos=vec2<f32>(.24,.20)+par*.25;let mp=uv-moon_pos;let md=length(mp);
    let moon=smoothstep(.245,.238,md);let moon_rim=smoothstep(.26,.235,md)-smoothstep(.242,.225,md);
    let moon_tex=noise2(mp*18.0)+.5*noise2(mp*43.0);
    col=mix(col,mix(c3,c4,.23+moon_tex*.18)*(.72+moon_tex*.12),moon);
    col+=c4*moon_rim*.23;
    for(var cr:i32=0;cr<7;cr=cr+1){let fc=f32(cr);let a=hash21(vec2<f32>(fc,2.0))*6.283;let rr=hash21(vec2<f32>(fc,9.0))*.16;
        let cp=vec2<f32>(cos(a),sin(a))*rr;let sz=.012+hash21(vec2<f32>(fc,4.0))*.026;
        let crater=smoothstep(sz,sz*.72,length(mp-cp))*moon;col=mix(col,col*.72,crater*.16);}

    // Thin musical aurora, printed like translucent ink behind the hills.
    for(var a:i32=0;a<4;a=a+1){let fa=f32(a);let y=.22+fa*.045+sin(uv.x*(2.0+fa*.7)+iTime*(.12+fa*.02))* (.035+mids*.035);
        let ink=exp(-abs(uv.y-y)*38.0)*smoothstep(.5,-.75,uv.x);col+=mix(c3,c4,fa*.23)*ink*(.018+mids*.035);}

    // Five torn-paper mountain layers with independent parallax.
    for(var l:i32=0;l<5;l=l+1){let fl=f32(l);let depth=fl/4.0;let x=(uv.x+par.x*(1.0-depth))* (2.0+depth*.9);
        let ridge=-.08-depth*.105+mountain(x,fl*2.71,1.0-depth*.35)+bass*.018*(1.0-depth);
        let mask=smoothstep(.012,-.008,uv.y-ridge);let layer=mix(c2,c1,depth*.62)*(.72+depth*.11);
        let edge=exp(-abs(uv.y-ridge)*105.0);col=mix(col,layer,mask);col+=mix(c3,c4,.2)*edge*(.035+.02*(1.0-depth));}

    // A reflective river cut into the foreground.
    let river_center=sin(uv.y*8.0+iTime*.08)*.035;let river_width=.035+(-uv.y+.5)*.18;
    let river=smoothstep(river_width,river_width*.72,abs(uv.x-river_center))*smoothstep(.04,-.42,uv.y);
    let ripple=pow(.5+.5*sin(uv.y*115.0+iTime*1.2+uv.x*14.0),18.0)*river;
    col=mix(col,mix(c1,c3,.3),river*.72);col+=c4*ripple*(.06+bass*.12);

    // Fireflies and falling paper flecks.
    for(var i:i32=0;i<22;i=i+1){let fi=f32(i);let h=hash21(vec2<f32>(fi,3.7));var p=vec2<f32>(mix(-.75,.75,h),mix(-.28,.3,hash21(vec2<f32>(fi,8.2))));
        p+=vec2<f32>(sin(iTime*(.18+h*.2)+fi)*.035,cos(iTime*(.13+h*.1)+fi*2.0)*.025);
        let glow=exp(-length(uv-p)*95.0)*(smoothstep(.35,.0,abs(p.y)))*(.25+treb*.8);col+=(c4+vec3<f32>(.15))*glow;}

    // Click draws a single shooting star across the paper sky.
    if(iMouseClick.z>0.0){let age=iTime-iMouseClick.z;let head=vec2<f32>(-.7+age*.72,.42-age*.2);let d=length(uv-head);
        let tail=exp(-abs((uv.y-head.y)+(uv.x-head.x)*.28)*110.0)*smoothstep(head.x-.42,head.x,uv.x)*smoothstep(head.x+.02,head.x,uv.x);
        col+=(c4+vec3<f32>(.25))*(exp(-d*80.0)+tail*.45)*exp(-age*.45);}
    col*=1.0-smoothstep(.48,1.05,length(uv))*.34;col=pow(max(col,vec3<f32>(0.0)),vec3<f32>(.93));
    return vec4<f32>(col,1.0);
}

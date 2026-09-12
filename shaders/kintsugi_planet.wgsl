// kintsugi_planet.wgsl — a broken ceramic world repaired by living light.
// Analytic sphere rendering: crisp, fast, and unlike the raymarched pieces.

const PI:f32=3.14159265359;const TAU:f32=6.28318530718;
fn hash21(p:vec2<f32>)->f32{return fract(sin(dot(p,vec2<f32>(127.1,311.7)))*43758.5453);}
fn rot(p:vec2<f32>,a:f32)->vec2<f32>{let c=cos(a);let s=sin(a);return vec2<f32>(c*p.x-s*p.y,s*p.x+c*p.y);}

fn voronoi_edge(p:vec2<f32>)->f32{
    let cell=floor(p);let f=fract(p);var f1=10.0;var f2=10.0;
    for(var y:i32=-1;y<=1;y=y+1){for(var x:i32=-1;x<=1;x=x+1){let g=vec2<f32>(f32(x),f32(y));
        let o=vec2<f32>(hash21(cell+g),hash21(cell+g+19.7));let d=length(g+o-f);
        if(d<f1){f2=f1;f1=d;}else if(d<f2){f2=d;}}}return f2-f1;
}

fn stars(rd:vec3<f32>,c1:vec3<f32>,c3:vec3<f32>,c4:vec3<f32>,treb:f32)->vec3<f32>{
    let sky=vec2<f32>(atan2(rd.z,rd.x),asin(clamp(rd.y,-1.0,1.0)));
    let id=floor(sky*vec2<f32>(150.0,190.0));let h=hash21(id);let st=step(.988,h)*pow(hash21(id+4.0),7.0);
    let neb=pow(.5+.5*sin(sky.x*3.0+sin(sky.y*7.0)+iTime*.035),8.0)*exp(-abs(sky.y)*2.5);
    return c1*.025+c3*neb*.035+(c4+vec3<f32>(.3))*st*(.4+treb);
}

@fragment fn main(@builtin(position) frag:vec4<f32>)->@location(0) vec4<f32>{
    let uv=(frag.xy-iResolution*.5)/min(iResolution.x,iResolution.y);
    let c1=iColors.color1.xyz;let c2=iColors.color2.xyz;let c3=iColors.color3.xyz;let c4=iColors.color4.xyz;
    let n=arrayLength(&freqs);let bass=(freqs[0]+freqs[min(1u,n-1u)]+freqs[min(2u,n-1u)])*.333;let mids=freqs[n/2u];let treb=freqs[n-1u];
    let mouse=(iMouse-.5)*2.0;let ro=vec3<f32>(0.0,0.0,3.0);let rd=normalize(vec3<f32>(uv,-1.65));
    var col=stars(rd,c1,c3,c4,treb);

    // Back half of a dusty planetary ring, then the ceramic globe, then front half.
    let plane_n=normalize(vec3<f32>(.18,1.0,.36));let denom=dot(rd,plane_n);let tp=-dot(ro,plane_n)/denom;
    let ring_p=ro+rd*tp;let ring_r=length(ring_p);let ring_mask=smoothstep(1.48,1.39,ring_r)*smoothstep(.92,1.0,ring_r);
    let ring_lines=.55+.45*sin(ring_r*150.0+sin(atan2(ring_p.z,ring_p.x)*9.0));
    if(tp>0.0){col+=mix(c2,c4,.35)*ring_mask*(.035+.07*ring_lines)*(select(.45,1.0,ring_p.z<0.0));}

    let oc=ro;let b=dot(oc,rd);let cc=dot(oc,oc)-.82*.82;let disc=b*b-cc;
    if(disc>0.0){let t=-b-sqrt(disc);let p=ro+rd*t;var nor=normalize(p);
        let nxz=rot(nor.xz,iTime*.045+mouse.x*.7);nor=vec3<f32>(nxz.x,nor.y,nxz.y);
        let nyz=rot(nor.yz,-mouse.y*.35);nor=vec3<f32>(nor.x,nyz.x,nyz.y);
        let lon=atan2(nor.z,nor.x)/TAU+.5;let lat=asin(clamp(nor.y,-1.0,1.0))/PI+.5;
        let sphere_uv=vec2<f32>(lon,lat);
        let edge1=voronoi_edge(sphere_uv*vec2<f32>(13.0,8.0)+vec2<f32>(iTime*.012,0.0));
        let edge2=voronoi_edge(sphere_uv*vec2<f32>(25.0,15.0)+7.3);
        let crack=max(smoothstep(.085,.018,edge1),smoothstep(.045,.008,edge2)*.52);
        let pulse=.55+.45*sin(iTime*2.0-lat*18.0+lon*9.0+bass*4.0);
        var surge=0.0;if(iMouseClick.z>0.0){let age=iTime-iMouseClick.z;surge=exp(-age*1.2)*(.5+.5*sin(age*13.0));}
        let gold=crack*(.45+pulse*(.45+bass*.55)+surge);
        let light=normalize(vec3<f32>(-.7,.85,.45));let diff=.18+.82*max(dot(normalize(p),light),0.0);
        let fres=pow(1.0-max(dot(normalize(p),-rd),0.0),3.0);let ceramic=mix(c2,c3,.22+.16*sin(lat*22.0))*diff;
        let spec=pow(max(dot(reflect(-light,normalize(p)),-rd),0.0),64.0);
        col=ceramic*(1.0-crack*.72)+mix(c3,c4+vec3<f32>(.25),.7)*gold+vec3<f32>(1.0)*spec*.55+c4*fres*.16;
        // Thin atmosphere separates the silhouette from space.
        col+=mix(c3,c4,.55)*fres*(.12+mids*.18);
    }
    // Front ring veil.
    if(tp>0.0&&ring_p.z>=0.0){col+=mix(c2,c4,.35)*ring_mask*(.025+.065*ring_lines);}
    let halo=exp(-abs(length(uv)-.5)*18.0);col+=c3*halo*(.012+mids*.025);
    col*=1.0-smoothstep(.45,1.0,length(uv))*.42;col=(col*(2.51*col+vec3<f32>(.03)))/(col*(2.43*col+vec3<f32>(.59))+vec3<f32>(.14));
    return vec4<f32>(pow(max(col,vec3<f32>(0.0)),vec3<f32>(.9)),1.0);
}

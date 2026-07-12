// ferrofluid_oracle.wgsl — a glossy magnetic intelligence forming from sound.
// Bass grows the spikes, mids rotate the field, treble flashes the metal.

const FAR:f32=10.0; const STEPS:i32=84;
fn rot(p:vec2<f32>,a:f32)->vec2<f32>{let c=cos(a);let s=sin(a);return vec2<f32>(c*p.x-s*p.y,s*p.x+c*p.y);}
fn hash21(p:vec2<f32>)->f32{return fract(sin(dot(p,vec2<f32>(127.1,311.7)))*43758.5453);}

fn field_shape(pin:vec3<f32>,bass:f32,mids:f32,impulse:f32)->vec2<f32>{
    var p=pin;
    let xz=rot(p.xz,iTime*.13+(iMouse.x-.5)*.7); p=vec3<f32>(xz.x,p.y,xz.y);
    let yz=rot(p.yz,sin(iTime*.11)*.22); p=vec3<f32>(p.x,yz.x,yz.y);
    let r=max(length(p),.0001); let n=p/r;
    let magnetic=pow(abs(sin(n.x*11.0+iTime*.5)*sin(n.y*13.0-iTime*.37)*sin(n.z*9.0+iTime*.29)),5.0);
    let ridges=pow(.5+.5*cos(atan2(n.z,n.x)*16.0+n.y*8.0+iTime*(.5+mids*.3)),12.0);
    let radius=.72+magnetic*(.20+bass*.24)+ridges*.055+impulse*.09*sin(n.y*18.0);
    var d=r-radius;
    // Liquid droplets being pulled back toward the main body.
    for(var i:i32=0;i<3;i=i+1){
        let fi=f32(i); var q=p;
        let a=iTime*(.35+fi*.07)+fi*2.094;
        let center=vec3<f32>(cos(a)*(1.02+fi*.1),sin(a*1.3)*.48,sin(a)*(1.02+fi*.1));
        let drop=length(q-center)-(.075+.025*sin(iTime+fi));
        let k=.16; let h=clamp(.5+.5*(drop-d)/k,0.0,1.0);
        d=mix(drop,d,h)-k*h*(1.0-h);
    }
    return vec2<f32>(d,magnetic+ridges*.35);
}

fn normal_at(p:vec3<f32>,b:f32,m:f32,im:f32)->vec3<f32>{
    let e=.0015; let h=vec2<f32>(e,-e);
    return normalize(h.xyy*field_shape(p+h.xyy,b,m,im).x+h.yyx*field_shape(p+h.yyx,b,m,im).x+
                     h.yxy*field_shape(p+h.yxy,b,m,im).x+h.xxx*field_shape(p+h.xxx,b,m,im).x);
}

fn environment(rd:vec3<f32>,c1:vec3<f32>,c2:vec3<f32>,c3:vec3<f32>,c4:vec3<f32>,treb:f32)->vec3<f32>{
    let horizon=pow(1.0-abs(rd.y),7.0);
    var col=c1*.025+mix(c2,c3,.45)*horizon*.32;
    let a=atan2(rd.z,rd.x); let bands=pow(.5+.5*sin(a*7.0+rd.y*12.0+iTime*.13),18.0);
    col+=mix(c3,c4,.5+.5*sin(a))*bands*.18;
    let star=hash21(floor(vec2<f32>(a,asin(clamp(rd.y,-1.0,1.0)))*110.0));
    col+=(c4+vec3<f32>(.35))*step(.993,star)*(.35+treb);
    return col;
}

@fragment fn main(@builtin(position) frag:vec4<f32>)->@location(0) vec4<f32>{
    let uv=(frag.xy-iResolution*.5)/min(iResolution.x,iResolution.y);
    let c1=iColors.color1.xyz;let c2=iColors.color2.xyz;let c3=iColors.color3.xyz;let c4=iColors.color4.xyz;
    let n=arrayLength(&freqs);let bass=(freqs[0]+freqs[min(1u,n-1u)]+freqs[min(2u,n-1u)])*.333;
    let mids=freqs[n/2u];let treb=freqs[n-1u];
    var impulse=0.0;if(iMouseClick.z>0.0){let age=iTime-iMouseClick.z;impulse=exp(-age*1.4)*sin(age*8.0);}
    let yaw=iTime*.055+(iMouse.x-.5)*1.0;let pitch=.08-(iMouse.y-.5)*.48;
    var ro=vec3<f32>(0.0,0.0,3.35);let rxz=rot(ro.xz,yaw);ro=vec3<f32>(rxz.x,ro.y,rxz.y);
    let ryz=rot(ro.yz,pitch);ro=vec3<f32>(ro.x,ryz.x,ryz.y);
    let f=normalize(-ro);let r=normalize(cross(f,vec3<f32>(0.0,1.0,0.0)));let u=cross(r,f);
    let rd=normalize(f*1.75+r*uv.x+u*uv.y);
    var col=environment(rd,c1,c2,c3,c4,treb);var travel=0.0;var hit=false;var detail=0.0;var aura=0.0;
    for(var i:i32=0;i<STEPS;i=i+1){let p=ro+rd*travel;let map=field_shape(p,bass,mids,impulse);detail=map.y;
        aura+=.0007/(.002+map.x*map.x);if(map.x<.0015*(1.0+travel*.08)){hit=true;break;}if(travel>FAR){break;}travel+=max(map.x*.67,.004);}
    col+=mix(c3,c4,.55)*min(aura,1.0)*(.04+bass*.035);
    if(hit){let p=ro+rd*travel;let nor=normal_at(p,bass,mids,impulse);let reflected=reflect(rd,nor);
        let env=environment(reflected,c1,c2,c3,c4,treb);let fres=pow(1.0-max(dot(nor,-rd),0.0),3.0);
        let light=normalize(vec3<f32>(-.7,.8,.4));let spec=pow(max(dot(reflect(-light,nor),-rd),0.0),80.0);
        let oil=.5+.5*sin(detail*6.0+nor.y*5.0+iTime*.2);
        let metal=mix(c1*.055,mix(c2,c3,oil)*.34,.28)+env*(.55+fres*.4);
        col=metal+(c4+vec3<f32>(.35))*spec*(1.0+treb)+mix(c3,c4,oil)*fres*.28;
        col=mix(col,environment(rd,c1,c2,c3,c4,treb),1.0-exp(-travel*travel*.012));}
    // Magnetic field-line halo.
    let rr=length(uv);let ang=atan2(uv.y,uv.x);let line=pow(.5+.5*cos(ang*12.0+iTime*.3),18.0)*exp(-abs(rr-.42)*22.0);
    col+=c3*line*(.06+mids*.16);col*=1.0-smoothstep(.45,1.0,length(uv))*.5;
    col=(col*(2.51*col+vec3<f32>(.03)))/(col*(2.43*col+vec3<f32>(.59))+vec3<f32>(.14));
    return vec4<f32>(pow(max(col,vec3<f32>(0.0)),vec3<f32>(.9)),1.0);
}

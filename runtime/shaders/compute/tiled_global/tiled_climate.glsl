#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, r32f) uniform readonly image2D height_in;
layout(set = 0, binding = 1, rg32f) uniform writeonly image2D climate_out;
layout(set = 1, binding = 0, std140) uniform Params {
    uint sample_width; uint sample_height; uint global_width; uint global_height;
    int origin_x; int origin_y; uint seed; uint planet_type;
    float average_temperature; float sea_level; float padding0; float padding1;
} params;
uint hash_u32(uint x){x^=x>>16u;x*=0x7feb352du;x^=x>>15u;x*=0x846ca68bu;x^=x>>16u;return x;}
uint hash_cell(ivec2 c,uint seed,uint channel){uint v=uint(c.x)*73856093u^uint(c.y)*19349663u;v^=seed*83492791u^channel*2654435761u;return hash_u32(v);}
float unit_noise(ivec2 c,uint seed,uint channel){return float(hash_cell(c,seed,channel))/4294967295.0;}
int wrap_x(int x,int w){return (x%w+w)%w;}
float fade(float t){return t*t*(3.0-2.0*t);}
float smooth_noise(ivec2 g,int scale,uint channel){
    scale=max(scale,1); int gw=int(params.global_width),gh=int(params.global_height);
    int cw=max(1,(gw+scale-1)/scale), ch=max(1,(gh+scale-1)/scale);
    int x=g.x/scale,y=g.y/scale; float fx=fade(float(g.x%scale)/float(scale)); float fy=fade(float(g.y%scale)/float(scale));
    ivec2 a=ivec2(wrap_x(x,cw),clamp(y,0,ch-1)),b=ivec2(wrap_x(x+1,cw),clamp(y,0,ch-1));
    ivec2 c=ivec2(wrap_x(x,cw),clamp(y+1,0,ch-1)),d=ivec2(wrap_x(x+1,cw),clamp(y+1,0,ch-1));
    return mix(mix(unit_noise(a,params.seed,channel),unit_noise(b,params.seed,channel),fx),mix(unit_noise(c,params.seed,channel),unit_noise(d,params.seed,channel),fx),fy);
}
void main(){
    ivec2 p=ivec2(gl_GlobalInvocationID.xy); if(p.x>=int(params.sample_width)||p.y>=int(params.sample_height))return;
    int gx=wrap_x(params.origin_x+p.x,int(params.global_width)); int gy=clamp(params.origin_y+p.y,0,int(params.global_height)-1); ivec2 g=ivec2(gx,gy);
    float sin_lat=clamp(1.0-2.0*(float(gy)+0.5)/float(params.global_height),-1.0,1.0);
    float latitude_factor=abs(sin_lat); int broad=max(int(params.global_width)/30,8);
    float moisture=smooth_noise(g,broad,31u), thermal=smooth_noise(g,broad*2,32u); float h=imageLoad(height_in,p).r;
    float temp=params.average_temperature-latitude_factor*52.0-max(h,0.0)*0.0062+(thermal-0.5)*9.0;
    float humidity=clamp(0.18+moisture*0.72-latitude_factor*0.14,0.0,1.0)*clamp(1.0-max(h,0.0)/18000.0,0.35,1.0);
    if(params.planet_type==3u||params.planet_type==5u) humidity=0.0;
    imageStore(climate_out,p,vec4(temp,humidity,0,0));
}

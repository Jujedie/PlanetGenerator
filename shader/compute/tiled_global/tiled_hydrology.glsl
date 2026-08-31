#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, r32f) uniform readonly image2D height_in;
layout(set = 0, binding = 1, rg32f) uniform readonly image2D climate_in;
layout(set = 0, binding = 2, r32f) uniform readonly image2D macro_flux;
layout(set = 0, binding = 3, r8ui) uniform readonly uimage2D macro_direction;
layout(set = 0, binding = 4, r8ui) uniform writeonly uimage2D water_out;
layout(set = 0, binding = 5, r32f) uniform writeonly image2D river_flux_out;
layout(set = 0, binding = 6, r8ui) uniform writeonly uimage2D flow_out;
layout(set = 1, binding = 0, std140) uniform Params {
    uint sample_width; uint sample_height; uint global_width; uint global_height;
    int origin_x; int origin_y; uint macro_width; uint macro_height;
    uint macro_stride; uint planet_type; float sea_level; float macro_max_flux;
} params;
const ivec2 D8[8]=ivec2[8](ivec2(1,0),ivec2(1,1),ivec2(0,1),ivec2(-1,1),ivec2(-1,0),ivec2(-1,-1),ivec2(0,-1),ivec2(1,-1));
int wrap_x(int x,int w){return (x%w+w)%w;}
void main(){
    ivec2 p=ivec2(gl_GlobalInvocationID.xy); int w=int(params.sample_width),h=int(params.sample_height); if(p.x>=w||p.y>=h)return;
    int gx=wrap_x(params.origin_x+p.x,int(params.global_width)); int gy=clamp(params.origin_y+p.y,0,int(params.global_height)-1);
    float my_h=imageLoad(height_in,p).r; uint water=(my_h<params.sea_level && params.planet_type!=3u && params.planet_type!=5u)?1u:0u;
    uint best=255u; float best_h=my_h;
    for(uint d=0u;d<8u;++d){ivec2 q=clamp(p+D8[d],ivec2(0),ivec2(w-1,h-1));float nh=imageLoad(height_in,q).r;if(nh<best_h){best_h=nh;best=d;}}
    int mx=clamp(gx/int(params.macro_stride),0,int(params.macro_width)-1); int my=clamp(gy/int(params.macro_stride),0,int(params.macro_height)-1);
    ivec2 mp=ivec2(mx,my); uint macro_d=imageLoad(macro_direction,mp).r; if(best==255u && macro_d<8u)best=macro_d;
    float mf=imageLoad(macro_flux,mp).r; float humidity=max(imageLoad(climate_in,p).g,0.001);
    float normalized=log2(1.0+mf)/log2(1.0+max(params.macro_max_flux,1.0));
    float local_flux=humidity*(1.0+normalized*1200.0);
    if(water>0u)local_flux=max(local_flux,normalized*1800.0);
    imageStore(water_out,p,uvec4(water,0u,0u,0u)); imageStore(river_flux_out,p,vec4(local_flux,0,0,0)); imageStore(flow_out,p,uvec4(best,0u,0u,0u));
}

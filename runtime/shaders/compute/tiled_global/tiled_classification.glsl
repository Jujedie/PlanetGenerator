#[compute]
#version 450
layout(local_size_x=16,local_size_y=16,local_size_z=1) in;
layout(set=0,binding=0,r32f) uniform readonly image2D height_in;
layout(set=0,binding=1,rg32f) uniform readonly image2D climate_in;
layout(set=0,binding=2,r8ui) uniform readonly uimage2D water_in;
layout(set=0,binding=3,r32f) uniform readonly image2D river_flux_in;
layout(set=0,binding=4,r32ui) uniform writeonly uimage2D biome_out;
layout(set=0,binding=5,r32ui) uniform writeonly uimage2D region_out;
layout(set=0,binding=6,r32ui) uniform writeonly uimage2D ocean_region_out;
layout(set=0,binding=7,rgba8ui) uniform writeonly uimage2D resources_out;
layout(set=1,binding=0,std140) uniform Params{
 uint width;uint height;uint global_width;uint global_height;int origin_x;int origin_y;uint seed;uint planet_type;
 float sea_level;float land_target_cells;float ocean_target_cells;float padding;
}params;
uint hash_u32(uint x){x^=x>>16u;x*=0x7feb352du;x^=x>>15u;x*=0x846ca68bu;x^=x>>16u;return x;}
int wrap_x(int x,int w){return(x%w+w)%w;}
uint admin_id(int gx,int gy,float target,bool ocean){int side=max(1,int(round(sqrt(max(target,1.0)))));int cols=(int(params.global_width)+side-1)/side;uint id=uint((gy/side)*cols+(gx/side));return ocean?(0x80000000u|(id&0x7fffffffu)):id;}
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);if(p.x>=int(params.width)||p.y>=int(params.height))return;int gx=wrap_x(params.origin_x+p.x,int(params.global_width));int gy=clamp(params.origin_y+p.y,0,int(params.global_height)-1);
 float h=imageLoad(height_in,p).r;vec2 c=imageLoad(climate_in,p).rg;uint water=imageLoad(water_in,p).r;float flux=imageLoad(river_flux_in,p).r;uint biome=0u;
 if(water>0u){biome=h<params.sea_level-2500.0?1u:(h<params.sea_level-200.0?2u:3u);}else if(c.x<-10.0)biome=10u;else if(c.y<0.18)biome=11u;else if(c.x>24.0&&c.y>0.65)biome=12u;else if(h>2200.0)biome=13u;else if(flux>450.0)biome=14u;else biome=15u;
 uint land_id=water==0u?admin_id(gx,gy,params.land_target_cells,false):0xffffffffu;uint ocean_id=water>0u?admin_id(gx,gy,params.ocean_target_cells,true):0xffffffffu;
 uint hv=hash_u32(uint(gx)*73856093u^uint(gy)*19349663u^params.seed);uvec4 res=uvec4(hv&255u,(hv>>8u)&255u,(hv>>16u)&255u,(hv>>24u)&255u);
 imageStore(biome_out,p,uvec4(biome,0,0,0));imageStore(region_out,p,uvec4(land_id,0,0,0));imageStore(ocean_region_out,p,uvec4(ocean_id,0,0,0));imageStore(resources_out,p,res);}

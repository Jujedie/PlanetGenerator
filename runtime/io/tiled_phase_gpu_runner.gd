class_name PGTiledPhaseGpuRunner
extends RefCounted

## Small RenderingDevice worker for the maximum-scale tiled path. It owns only
## one tile (+ halo) at a time and shares the application's single local device
## through PGGPUContext. No full-resolution global texture is ever allocated.

const SHADERS := {
	"terrain": "res://addons/planet_generator/runtime/shaders/compute/tiled_global/tiled_terrain.glsl",
	"erosion": "res://addons/planet_generator/runtime/shaders/compute/tiled_global/tiled_erosion.glsl",
	"climate": "res://addons/planet_generator/runtime/shaders/compute/tiled_global/tiled_climate.glsl",
	"hydrology": "res://addons/planet_generator/runtime/shaders/compute/tiled_global/tiled_hydrology.glsl",
	"classification": "res://addons/planet_generator/runtime/shaders/compute/tiled_global/tiled_classification.glsl",
}

var context: PGGPUContext
var rd: RenderingDevice
var params: Dictionary
var _macro_flux: RID
var _macro_direction: RID
var _macro_context: PGGlobalHydrologyContext
var peak_active_bytes := 0
var _cleaned_up := false

func _init(generation_params: Dictionary) -> void:
	params = generation_params.duplicate(true)
	# 1x1 only acquires the already-controlled local RenderingDevice and creates
	# negligible compatibility textures. Tile resources are allocated explicitly.
	context = PGGPUContext.new(Vector2i.ONE)
	if context == null or context.rd == null:
		return
	rd = context.rd
	for shader_name in SHADERS.keys():
		if not context.load_compute_shader(SHADERS[shader_name], shader_name):
			push_error("Unable to load tiled shader: " + shader_name)

func is_ready() -> bool:
	return rd != null and not _cleaned_up and context != null

func set_hydrology_context(macro: PGGlobalHydrologyContext) -> bool:
	_macro_context = macro
	_free_macro_textures()
	if not is_ready() or macro == null:
		return false
	_macro_flux = _create_texture(
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		macro.macro_dimensions, macro.flux_bytes(), 4
	)
	_macro_direction = _create_texture(
		RenderingDevice.DATA_FORMAT_R8_UINT,
		macro.macro_dimensions, macro.direction_bytes(), 1
	)
	return _macro_flux.is_valid() and _macro_direction.is_valid()

func generate_terrain(descriptor: Dictionary, cancel_token: PGGenerationCancelToken) -> Dictionary:
	if cancel_token.is_cancelled() or not is_ready():
		return {}
	var size: Vector2i = descriptor["sample_size"]
	var height := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size, PackedByteArray(), 4)
	var plates := _create_texture(RenderingDevice.DATA_FORMAT_R32_UINT, size, PackedByteArray(), 4)
	if not height.is_valid() or not plates.is_valid():
		_free_many([height, plates])
		return {}
	var texture_set := _uniform_set("terrain", [
		_image_uniform(0, height), _image_uniform(1, plates),
	])
	var ubo := PackedByteArray()
	ubo.resize(48)
	_encode_common_absolute(ubo, descriptor)
	ubo.encode_float(32, float(params.get("sea_level", 0.0)))
	var terrain_scale := float(params.get("terrain_scale", 0.0))
	ubo.encode_float(36, terrain_scale)
	ubo.encode_float(40, float(params.get("planet_radius", 150.0)))
	ubo.encode_float(44, 0.0)
	var param_resources := _parameter_set("terrain", ubo)
	_dispatch("terrain", texture_set, param_resources[0], size)
	context.sync_for_cpu("tiled_terrain_readback")
	var height_data := rd.texture_get_data(height, 0)
	var plate_data := rd.texture_get_data(plates, 0)
	var result := {
		"height_base": _crop_payload(height_data, size, descriptor, 4),
		"plates": _crop_payload(plate_data, size, descriptor, 4),
	}
	_release_dispatch_resources(texture_set, param_resources)
	_free_many([height, plates])
	return result

func erode_height(descriptor: Dictionary, input_height: PackedByteArray,
		iterations: int, cancel_token: PGGenerationCancelToken) -> Dictionary:
	if cancel_token.is_cancelled() or not is_ready(): return {}
	var size: Vector2i = descriptor["sample_size"]
	if input_height.size() != size.x * size.y * 4: return {}
	var a := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size, input_height, 4)
	var b := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size, PackedByteArray(), 4)
	if not a.is_valid() or not b.is_valid():
		_free_many([a,b]); return {}
	var count := maxi(iterations, 0)
	if count == 0:
		var unchanged := _crop_payload(input_height, size, descriptor, 4)
		_free_many([a,b])
		return {"height": unchanged}
	var rate := float(params.get("erosion_rate", 0.05))
	var cell_km := sqrt(maxf(float(params.get("global_cell_area_km2", 1.0)), 0.000001))
	for iteration in range(count):
		if cancel_token.is_cancelled():
			context.sync_for_cpu("tiled_erosion_cancel")
			_free_many([a,b]); return {}
		var src := a if iteration % 2 == 0 else b
		var dst := b if iteration % 2 == 0 else a
		var texture_set := _uniform_set("erosion", [_image_uniform(0, src), _image_uniform(1, dst)])
		var ubo := PackedByteArray(); ubo.resize(32)
		ubo.encode_u32(0, size.x); ubo.encode_u32(4, size.y)
		ubo.encode_u32(8, iteration); ubo.encode_u32(12, count)
		ubo.encode_float(16, rate); ubo.encode_float(20, cell_km)
		ubo.encode_float(24, float(params.get("sea_level", 0.0))); ubo.encode_float(28, 0.0)
		var param_resources := _parameter_set("erosion", ubo)
		_dispatch("erosion", texture_set, param_resources[0], size)
		_release_dispatch_resources(texture_set, param_resources)
	context.sync_for_cpu("tiled_erosion_readback")
	var final_tex := b if count % 2 == 1 else a
	var data := rd.texture_get_data(final_tex, 0)
	var result := {"height": _crop_payload(data, size, descriptor, 4)}
	_free_many([a,b])
	return result

func generate_climate(descriptor: Dictionary, height_data: PackedByteArray,
		cancel_token: PGGenerationCancelToken) -> Dictionary:
	if cancel_token.is_cancelled() or not is_ready(): return {}
	var size: Vector2i = descriptor["sample_size"]
	if height_data.size() != size.x * size.y * 4: return {}
	var height := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT, size, height_data, 4)
	var climate := _create_texture(RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, size, PackedByteArray(), 8)
	if not height.is_valid() or not climate.is_valid(): _free_many([height,climate]); return {}
	var texture_set := _uniform_set("climate", [_image_uniform(0,height), _image_uniform(1,climate)])
	var ubo := PackedByteArray(); ubo.resize(48); _encode_common_absolute(ubo, descriptor)
	ubo.encode_float(32, float(params.get("avg_temperature", 15.0)))
	ubo.encode_float(36, float(params.get("sea_level", 0.0)))
	ubo.encode_float(40, 0.0); ubo.encode_float(44, 0.0)
	var param_resources := _parameter_set("climate", ubo)
	_dispatch("climate", texture_set, param_resources[0], size)
	context.sync_for_cpu("tiled_climate_readback")
	var data := rd.texture_get_data(climate,0)
	var result := {"climate": _crop_payload(data,size,descriptor,8)}
	_release_dispatch_resources(texture_set,param_resources); _free_many([height,climate])
	return result

func generate_hydrology(descriptor: Dictionary, height_data: PackedByteArray,
		climate_data: PackedByteArray, cancel_token: PGGenerationCancelToken) -> Dictionary:
	if cancel_token.is_cancelled() or not is_ready() or _macro_context == null: return {}
	var size: Vector2i = descriptor["sample_size"]
	if height_data.size()!=size.x*size.y*4 or climate_data.size()!=size.x*size.y*8: return {}
	var height := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT,size,height_data,4)
	var climate := _create_texture(RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,size,climate_data,8)
	var water := _create_texture(RenderingDevice.DATA_FORMAT_R8_UINT,size,PackedByteArray(),1)
	var flux := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT,size,PackedByteArray(),4)
	var flow := _create_texture(RenderingDevice.DATA_FORMAT_R8_UINT,size,PackedByteArray(),1)
	if not height.is_valid() or not climate.is_valid() or not water.is_valid() or not flux.is_valid() or not flow.is_valid():
		_free_many([height,climate,water,flux,flow]); return {}
	var texture_set := _uniform_set("hydrology", [
		_image_uniform(0,height),_image_uniform(1,climate),_image_uniform(2,_macro_flux),
		_image_uniform(3,_macro_direction),_image_uniform(4,water),_image_uniform(5,flux),_image_uniform(6,flow),
	])
	var ubo := PackedByteArray(); ubo.resize(48)
	var dims: Vector2i = descriptor["global_dimensions"]; var origin: Vector2i = descriptor["sample_origin"]
	ubo.encode_u32(0,size.x); ubo.encode_u32(4,size.y); ubo.encode_u32(8,dims.x); ubo.encode_u32(12,dims.y)
	ubo.encode_s32(16,origin.x); ubo.encode_s32(20,origin.y)
	ubo.encode_u32(24,_macro_context.macro_dimensions.x); ubo.encode_u32(28,_macro_context.macro_dimensions.y)
	ubo.encode_u32(32,_macro_context.stride); ubo.encode_u32(36,int(params.get("planet_type",0)))
	ubo.encode_float(40,float(params.get("sea_level",0.0))); ubo.encode_float(44,_macro_context.max_flux)
	var param_resources := _parameter_set("hydrology",ubo)
	_dispatch("hydrology",texture_set,param_resources[0],size)
	context.sync_for_cpu("tiled_hydrology_readback")
	var result := {
		"water_mask": _crop_payload(rd.texture_get_data(water,0),size,descriptor,1),
		"river_flux": _crop_payload(rd.texture_get_data(flux,0),size,descriptor,4),
		"flow_direction": _crop_payload(rd.texture_get_data(flow,0),size,descriptor,1),
	}
	_release_dispatch_resources(texture_set,param_resources); _free_many([height,climate,water,flux,flow])
	return result

func generate_classification(descriptor: Dictionary, height_data: PackedByteArray,
		climate_data: PackedByteArray, water_data: PackedByteArray,
		flux_data: PackedByteArray, cancel_token: PGGenerationCancelToken) -> Dictionary:
	if cancel_token.is_cancelled() or not is_ready(): return {}
	var size: Vector2i = descriptor["sample_size"]
	if height_data.size()!=size.x*size.y*4 or climate_data.size()!=size.x*size.y*8 or water_data.size()!=size.x*size.y or flux_data.size()!=size.x*size.y*4: return {}
	var height := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT,size,height_data,4)
	var climate := _create_texture(RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,size,climate_data,8)
	var water := _create_texture(RenderingDevice.DATA_FORMAT_R8_UINT,size,water_data,1)
	var flux := _create_texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT,size,flux_data,4)
	var biome := _create_texture(RenderingDevice.DATA_FORMAT_R32_UINT,size,PackedByteArray(),4)
	var land := _create_texture(RenderingDevice.DATA_FORMAT_R32_UINT,size,PackedByteArray(),4)
	var ocean := _create_texture(RenderingDevice.DATA_FORMAT_R32_UINT,size,PackedByteArray(),4)
	var resources := _create_texture(RenderingDevice.DATA_FORMAT_R8G8B8A8_UINT,size,PackedByteArray(),4)
	var all := [height,climate,water,flux,biome,land,ocean,resources]
	for rid in all:
		if not rid.is_valid(): _free_many(all); return {}
	var texture_set := _uniform_set("classification",[
		_image_uniform(0,height),_image_uniform(1,climate),_image_uniform(2,water),_image_uniform(3,flux),
		_image_uniform(4,biome),_image_uniform(5,land),_image_uniform(6,ocean),_image_uniform(7,resources),
	])
	var ubo := PackedByteArray(); ubo.resize(48)
	var dims: Vector2i=descriptor["global_dimensions"];var origin: Vector2i=descriptor["sample_origin"]
	ubo.encode_u32(0,size.x);ubo.encode_u32(4,size.y);ubo.encode_u32(8,dims.x);ubo.encode_u32(12,dims.y)
	ubo.encode_s32(16,origin.x);ubo.encode_s32(20,origin.y);ubo.encode_u32(24,int(params.get("seed",12345)));ubo.encode_u32(28,int(params.get("planet_type",0)))
	ubo.encode_float(32,float(params.get("sea_level",0.0)));ubo.encode_float(36,maxf(float(params.get("nb_cases_regions",50.0)),1.0));ubo.encode_float(40,maxf(float(params.get("nb_cases_ocean_regions",100.0)),1.0));ubo.encode_float(44,0.0)
	var param_resources := _parameter_set("classification",ubo)
	_dispatch("classification",texture_set,param_resources[0],size)
	context.sync_for_cpu("tiled_classification_readback")
	var result := {
		"biome_id": _crop_payload(rd.texture_get_data(biome,0),size,descriptor,4),
		"region_map": _crop_payload(rd.texture_get_data(land,0),size,descriptor,4),
		"ocean_region_map": _crop_payload(rd.texture_get_data(ocean,0),size,descriptor,4),
		"resources": _crop_payload(rd.texture_get_data(resources,0),size,descriptor,4),
	}
	_release_dispatch_resources(texture_set,param_resources);_free_many(all)
	return result

func cleanup() -> void:
	if _cleaned_up: return
	_cleaned_up=true
	if context != null:
		context.sync_for_cpu("tiled_runner_cleanup")
	_free_macro_textures()
	if context != null:
		context.cleanup()
	context=null;rd=null

func _encode_common_absolute(ubo: PackedByteArray, descriptor: Dictionary) -> void:
	var size: Vector2i=descriptor["sample_size"];var dims: Vector2i=descriptor["global_dimensions"];var origin: Vector2i=descriptor["sample_origin"]
	ubo.encode_u32(0,size.x);ubo.encode_u32(4,size.y);ubo.encode_u32(8,dims.x);ubo.encode_u32(12,dims.y)
	ubo.encode_s32(16,origin.x);ubo.encode_s32(20,origin.y);ubo.encode_u32(24,int(params.get("seed",12345)));ubo.encode_u32(28,int(params.get("planet_type",0)))

func _create_texture(format_value: int, size: Vector2i, data: PackedByteArray, bytes_per_pixel: int) -> RID:
	var format := RDTextureFormat.new();format.width=size.x;format.height=size.y;format.format=format_value
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_STORAGE_BIT|RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT|RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT|RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial: Array[PackedByteArray]=[]
	if not data.is_empty(): initial=[data]
	var rid:=rd.texture_create(format,RDTextureView.new(),initial)
	if rid.is_valid():
		peak_active_bytes=maxi(peak_active_bytes,size.x*size.y*bytes_per_pixel)
	return rid

func _image_uniform(binding: int, rid: RID) -> RDUniform:
	var uniform:=RDUniform.new();uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE;uniform.binding=binding;uniform.add_id(rid);return uniform

func _uniform_set(shader_name: String, uniforms: Array) -> RID:
	return rd.uniform_set_create(uniforms,context.shaders[shader_name],0)

func _parameter_set(shader_name: String, bytes: PackedByteArray) -> Array:
	var buffer:=rd.uniform_buffer_create(bytes.size(),bytes);var uniform:=RDUniform.new();uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER;uniform.binding=0;uniform.add_id(buffer)
	var set:=rd.uniform_set_create([uniform],context.shaders[shader_name],1);return [set,buffer]

func _dispatch(shader_name: String, texture_set: RID, param_set: RID, size: Vector2i) -> void:
	var list:=rd.compute_list_begin();rd.compute_list_bind_compute_pipeline(list,context.pipelines[shader_name]);rd.compute_list_bind_uniform_set(list,texture_set,0);rd.compute_list_bind_uniform_set(list,param_set,1);rd.compute_list_dispatch(list,ceili(float(size.x)/16.0),ceili(float(size.y)/16.0),1);rd.compute_list_end();context.submit_gpu_work()

func _release_dispatch_resources(texture_set: RID, param_resources: Array) -> void:
	context.release_rid(texture_set);context.release_rid(param_resources[0]);context.release_rid(param_resources[1])

func _free_many(rids: Array) -> void:
	for rid in rids:
		if rid.is_valid(): context.release_rid(rid)

func _free_macro_textures() -> void:
	if context == null:return
	if _macro_flux.is_valid():context.release_rid(_macro_flux)
	if _macro_direction.is_valid():context.release_rid(_macro_direction)
	_macro_flux=RID();_macro_direction=RID()

func _crop_payload(data: PackedByteArray, sample_size: Vector2i,
		descriptor: Dictionary, bytes_per_pixel: int) -> PackedByteArray:
	var core: Rect2i=descriptor["core"];var offset: Vector2i=descriptor["crop_offset"]
	if core.size==sample_size and offset==Vector2i.ZERO:return data
	var output:=PackedByteArray()
	for y in range(core.size.y):
		var start:=((y+offset.y)*sample_size.x+offset.x)*bytes_per_pixel
		var length:=core.size.x*bytes_per_pixel
		output.append_array(data.slice(start,start+length))
	return output

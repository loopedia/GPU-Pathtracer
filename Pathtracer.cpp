#include "Pathtracer.h"

#include <filesystem>

#include "CUDAMemory.h"
#include "CUDAContext.h"

#include "MeshData.h"
#include "BVH.h"
#include "MBVH.h"

#include "Sky.h"

#include "ScopedTimer.h"

void Pathtracer::init(const char * cuda_src_name, const char * scene_name, const char * sky_name) {
	CUDAContext::init();

	camera.init(DEG_TO_RAD(110.0f));
	camera.resize(SCREEN_WIDTH, SCREEN_HEIGHT);

	// Init CUDA Module and its Kernel
	module.init(cuda_src_name, CUDAContext::compute_capability);

	const MeshData * mesh = MeshData::load(scene_name);

	if (mesh->material_count > MAX_MATERIALS || Texture::texture_count > MAX_TEXTURES) abort();

	// Set global Material table
	module.get_global("materials").set_buffer(mesh->materials, mesh->material_count);

	// Set global Texture table
	if (Texture::texture_count > 0) {
		CUtexObject * tex_objects = new CUtexObject[Texture::texture_count];

		for (int i = 0; i < Texture::texture_count; i++) {
			CUarray array = CUDAMemory::create_array(Texture::textures[i].width, Texture::textures[i].height, Texture::textures[i].channels, CUarray_format::CU_AD_FORMAT_UNSIGNED_INT8);
		
			CUDAMemory::copy_array(array, Texture::textures[i].channels * Texture::textures[i].width, Texture::textures[i].height, Texture::textures[i].data);

			// Describe the Array to read from
			CUDA_RESOURCE_DESC res_desc = { };
			res_desc.resType = CUresourcetype::CU_RESOURCE_TYPE_ARRAY;
			res_desc.res.array.hArray = array;
		
			// Describe how to sample the Texture
			CUDA_TEXTURE_DESC tex_desc = { };
			tex_desc.addressMode[0] = CUaddress_mode::CU_TR_ADDRESS_MODE_WRAP;
			tex_desc.addressMode[1] = CUaddress_mode::CU_TR_ADDRESS_MODE_WRAP;
			tex_desc.filterMode = CUfilter_mode::CU_TR_FILTER_MODE_POINT;
			tex_desc.flags = CU_TRSF_NORMALIZED_COORDINATES | CU_TRSF_SRGB;
			
			CUDACALL(cuTexObjectCreate(tex_objects + i, &res_desc, &tex_desc, nullptr));
		}

		module.get_global("textures").set_buffer(tex_objects, Texture::texture_count);

		delete [] tex_objects;
	}

	// Construct BVH for the Triangle soup
	BVH<Triangle> bvh;

	std::string bvh_filename = std::string(scene_name) + ".bvh";
	if (std::filesystem::exists(bvh_filename)) {
		printf("Loading BVH %s from disk.\n", bvh_filename.c_str());

		bvh.load_from_disk(bvh_filename.c_str());
	} else {
		bvh.init(mesh->triangle_count);

		memcpy(bvh.primitives, mesh->triangles, mesh->triangle_count * sizeof(Triangle));

		for (int i = 0; i < bvh.primitive_count; i++) {
			Vector3 vertices[3] = { 
				bvh.primitives[i].position0, 
				bvh.primitives[i].position1, 
				bvh.primitives[i].position2
			};
			bvh.primitives[i].aabb = AABB::from_points(vertices, 3);
		}

		{
			ScopedTimer timer("BVH Construction");

			bvh.build_sbvh();
		}

		bvh.save_to_disk(bvh_filename.c_str());
	}

	MBVH<Triangle> mbvh;
	mbvh.init(bvh);

	// Flatten the Primitives array so that we don't need the indices array as an indirection to index it
	// (This does mean more memory consumption)
	Triangle * flat_triangles = new Triangle[mbvh.leaf_count];
	for (int i = 0; i < mbvh.leaf_count; i++) {
		flat_triangles[i] = mbvh.primitives[mbvh.indices[i]];
	}

	// Allocate Triangles in SoA format
	Vector3 * triangles_position0      = new Vector3[mbvh.leaf_count];
	Vector3 * triangles_position_edge1 = new Vector3[mbvh.leaf_count];
	Vector3 * triangles_position_edge2 = new Vector3[mbvh.leaf_count];

	Vector3 * triangles_normal0      = new Vector3[mbvh.leaf_count];
	Vector3 * triangles_normal_edge1 = new Vector3[mbvh.leaf_count];
	Vector3 * triangles_normal_edge2 = new Vector3[mbvh.leaf_count]; 
	
	Vector2 * triangles_tex_coord0      = new Vector2[mbvh.leaf_count];
	Vector2 * triangles_tex_coord_edge1 = new Vector2[mbvh.leaf_count];
	Vector2 * triangles_tex_coord_edge2 = new Vector2[mbvh.leaf_count];

	int * triangles_material_id = new int[mbvh.leaf_count];

	for (int i = 0; i < mbvh.leaf_count; i++) {
		triangles_position0[i]      = flat_triangles[i].position0;
		triangles_position_edge1[i] = flat_triangles[i].position1 - flat_triangles[i].position0;
		triangles_position_edge2[i] = flat_triangles[i].position2 - flat_triangles[i].position0;

		triangles_normal0[i]      = flat_triangles[i].normal0;
		triangles_normal_edge1[i] = flat_triangles[i].normal1 - flat_triangles[i].normal0;
		triangles_normal_edge2[i] = flat_triangles[i].normal2 - flat_triangles[i].normal0;

		triangles_tex_coord0[i]      = flat_triangles[i].tex_coord0;
		triangles_tex_coord_edge1[i] = flat_triangles[i].tex_coord1 - flat_triangles[i].tex_coord0;
		triangles_tex_coord_edge2[i] = flat_triangles[i].tex_coord2 - flat_triangles[i].tex_coord0;

		triangles_material_id[i] = flat_triangles[i].material_id;
	}

	delete [] flat_triangles;

	// Set global Triangle buffers
	module.get_global("triangles_position0"     ).set_buffer(triangles_position0,      mbvh.leaf_count);
	module.get_global("triangles_position_edge1").set_buffer(triangles_position_edge1, mbvh.leaf_count);
	module.get_global("triangles_position_edge2").set_buffer(triangles_position_edge2, mbvh.leaf_count);

	module.get_global("triangles_normal0"     ).set_buffer(triangles_normal0,      mbvh.leaf_count);
	module.get_global("triangles_normal_edge1").set_buffer(triangles_normal_edge1, mbvh.leaf_count);
	module.get_global("triangles_normal_edge2").set_buffer(triangles_normal_edge2, mbvh.leaf_count);

	module.get_global("triangles_tex_coord0"     ).set_buffer(triangles_tex_coord0,      mbvh.leaf_count);
	module.get_global("triangles_tex_coord_edge1").set_buffer(triangles_tex_coord_edge1, mbvh.leaf_count);
	module.get_global("triangles_tex_coord_edge2").set_buffer(triangles_tex_coord_edge2, mbvh.leaf_count);

	module.get_global("triangles_material_id").set_buffer(triangles_material_id, mbvh.leaf_count);

	// Clean up buffers on Host side
	delete [] triangles_position0;  
	delete [] triangles_position_edge1;
	delete [] triangles_position_edge2;
	delete [] triangles_normal0;
	delete [] triangles_normal_edge1;
	delete [] triangles_normal_edge2;
	delete [] triangles_tex_coord0;  
	delete [] triangles_tex_coord_edge1;
	delete [] triangles_tex_coord_edge2;
	delete [] triangles_material_id;

	int * light_indices = new int[mesh->triangle_count];
	int   light_count = 0;

	for (int i = 0; i < mesh->triangle_count; i++) {
		const Triangle & triangle = mesh->triangles[i];

		if (Vector3::length_squared(mesh->materials[triangle.material_id].emission) > 0.0f) {
			int index = -1;
			for (int j = 0; j < mbvh.leaf_count; j++) {
				if (mbvh.indices[j] == i) {
					index = j;

					break;
				}
			}

			light_indices[light_count++] = index;
		}
	}
	
	if (light_count > 0) {
		module.get_global("light_indices").set_buffer(light_indices, light_count);
	}

	delete [] light_indices;

	module.get_global("light_count").set_value(light_count);

	// Set global MBVHNode buffer
	module.get_global("mbvh_nodes").set_buffer(mbvh.nodes, mbvh.node_count);

	// Set Sky globals
	Sky sky;
	sky.init(sky_name);

	module.get_global("sky_size").set_value(sky.size);
	module.get_global("sky_data").set_buffer(sky.data, sky.size * sky.size);
	
	if (strcmp(scene_name, DATA_PATH("pica/pica.obj")) == 0) {
		camera.position = Vector3(-14.875896f, 5.407789f, 22.486183f);
		camera.rotation = Quaternion(0.000000f, 0.980876f, 0.000000f, 0.194635f);
	} else if (strcmp(scene_name, DATA_PATH("sponza/sponza.obj")) == 0) {
		camera.position = Vector3(2.698714f, 39.508224f, 15.633610f);
		camera.rotation = Quaternion(0.000000f, -0.891950f, 0.000000f, 0.452135f);
	} else if (strcmp(scene_name, DATA_PATH("scene.obj")) == 0) {
		camera.position = Vector3(-0.101589f, 0.613379f, 3.580916f);
		camera.rotation = Quaternion(-0.006744f, 0.992265f, -0.107043f, -0.062512f);

		//camera.position = Vector3(-1.843730f, -0.213465f, -0.398855f);
		//camera.rotation = Quaternion(0.045417f, 0.900693f, -0.097165f, 0.421010f);

		//camera.position = Vector3(-1.526055f, 0.739711f, -1.135700f);
		//camera.rotation = Quaternion(-0.154179f, -0.830964f, 0.282224f, -0.453958f);
	} else if (strcmp(scene_name, DATA_PATH("cornellbox.obj")) == 0) {
		camera.position = Vector3(0.528027f, 1.004323f, 0.774033f);
		camera.rotation = Quaternion(0.035059f, -0.963870f, 0.208413f, 0.162142f);
	} else if (strcmp(scene_name, DATA_PATH("glossy.obj")) == 0) {
		camera.position = Vector3(9.467193f, 5.919240f, -0.646071f);
		camera.rotation = Quaternion(0.179088f, -0.677310f, 0.175366f, 0.691683f);
	} else {
		camera.position = Vector3(1.272743f, 3.097532f, 3.189943f);
		camera.rotation = Quaternion(0.000000f, 0.995683f, 0.000000f, -0.092814f);
	}
}

void Pathtracer::update(float delta, const unsigned char * keys) {
	camera.update(delta, keys);
}

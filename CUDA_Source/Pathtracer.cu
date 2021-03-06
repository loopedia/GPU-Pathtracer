#include "cudart/vector_types.h"
#include "cudart/cuda_math.h"

#include "Common.h"

__device__ __constant__ int screen_width;
__device__ __constant__ int screen_pitch;
__device__ __constant__ int screen_height;

__device__ __constant__ Settings settings;

#include "Util.h"
#include "Shading.h"
#include "Sky.h"
#include "Random.h"

#define INFINITY ((float)(1e+300 * 1e+300))

// Frame Buffers
__device__ float4 * frame_buffer_albedo;
__device__ float4 * frame_buffer_direct;
__device__ float4 * frame_buffer_indirect;

__device__ float4 * frame_buffer_moment;

// GBuffers (OpenGL resource-mapped textures)
__device__ Texture<float4> gbuffer_normal_and_depth;
__device__ Texture<float2> gbuffer_uv;
__device__ Texture<float4> gbuffer_uv_gradient;
__device__ Texture<int2>   gbuffer_mesh_id_and_triangle_id;
__device__ Texture<float2> gbuffer_screen_position_prev;
__device__ Texture<float2> gbuffer_depth_gradient;

// SVGF History Buffers (Temporally Integrated)
__device__ int    * history_length;
__device__ float4 * history_direct;
__device__ float4 * history_indirect;
__device__ float4 * history_moment;
__device__ float4 * history_normal_and_depth;

// Used for Temporal Anti-Aliasing
__device__ float4 * taa_frame_curr;
__device__ float4 * taa_frame_prev;

// Used by Reconstruction Filter
__device__ float2 * sample_xy;
__device__ float4 * reconstruction;

// Final Frame buffer, shared with OpenGL
__device__ Surface<float4> accumulator; 

#include "SVGF.h"
#include "TAA.h"

// Vector3 buffer in SoA layout
struct Vector3_SoA {
	float * x;
	float * y;
	float * z;

	__device__ void from_float3(int index, const float3 & vector) {
		x[index] = vector.x;
		y[index] = vector.y;
		z[index] = vector.z;
	}

	__device__ float3 to_float3(int index) const {
		return make_float3(
			x[index],
			y[index],
			z[index]
		);
	}
};

struct HitBuffer {
	uint4 * hits;

	__device__ void set(int index, int mesh_id, int triangle_id, float t, float u, float v) {
		unsigned uv = int(u * 65535.0f) | (int(v * 65535.0f) << 16);
		hits[index] = make_uint4(mesh_id, triangle_id, float_as_uint(t), uv);
	}

	__device__ void get(int index, int & mesh_id, int & triangle_id, float & t, float & u, float & v) const {
		uint4 hit = __ldg(&hits[index]);

		mesh_id     = hit.x;
		triangle_id = hit.y;
		
		t = uint_as_float(hit.z);

		u = float(hit.w & 0xffff) / 65535.0f;
		v = float(hit.w >> 16)    / 65535.0f;
	}
};

// Input to the Trace and Sort Kernels in SoA layout
struct TraceBuffer {
	Vector3_SoA origin;
	Vector3_SoA direction;

#if ENABLE_MIPMAPPING
	float * cone_width;
#endif

	float   * hit_ts;
	HitBuffer hits;

	int       * pixel_index;
	Vector3_SoA throughput;

	char  * last_material_type;
	float * last_pdf;
};

// Input to the various Shade Kernels in SoA layout
struct MaterialBuffer {
	Vector3_SoA direction;	

#if ENABLE_MIPMAPPING
	float * cone_width;
#endif

	float   * hit_ts;
	HitBuffer hits;

	int       * pixel_index;
	Vector3_SoA throughput;
};

// Input to the Shadow Trace Kernel in SoA layout
struct ShadowRayBuffer {
	Vector3_SoA ray_origin;
	Vector3_SoA ray_direction;

	float * max_distance;

	int       * pixel_index;
	Vector3_SoA illumination;
};

__device__ TraceBuffer     ray_buffer_trace;
__device__ MaterialBuffer  ray_buffer_shade_diffuse;
__device__ MaterialBuffer  ray_buffer_shade_dielectric;
__device__ MaterialBuffer  ray_buffer_shade_glossy;
__device__ ShadowRayBuffer ray_buffer_shadow;

// Number of elements in each Buffer
// Sizes are stored for ALL bounces so we only have to reset these
// values back to 0 after every frame, instead of after every bounce
struct BufferSizes {
	int trace     [NUM_BOUNCES];
	int diffuse   [NUM_BOUNCES];
	int dielectric[NUM_BOUNCES];
	int glossy    [NUM_BOUNCES];
	int shadow    [NUM_BOUNCES];

	// Global counters for tracing kernels
	int rays_retired       [NUM_BOUNCES];
	int rays_retired_shadow[NUM_BOUNCES];
} __device__ buffer_sizes;

struct Camera {
	float3 position;
	float3 bottom_left_corner;
	float3 x_axis;
	float3 y_axis;
	float  pixel_spread_angle;
} __device__ __constant__ camera;

#include "Tracing.h"
#include "Mipmap.h"

// Sends the rasterized GBuffer to the right Material kernels,
// as if the primary Rays they were Raytraced 
extern "C" __global__ void kernel_primary(
	int rand_seed,
	int sample_index,
	int pixel_offset,
	int pixel_count,
	bool jitter
) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= pixel_count) return;

	int index_offset = index + pixel_offset;
	int x = index_offset % screen_width;
	int y = index_offset / screen_width;

	int pixel_index = x + y * screen_pitch;

	unsigned seed = wang_hash(pixel_index ^ rand_seed);

	float u_screenspace = float(x) + 0.5f;
	float v_screenspace = float(y) + 0.5f;

	float u = u_screenspace / float(screen_width);
	float v = v_screenspace / float(screen_height);

	float2 uv          = gbuffer_uv         .get(u, v);
	float4 uv_gradient = gbuffer_uv_gradient.get(u, v);

	int2 mesh_id_and_triangle_id = gbuffer_mesh_id_and_triangle_id.get(u, v);
	int mesh_id     = mesh_id_and_triangle_id.x;
	int triangle_id = mesh_id_and_triangle_id.y - 1;

	float dx = 0.0f;
	float dy = 0.0f;
	
	if (jitter) {
		// Jitter the barycentric coordinates in screen space using their screen space differentials
		dx = random_float_heitz(x, y, sample_index, 0, 0, seed) - 0.5f;
		dy = random_float_heitz(x, y, sample_index, 0, 1, seed) - 0.5f;

		uv.x = saturate(uv.x + uv_gradient.x * dx + uv_gradient.z * dy);
		uv.y = saturate(uv.y + uv_gradient.y * dx + uv_gradient.w * dy);
	}

	float2 pixel_coord = make_float2(u_screenspace + dx, v_screenspace + dy);
	sample_xy[pixel_index] = pixel_coord;

	float3 ray_direction = camera.bottom_left_corner + pixel_coord.x * camera.x_axis + pixel_coord.y * camera.y_axis;

	// Triangle ID -1 means no hit
	if (triangle_id == -1) {
		if (settings.demodulate_albedo || settings.enable_svgf) {
			frame_buffer_albedo[pixel_index] = make_float4(1.0f);
		}
		frame_buffer_direct[pixel_index] = make_float4(sample_sky(normalize(ray_direction)));

		return;
	}

	const Material & material = materials[triangle_get_material_id(triangle_id)];

	// Decide which Kernel to invoke, based on Material Type
	switch (material.type) {
		case Material::Type::LIGHT: {
			// Terminate Path
			if (settings.demodulate_albedo || settings.enable_svgf) {
				frame_buffer_albedo[pixel_index] = make_float4(1.0f);
			}
			frame_buffer_direct[pixel_index] = make_float4(material.emission);

			break;
		}
		
		case Material::Type::DIFFUSE: {
			int index_out = atomic_agg_inc(&buffer_sizes.diffuse[0]);

			ray_buffer_shade_diffuse.direction.from_float3(index_out, ray_direction);

			ray_buffer_shade_diffuse.hits.set(index_out, mesh_id, triangle_id, 0.0f, uv.x, uv.y);

			ray_buffer_shade_diffuse.pixel_index[index_out] = pixel_index;
			ray_buffer_shade_diffuse.throughput.from_float3(index_out, make_float3(1.0f));

			break;
		}

		case Material::Type::DIELECTRIC: {
			int index_out = atomic_agg_inc(&buffer_sizes.dielectric[0]);

			ray_buffer_shade_dielectric.direction.from_float3(index_out, ray_direction);

			ray_buffer_shade_dielectric.hits.set(index_out, mesh_id, triangle_id, 0.0f, uv.x, uv.y);

			ray_buffer_shade_dielectric.pixel_index[index_out] = pixel_index;
			ray_buffer_shade_dielectric.throughput.from_float3(index_out, make_float3(1.0f));
			
			break;
		}

		case Material::Type::GLOSSY: {
			int index_out = atomic_agg_inc(&buffer_sizes.glossy[0]);

			ray_buffer_shade_glossy.direction.from_float3(index_out, ray_direction);

			ray_buffer_shade_glossy.hits.set(index_out, mesh_id, triangle_id, 0.0f, uv.x, uv.y);

			ray_buffer_shade_glossy.pixel_index[index_out] = pixel_index;
			ray_buffer_shade_glossy.throughput.from_float3(index_out, make_float3(1.0f));
			
			break;
		}
	}
}

extern "C" __global__ void kernel_generate(
	int rand_seed,
	int sample_index,
	int pixel_offset,
	int pixel_count
) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= pixel_count) return;

	int index_offset = index + pixel_offset;
	int x = index_offset % screen_width;
	int y = index_offset / screen_width;

	unsigned seed = wang_hash(index_offset ^ rand_seed);

	int pixel_index = x + y * screen_pitch;
	ASSERT(pixel_index < screen_pitch * screen_height, "Pixel should fit inside the buffer");

	// Add random value between 0 and 1 so that after averaging we get anti-aliasing
	float x_jittered = float(x) + random_float_heitz(x, y, sample_index, 0, 0, seed);
	float y_jittered = float(y) + random_float_heitz(x, y, sample_index, 0, 1, seed);

	sample_xy[pixel_index] = make_float2(x_jittered, y_jittered);

	float3 direction_unnormalized = camera.bottom_left_corner + x_jittered * camera.x_axis + y_jittered * camera.y_axis;

	// Create primary Ray that starts at the Camera's position and goes through the current pixel
	ray_buffer_trace.origin   .from_float3(index, camera.position);
	ray_buffer_trace.direction.from_float3(index, direction_unnormalized);

	ray_buffer_trace.pixel_index[index] = pixel_index;
	ray_buffer_trace.throughput.from_float3(index, make_float3(1.0f));

	ray_buffer_trace.last_material_type[index] = char(Material::Type::DIELECTRIC);
}

extern "C" __global__ void kernel_trace(int bounce) {
	bvh_trace(buffer_sizes.trace[bounce], &buffer_sizes.rays_retired[bounce]);
}

extern "C" __global__ void kernel_sort(int rand_seed, int bounce) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= buffer_sizes.trace[bounce]) return;

	float3 ray_origin    = ray_buffer_trace.origin   .to_float3(index);
	float3 ray_direction = ray_buffer_trace.direction.to_float3(index);

	int   hit_mesh_id;
	int   hit_triangle_id;
	float hit_t;
	float hit_u;
	float hit_v;
	ray_buffer_trace.hits.get(index, hit_mesh_id, hit_triangle_id, hit_t, hit_u, hit_v);

	int    ray_pixel_index = ray_buffer_trace.pixel_index[index];
	float3 ray_throughput  = ray_buffer_trace.throughput.to_float3(index);
	
	// If we didn't hit anything, sample the Sky
	if (hit_triangle_id == -1) {
		float3 illumination = ray_throughput * sample_sky(normalize(ray_direction));

		if (bounce == 0) {
			if (settings.demodulate_albedo || settings.enable_svgf) {
				frame_buffer_albedo[ray_pixel_index] = make_float4(1.0f);
			}
			frame_buffer_direct[ray_pixel_index] = make_float4(illumination);
		} else if (bounce == 1) {
			frame_buffer_direct[ray_pixel_index] += make_float4(illumination);
		} else {
			frame_buffer_indirect[ray_pixel_index] += make_float4(illumination);
		}

		return;
	}

	// Get the Material of the Triangle we hit
	const Material & material = materials[triangle_get_material_id(hit_triangle_id)];

	if (material.type == Material::Type::LIGHT) {
		bool no_mis = true;
		if (settings.enable_next_event_estimation) {
			no_mis = 
				(ray_buffer_trace.last_material_type[index] == char(Material::Type::DIELECTRIC)) ||
				(ray_buffer_trace.last_material_type[index] == char(Material::Type::GLOSSY) && material.roughness < ROUGHNESS_CUTOFF);
		}

		if (no_mis) {
			float3 illumination = ray_throughput * material.emission;

			if (bounce == 0) {
				if (settings.demodulate_albedo || settings.enable_svgf) {
					frame_buffer_albedo[ray_pixel_index] = make_float4(1.0f);
				}
				frame_buffer_direct[ray_pixel_index] = make_float4(material.emission);
			} else if (bounce == 1) {
				frame_buffer_direct[ray_pixel_index] += make_float4(illumination);
			} else {
				frame_buffer_indirect[ray_pixel_index] += make_float4(illumination);
			}

			return;
		}

		if (settings.enable_multiple_importance_sampling) {
			// Get the corner + 2 edges of the Triangle we hit
			float3 light_position_0, light_position_edge_1, light_position_edge_2;
			float3 light_normal_0,   light_normal_edge_1,   light_normal_edge_2;

			triangle_get_positions_and_normals(hit_triangle_id,
				light_position_0, light_position_edge_1, light_position_edge_2,
				light_normal_0,   light_normal_edge_1,   light_normal_edge_2
			);

			// Get hit position / normal by interpolating based on the hit (u,v)
			float3 light_point  = barycentric(hit_u, hit_v, light_position_0, light_position_edge_1, light_position_edge_2);
			float3 light_normal = barycentric(hit_u, hit_v, light_normal_0,   light_normal_edge_1,   light_normal_edge_2);

			// Normalize and transform into world space
			light_normal = normalize(light_normal);
			mesh_transform_position_and_direction(hit_mesh_id, light_point, light_normal);

			float3 to_light = light_point - ray_origin;;
			float distance_to_light_squared = dot(to_light, to_light);
			float distance_to_light         = sqrtf(distance_to_light_squared);

			to_light /= distance_to_light; // Normalize

			float cos_o = fabsf(dot(to_light, light_normal));
			// if (cos_o <= 0.0f) return;

			float light_area = 0.5f * length(cross(light_position_edge_1, light_position_edge_2));
			
			float brdf_pdf = ray_buffer_trace.last_pdf[index];

#if LIGHT_SELECTION == LIGHT_SELECT_UNIFORM
			float light_select_pdf = light_total_count_inv;
#elif LIGHT_SELECTION == LIGHT_SELECT_AREA
			float light_select_pdf = light_area / light_total_area;
#endif
			float light_pdf = light_select_pdf * distance_to_light_squared / (cos_o * light_area); // Convert solid angle measure

			float mis_pdf = brdf_pdf + light_pdf;

			float3 illumination = ray_throughput * material.emission * brdf_pdf / mis_pdf;

			if (bounce == 1) {
				frame_buffer_direct[ray_pixel_index] += make_float4(illumination);
			} else {
				frame_buffer_indirect[ray_pixel_index] += make_float4(illumination);
			}
		}

		return;
	}

	unsigned seed = wang_hash(index ^ rand_seed);

	// Russian Roulette
	float p_survive = saturate(fmaxf(ray_throughput.x, fmaxf(ray_throughput.y, ray_throughput.z)));
	if (random_float_xorshift(seed) > p_survive) {
		return;
	}

	ray_throughput /= p_survive;

	switch (material.type) {
		case Material::Type::DIFFUSE: {
			int index_out = atomic_agg_inc(&buffer_sizes.diffuse[bounce]);

			ray_buffer_shade_diffuse.direction.from_float3(index_out, ray_direction);

#if ENABLE_MIPMAPPING
			if (bounce > 0) ray_buffer_shade_diffuse.cone_width[index_out] = ray_buffer_trace.cone_width[index];
#endif
			ray_buffer_shade_diffuse.hits.set(index_out, hit_mesh_id, hit_triangle_id, hit_t, hit_u, hit_v);
			
			ray_buffer_shade_diffuse.pixel_index[index_out] = ray_buffer_trace.pixel_index[index];
			ray_buffer_shade_diffuse.throughput.from_float3(index_out, ray_throughput);

			break;
		}

		case Material::Type::DIELECTRIC: {
			int index_out = atomic_agg_inc(&buffer_sizes.dielectric[bounce]);

			ray_buffer_shade_dielectric.direction.from_float3(index_out, ray_direction);

#if ENABLE_MIPMAPPING
			if (bounce > 0) ray_buffer_shade_dielectric.cone_width[index_out] = ray_buffer_trace.cone_width[index];
#endif
			ray_buffer_shade_dielectric.hits.set(index_out, hit_mesh_id, hit_triangle_id, hit_t, hit_u, hit_v);

			ray_buffer_shade_dielectric.pixel_index[index_out] = ray_buffer_trace.pixel_index[index];
			ray_buffer_shade_dielectric.throughput.from_float3(index_out, ray_throughput);

			break;
		}

		case Material::Type::GLOSSY: {
			int index_out = atomic_agg_inc(&buffer_sizes.glossy[bounce]);

			ray_buffer_shade_glossy.direction.from_float3(index_out, ray_direction);

#if ENABLE_MIPMAPPING
			if (bounce > 0) ray_buffer_shade_glossy.cone_width[index_out] = ray_buffer_trace.cone_width[index];
#endif
			ray_buffer_shade_glossy.hits.set(index_out, hit_mesh_id, hit_triangle_id, hit_t, hit_u, hit_v);

			ray_buffer_shade_glossy.pixel_index[index_out] = ray_buffer_trace.pixel_index[index];
			ray_buffer_shade_glossy.throughput.from_float3(index_out, ray_throughput);

			break;
		}
	}
}

extern "C" __global__ void kernel_shade_diffuse(int rand_seed, int bounce, int sample_index) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= buffer_sizes.diffuse[bounce]) return;

	float3 ray_direction = ray_buffer_shade_diffuse.direction.to_float3(index);

	int   ray_mesh_id;
	int   ray_triangle_id;
	float ray_t;
	float ray_u;
	float ray_v;
	ray_buffer_shade_diffuse.hits.get(index, ray_mesh_id, ray_triangle_id, ray_t, ray_u, ray_v);

	int ray_pixel_index = ray_buffer_shade_diffuse.pixel_index[index];
	int x = ray_pixel_index % screen_pitch;
	int y = ray_pixel_index / screen_pitch;

	float3 ray_throughput = ray_buffer_shade_diffuse.throughput.to_float3(index);

	ASSERT(ray_triangle_id != -1, "Ray must have hit something for this Kernel to be invoked!");

	unsigned seed = wang_hash(index ^ rand_seed);

	const Material & material = materials[triangle_get_material_id(ray_triangle_id)];

	ASSERT(material.type == Material::Type::DIFFUSE, "Material should be diffuse in this Kernel");

	float3 hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2;
	float3 hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2;
	float2 hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2;

	triangle_get_positions_normals_and_tex_coords(ray_triangle_id,
		hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2,
		hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2,
		hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2
	);

	float3 hit_point     = barycentric(ray_u, ray_v, hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2);
	float3 hit_normal    = barycentric(ray_u, ray_v, hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2);
	float2 hit_tex_coord = barycentric(ray_u, ray_v, hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2);

	hit_normal = normalize(hit_normal);
	mesh_transform_position_and_direction(ray_mesh_id, hit_point, hit_normal);
	
	if (dot(ray_direction, hit_normal) > 0.0f) hit_normal = -hit_normal;

	float3 albedo;

#if ENABLE_MIPMAPPING
	float cone_width;

	// Primary rays use ray differentials to determine mipmap LOD, subsequent bounces use ray cones
	if (bounce == 0) {
		cone_width = camera.pixel_spread_angle * ray_t / length(ray_direction); // On bounce 0 Ray direction is non-normalized

		albedo = mipmap_sample_ray_differentials(
			material,
			ray_mesh_id, ray_triangle_id,
			hit_triangle_position_edge_1, hit_triangle_position_edge_2,
			hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2,
			ray_direction, ray_t,
			hit_tex_coord
		);
	} else {	
		cone_width = ray_buffer_shade_diffuse.cone_width[index] + camera.pixel_spread_angle * ray_t;

		albedo = mipmap_sample_ray_cones(material, ray_triangle_id, ray_direction, ray_t, cone_width, hit_normal, hit_tex_coord);
	}
#else
	albedo = material.albedo(hit_tex_coord.x, hit_tex_coord.y);
#endif

	if (bounce == 0 && (settings.demodulate_albedo || settings.enable_svgf)) {
		frame_buffer_albedo[ray_pixel_index] = make_float4(albedo);
	}

	float3 throughput = ray_throughput * albedo;
	
	if (settings.enable_next_event_estimation) {
		bool scene_has_lights = light_total_count_inv < INFINITY; // 1 / light_count < INF means light_count > 0
		if (scene_has_lights) {
			// Trace Shadow Ray
			float light_u, light_v;
			int   light_transform_id;
			int   light_id = random_point_on_random_light(x, y, sample_index, bounce, seed, light_u, light_v, light_transform_id);

			float3 light_position_0, light_position_edge_1, light_position_edge_2;
			float3 light_normal_0,   light_normal_edge_1,   light_normal_edge_2;

			triangle_get_positions_and_normals(light_id,
				light_position_0, light_position_edge_1, light_position_edge_2,
				light_normal_0,   light_normal_edge_1,   light_normal_edge_2
			);

			float3 light_point  = barycentric(light_u, light_v, light_position_0, light_position_edge_1, light_position_edge_2);
			float3 light_normal = barycentric(light_u, light_v, light_normal_0,   light_normal_edge_1,   light_normal_edge_2);

			light_normal = normalize(light_normal);
			mesh_transform_position_and_direction(light_transform_id, light_point, light_normal);

			float3 to_light = light_point - hit_point;
			float distance_to_light_squared = dot(to_light, to_light);
			float distance_to_light         = sqrtf(distance_to_light_squared);

			// Normalize the vector to the light
			to_light /= distance_to_light;

			float cos_o = -dot(to_light, light_normal);
			float cos_i =  dot(to_light,   hit_normal);
		
			// Only trace Shadow Ray if light transport is possible given the normals
			if (cos_o > 0.0f && cos_i > 0.0f) {
				// NOTE: N dot L is included here
				float brdf     = cos_i * ONE_OVER_PI;
				float brdf_pdf = cos_i * ONE_OVER_PI;

				float light_area = 0.5f * length(cross(light_position_edge_1, light_position_edge_2));

#if LIGHT_SELECTION == LIGHT_SELECT_UNIFORM
				float light_select_pdf = light_total_count_inv; 
#elif LIGHT_SELECTION == LIGHT_SELECT_AREA
				float light_select_pdf = light_area / light_total_area;
#endif
				float light_pdf = light_select_pdf * distance_to_light_squared / (cos_o * light_area); // Convert solid angle measure

				float mis_pdf = settings.enable_multiple_importance_sampling ? brdf_pdf + light_pdf : light_pdf;

				float3 emission     = materials[triangle_get_material_id(light_id)].emission;
				float3 illumination = throughput * brdf * emission / mis_pdf;

				int shadow_ray_index = atomic_agg_inc(&buffer_sizes.shadow[bounce]);

				ray_buffer_shadow.ray_origin   .from_float3(shadow_ray_index, hit_point);
				ray_buffer_shadow.ray_direction.from_float3(shadow_ray_index, to_light);

				ray_buffer_shadow.max_distance[shadow_ray_index] = distance_to_light - EPSILON;

				ray_buffer_shadow.pixel_index[shadow_ray_index] = ray_pixel_index;
				ray_buffer_shadow.illumination.from_float3(shadow_ray_index, illumination);
			}
		}
	}

	if (bounce == NUM_BOUNCES - 1) return;

	int index_out = atomic_agg_inc(&buffer_sizes.trace[bounce + 1]);

	float3 tangent, binormal;
	orthonormal_basis(hit_normal, tangent, binormal);

	float3 direction_local = random_cosine_weighted_direction(x, y, sample_index, bounce, seed);
	float3 direction_world = local_to_world(direction_local, tangent, binormal, hit_normal);

	ray_buffer_trace.origin   .from_float3(index_out, hit_point);
	ray_buffer_trace.direction.from_float3(index_out, direction_world);
	
#if ENABLE_MIPMAPPING
	ray_buffer_trace.cone_width[index_out] = cone_width;
#endif

	ray_buffer_trace.pixel_index[index_out]  = ray_pixel_index;
	ray_buffer_trace.throughput.from_float3(index_out, throughput);

	ray_buffer_trace.last_material_type[index_out] = char(Material::Type::DIFFUSE);
	ray_buffer_trace.last_pdf[index_out] = fabsf(dot(direction_world, hit_normal)) * ONE_OVER_PI;
}

extern "C" __global__ void kernel_shade_dielectric(int rand_seed, int bounce) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= buffer_sizes.dielectric[bounce] || bounce == NUM_BOUNCES - 1) return;

	float3 ray_direction = ray_buffer_shade_dielectric.direction.to_float3(index);
	if (bounce == 0) ray_direction = normalize(ray_direction);

	int   ray_mesh_id;
	int   ray_triangle_id;
	float ray_t;
	float ray_u;
	float ray_v;
	ray_buffer_shade_dielectric.hits.get(index, ray_mesh_id, ray_triangle_id, ray_t, ray_u, ray_v);

	// Primary Ray direction is not normalized because ray differentials need their original length
	// This is not needed in this kernel so normalize the direction and correct t so that it is the actual distance along the ray
	if (bounce == 0) {
		float ray_direction_length_inv = 1.0f / length(ray_direction);
		ray_t         *= ray_direction_length_inv;
		ray_direction *= ray_direction_length_inv;
	}

	int ray_pixel_index = ray_buffer_shade_dielectric.pixel_index[index];

	float3 ray_throughput = ray_buffer_shade_dielectric.throughput.to_float3(index);

	ASSERT(ray_triangle_id != -1, "Ray must have hit something for this Kernel to be invoked!");

	unsigned seed = wang_hash(index ^ rand_seed);

	const Material & material = materials[triangle_get_material_id(ray_triangle_id)];

	ASSERT(material.type == Material::Type::DIELECTRIC, "Material should be dielectric in this Kernel");

	float3 hit_triangle_position_0, hit_triangle_position_edge_1, hit_triangle_position_edge_2;
	float3 hit_triangle_normal_0,   hit_triangle_normal_edge_1,   hit_triangle_normal_edge_2;

	triangle_get_positions_and_normals(ray_triangle_id,
		hit_triangle_position_0, hit_triangle_position_edge_1, hit_triangle_position_edge_2,
		hit_triangle_normal_0,   hit_triangle_normal_edge_1,   hit_triangle_normal_edge_2
	);

	float3 hit_point  = barycentric(ray_u, ray_v, hit_triangle_position_0, hit_triangle_position_edge_1, hit_triangle_position_edge_2);
	float3 hit_normal = barycentric(ray_u, ray_v, hit_triangle_normal_0,   hit_triangle_normal_edge_1,   hit_triangle_normal_edge_2);
	
	hit_normal = normalize(hit_normal);
	mesh_transform_position_and_direction(ray_mesh_id, hit_point, hit_normal);

	int index_out = atomic_agg_inc(&buffer_sizes.trace[bounce + 1]);

	float3 direction;
	float3 direction_reflected = reflect(ray_direction, hit_normal);

	float3 normal;
	float  cos_theta;

	float eta_1;
	float eta_2;

	float dir_dot_normal = dot(ray_direction, hit_normal);
	if (dir_dot_normal < 0.0f) { 
		// Entering material		
		eta_1 = 1.0f;
		eta_2 = material.index_of_refraction;

		normal    =  hit_normal;
		cos_theta = -dir_dot_normal;
	} else { 
		// Leaving material
		eta_1 = material.index_of_refraction;
		eta_2 = 1.0f;

		normal    = -hit_normal;
		cos_theta =  dir_dot_normal;

		// Lambert-Beer Law
		// NOTE: does not take into account nested dielectrics!
		if (dot(material.absorption, material.absorption) > EPSILON) {
			ray_throughput.x *= expf(material.absorption.x * ray_t);
			ray_throughput.y *= expf(material.absorption.y * ray_t);
			ray_throughput.z *= expf(material.absorption.z * ray_t);
		}
	}

	float eta = eta_1 / eta_2;
	float k = 1.0f - eta*eta * (1.0f - cos_theta*cos_theta);

	if (k < 0.0f) {
		// Total Internal Reflection
		direction = direction_reflected;
	} else {
		float3 direction_refracted = normalize(eta * ray_direction + (eta * cos_theta - sqrtf(k)) * hit_normal);

		float fresnel = fresnel_schlick(eta_1, eta_2, cos_theta, -dot(direction_refracted, normal));

		if (random_float_xorshift(seed) < fresnel) {
			direction = direction_reflected;
		} else {
			direction = direction_refracted;
		}
	}

	if ((settings.demodulate_albedo || settings.enable_svgf) && bounce == 0) {
		frame_buffer_albedo[ray_pixel_index] = make_float4(1.0f);
	}

	ray_buffer_trace.origin   .from_float3(index_out, hit_point);
	ray_buffer_trace.direction.from_float3(index_out, direction);

#if ENABLE_MIPMAPPING
	ray_buffer_trace.cone_width[index_out] = ray_buffer_shade_diffuse.cone_width[index] + camera.pixel_spread_angle * ray_t;
#endif
	ray_buffer_trace.pixel_index[index_out] = ray_pixel_index;
	ray_buffer_trace.throughput.from_float3(index_out, ray_throughput);

	ray_buffer_trace.last_material_type[index_out] = char(Material::Type::DIELECTRIC);
}

extern "C" __global__ void kernel_shade_glossy(int rand_seed, int bounce, int sample_index) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index >= buffer_sizes.glossy[bounce]) return;

	float3 ray_direction = ray_buffer_shade_glossy.direction.to_float3(index);

	int   ray_mesh_id;
	int   ray_triangle_id;
	float ray_t;
	float ray_u;
	float ray_v;
	ray_buffer_shade_glossy.hits.get(index, ray_mesh_id, ray_triangle_id, ray_t, ray_u, ray_v);

	int ray_pixel_index = ray_buffer_shade_glossy.pixel_index[index];
	int x = ray_pixel_index % screen_pitch;
	int y = ray_pixel_index / screen_pitch; 

	float3 ray_throughput = ray_buffer_shade_glossy.throughput.to_float3(index);

	ASSERT(ray_triangle_id != -1, "Ray must have hit something for this Kernel to be invoked!");

	unsigned seed = wang_hash(index ^ rand_seed);

	const Material & material = materials[triangle_get_material_id(ray_triangle_id)];

	ASSERT(material.type == Material::Type::GLOSSY, "Material should be glossy in this Kernel");

	float3 hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2;
	float3 hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2;
	float2 hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2;

	triangle_get_positions_normals_and_tex_coords(ray_triangle_id,
		hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2,
		hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2,
		hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2
	);

	float3 hit_point     = barycentric(ray_u, ray_v, hit_triangle_position_0,  hit_triangle_position_edge_1,  hit_triangle_position_edge_2);
	float3 hit_normal    = barycentric(ray_u, ray_v, hit_triangle_normal_0,    hit_triangle_normal_edge_1,    hit_triangle_normal_edge_2);
	float2 hit_tex_coord = barycentric(ray_u, ray_v, hit_triangle_tex_coord_0, hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2);

	hit_normal = normalize(hit_normal);
	mesh_transform_position_and_direction(ray_mesh_id, hit_point, hit_normal);

	if (dot(ray_direction, hit_normal) > 0.0f) hit_normal = -hit_normal;

	float3 albedo;

#if ENABLE_MIPMAPPING
	float cone_width;

	// Primary rays use ray differentials to determine mipmap LOD, subsequent bounces use ray cones
	if (bounce == 0) {
		cone_width = camera.pixel_spread_angle * ray_t / length(ray_direction); // On bounce 0 Ray direction is non-normalized

		albedo = mipmap_sample_ray_differentials(
			material,
			ray_mesh_id, ray_triangle_id,
			hit_triangle_position_edge_1, hit_triangle_position_edge_2,
			hit_triangle_tex_coord_edge_1, hit_triangle_tex_coord_edge_2,
			ray_direction, ray_t,
			hit_tex_coord
		);
	} else {	
		cone_width = ray_buffer_shade_diffuse.cone_width[index] + camera.pixel_spread_angle * ray_t;

		albedo = mipmap_sample_ray_cones(material, ray_triangle_id, ray_direction, ray_t, cone_width, hit_normal, hit_tex_coord);
	}
#else
	albedo = material.albedo(hit_tex_coord.x, hit_tex_coord.y);
#endif

	if (bounce == 0 && (settings.demodulate_albedo || settings.enable_svgf)) {
		frame_buffer_albedo[ray_pixel_index] = make_float4(albedo);
	}

	float3 throughput = ray_throughput * albedo;

	float3 direction_in = -1.0f * normalize(ray_direction);

	// Slightly widen the distribution to prevent the weights from becoming too large (see Walter et al. 2007)
	float alpha = (1.2f - 0.2f * sqrtf(dot(direction_in, hit_normal))) * material.roughness;
	
	if (settings.enable_next_event_estimation) {
		bool scene_has_lights = light_total_count_inv < INFINITY; // 1 / light_count < INF means light_count > 0
		if (scene_has_lights && material.roughness >= ROUGHNESS_CUTOFF) {
			// Trace Shadow Ray
			float light_u;
			float light_v;
			int   light_transform_id;
			int   light_id = random_point_on_random_light(x, y, sample_index, bounce, seed, light_u, light_v, light_transform_id);

			float3 light_position_0, light_position_edge_1, light_position_edge_2;
			float3 light_normal_0,   light_normal_edge_1,   light_normal_edge_2;

			triangle_get_positions_and_normals(light_id,
				light_position_0, light_position_edge_1, light_position_edge_2,
				light_normal_0,   light_normal_edge_1,   light_normal_edge_2
			);

			float3 light_point  = barycentric(light_u, light_v, light_position_0, light_position_edge_1, light_position_edge_2);
			float3 light_normal = barycentric(light_u, light_v, light_normal_0,   light_normal_edge_1,   light_normal_edge_2);

			light_normal = normalize(light_normal);
			mesh_transform_position_and_direction(light_transform_id, light_point, light_normal);

			float3 to_light = light_point - hit_point;
			float distance_to_light_squared = dot(to_light, to_light);
			float distance_to_light         = sqrtf(distance_to_light_squared);

			// Normalize the vector to the light
			to_light /= distance_to_light;

			float cos_o = -dot(to_light, light_normal);
			float cos_i =  dot(to_light,   hit_normal);

			// Only trace Shadow Ray if light transport is possible given the normals
			if (cos_o > 0.0f && cos_i > 0.0f) {
				float3 half_vector = normalize(to_light + direction_in);

				float i_dot_n = dot(direction_in, hit_normal);
				float m_dot_n = dot(half_vector,  hit_normal);

				float F = fresnel_schlick(material.index_of_refraction, 1.0f, i_dot_n, i_dot_n);
				float D = microfacet_D(m_dot_n, alpha);
				float G = microfacet_G(i_dot_n, cos_i, i_dot_n, cos_i, m_dot_n, alpha);

				// NOTE: N dot L is omitted from the denominator here
				float brdf     = (F * G * D) / (4.0f * i_dot_n);
				float brdf_pdf = F * D * m_dot_n / (4.0f * dot(half_vector, direction_in));
				
				float light_area = 0.5f * length(cross(light_position_edge_1, light_position_edge_2));

#if LIGHT_SELECTION == LIGHT_SELECT_UNIFORM
				float light_select_pdf = light_total_count_inv;
#elif LIGHT_SELECTION == LIGHT_SELECT_AREA
				float light_select_pdf = light_area / light_total_area;
#endif
				float light_pdf = light_select_pdf * distance_to_light_squared / (cos_o * light_area); // Convert solid angle measure

				float mis_pdf = settings.enable_multiple_importance_sampling ? brdf_pdf + light_pdf : light_pdf;

				float3 emission     = materials[triangle_get_material_id(light_id)].emission;
				float3 illumination = throughput * brdf * emission / mis_pdf;

				int shadow_ray_index = atomic_agg_inc(&buffer_sizes.shadow[bounce]);

				ray_buffer_shadow.ray_origin   .from_float3(shadow_ray_index, hit_point);
				ray_buffer_shadow.ray_direction.from_float3(shadow_ray_index, to_light);

				ray_buffer_shadow.max_distance[shadow_ray_index] = distance_to_light - EPSILON;

				ray_buffer_shadow.pixel_index[shadow_ray_index] = ray_pixel_index;
				ray_buffer_shadow.illumination.from_float3(shadow_ray_index, illumination);
			}
		}
	}

	if (bounce == NUM_BOUNCES - 1) return;

	// Sample normal distribution in spherical coordinates
	float theta = atanf(sqrtf(-alpha * alpha * logf(random_float_heitz(x, y, sample_index, bounce, 4, seed) + 1e-8f)));
	float phi   = TWO_PI * random_float_heitz(x, y, sample_index, bounce, 5, seed);

	float sin_theta, cos_theta;
	float sin_phi,   cos_phi;

	sincos(theta, &sin_theta, &cos_theta);
	sincos(phi,   &sin_phi,   &cos_phi);

	// Convert from spherical coordinates to cartesian coordinates
	float3 micro_normal_local = make_float3(sin_theta * cos_phi, sin_theta * sin_phi, cos_theta);

	float3 hit_tangent, hit_binormal;
	orthonormal_basis(hit_normal, hit_tangent, hit_binormal);

	float3 micro_normal_world = local_to_world(micro_normal_local, hit_tangent, hit_binormal, hit_normal);

	float3 direction_out = reflect(-direction_in, micro_normal_world);

	float i_dot_m = dot(direction_in,  micro_normal_world);
	float o_dot_m = dot(direction_out, micro_normal_world);
	float i_dot_n = dot(direction_in,       hit_normal);
	float o_dot_n = dot(direction_out,      hit_normal);
	float m_dot_n = dot(micro_normal_world, hit_normal);

	float F = fresnel_schlick(material.index_of_refraction, 1.0f, i_dot_m, i_dot_m);
	float D = microfacet_D(m_dot_n, alpha);
	float G = microfacet_G(i_dot_m, o_dot_m, i_dot_n, o_dot_n, m_dot_n, alpha);
	float weight = fabsf(i_dot_m) * F * G / fabsf(i_dot_n * m_dot_n);

	int index_out = atomic_agg_inc(&buffer_sizes.trace[bounce + 1]);

	ray_buffer_trace.origin   .from_float3(index_out, hit_point);
	ray_buffer_trace.direction.from_float3(index_out, direction_out);

	ray_buffer_trace.pixel_index[index_out] = ray_pixel_index;
	ray_buffer_trace.throughput.from_float3(index_out, throughput);

	ray_buffer_trace.last_material_type[index_out] = char(Material::Type::GLOSSY);
	ray_buffer_trace.last_pdf[index_out] = D * fabsf(m_dot_n) / (4.0f * fabsf(o_dot_m));
}

extern "C" __global__ void kernel_trace_shadow(int bounce) {
	bvh_trace_shadow(buffer_sizes.shadow[bounce], &buffer_sizes.rays_retired_shadow[bounce], bounce);
}

extern "C" __global__ void kernel_reconstruct() {
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;

	if (x >= screen_width || y >= screen_height) return;

	int pixel_index = x + y * screen_pitch;

	float4 direct   = frame_buffer_direct  [pixel_index];
	float4 indirect = frame_buffer_indirect[pixel_index];

	float4 colour = direct + indirect;

	if (settings.demodulate_albedo) {
		colour /= fmaxf(frame_buffer_albedo[pixel_index], make_float4(1e-8f));
	}

	float2 sample = sample_xy[pixel_index];

	const float FILTER_RADIUS    = 1.0f;
	const float GAUSSIAN_FALLOFF = 0.5f;
	const float GUASSIAN_OFFSET  = expf(-GAUSSIAN_FALLOFF * FILTER_RADIUS * FILTER_RADIUS);
	
	float start_x = fmaxf(floorf(sample.x - FILTER_RADIUS + 0.5f), 0.0f);
	float start_y = fmaxf(floorf(sample.y - FILTER_RADIUS + 0.5f), 0.0f);
	float end_x   = fminf(floorf(sample.x + FILTER_RADIUS + 0.5f), float(screen_width)  - 1.0f);
	float end_y   = fminf(floorf(sample.y + FILTER_RADIUS + 0.5f), float(screen_height) - 1.0f);

	int i, j;
	float fi, fj;

	for (j = int(start_y), fj = start_y + 0.5f; j <= int(end_y); j++, fj += 1.0f) {
		for (i = int(start_x), fi = start_x + 0.5f; i <= int(end_x); i++, fi += 1.0f) {
			const int index = i + j * screen_pitch;

			float weight;
			switch (settings.reconstruction_filter) {
				case ReconstructionFilter::MITCHELL_NETRAVALI: {
					weight = mitchell_netravali(fi - sample.x) * mitchell_netravali(fj - sample.y);

					break;
				}

				case ReconstructionFilter::GAUSSIAN: {
					float dx = fi - sample.x;
					float dy = fj - sample.y;

					float gaussian_x = fmaxf(0.0f, expf(-GAUSSIAN_FALLOFF * dx*dx) - GUASSIAN_OFFSET);
					float gaussian_y = fmaxf(0.0f, expf(-GAUSSIAN_FALLOFF * dy*dy) - GUASSIAN_OFFSET);

					weight = gaussian_x * gaussian_y;

					break;
				}
			}

			atomicAdd(&reconstruction[index].x, weight * colour.x);
			atomicAdd(&reconstruction[index].y, weight * colour.y);
			atomicAdd(&reconstruction[index].z, weight * colour.z);
			atomicAdd(&reconstruction[index].w, weight);
		}
	}
}

extern "C" __global__ void kernel_accumulate(float frames_accumulated) {
	int x = blockIdx.x * blockDim.x + threadIdx.x;
	int y = blockIdx.y * blockDim.y + threadIdx.y;

	if (x >= screen_width || y >= screen_height) return;

	int pixel_index = x + y * screen_pitch;

	float4 colour;

	if (settings.reconstruction_filter == ReconstructionFilter::BOX) {
		float4 direct   = frame_buffer_direct  [pixel_index];
		float4 indirect = frame_buffer_indirect[pixel_index];

		colour = direct + indirect;

		if (settings.demodulate_albedo) {
			colour /= fmaxf(frame_buffer_albedo[pixel_index], make_float4(1e-8f));
		}	
	} else {
		colour = reconstruction[pixel_index];
		colour.x /= colour.w;
		colour.y /= colour.w;
		colour.z /= colour.w;

		reconstruction[pixel_index] = make_float4(0.0f);
	}

	if (frames_accumulated > 0.0f) {
		float4 colour_prev = accumulator.get(x, y);

		// Take average over n samples by weighing the current content of the framebuffer by (n-1) and the new sample by 1
		colour = (colour_prev * (frames_accumulated - 1.0f) + colour) / frames_accumulated;
	}

	accumulator.set(x, y, colour);

	// Clear frame buffers for next frame
	if (settings.demodulate_albedo) {
		frame_buffer_albedo[pixel_index] = make_float4(0.0f);
	}
	frame_buffer_direct  [pixel_index] = make_float4(0.0f);
	frame_buffer_indirect[pixel_index] = make_float4(0.0f);
}

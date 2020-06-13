#include "BVHBuilders.h"

#include <algorithm>

#include "BVH.h"
#include "BVHPartitions.h"

#include "ScopeTimer.h"

static void build_bvh(BVHNode & node, const Triangle * triangles, int * indices[3], BVHNode nodes[], int & node_index, int first_index, int index_count, float * sah, int * temp) {
	node.aabb = BVHPartitions::calculate_bounds(triangles, indices[0], first_index, first_index + index_count);
		
	if (index_count < 3) {
		// Leaf Node, terminate recursion
		node.first = first_index;
		node.count = index_count;

		return;
	}
		
	node.left = node_index;
	node_index += 2;
		
	int split_dimension;
	float split_cost;
	int split_index = BVHPartitions::partition_sah(triangles, indices, first_index, index_count, sah, split_dimension, split_cost);

	// Check SAH termination condition
	float parent_cost = node.aabb.surface_area() * float(index_count); 
	if (split_cost >= parent_cost) {
		node.first = first_index;
		node.count = index_count;

		return;
	}

	float split = triangles[indices[split_dimension][split_index]].get_center()[split_dimension];
	BVHPartitions::split_indices(triangles, indices, first_index, index_count, temp, split_dimension, split_index, split);

	node.count = (split_dimension + 1) << 30;

	int n_left  = split_index - first_index;
	int n_right = first_index + index_count - split_index;

	build_bvh(nodes[node.left    ], triangles, indices, nodes, node_index, first_index,          n_left,  sah, temp);
	build_bvh(nodes[node.left + 1], triangles, indices, nodes, node_index, first_index + n_left, n_right, sah, temp);
}

void BVHBuilders::build_bvh(BVH & bvh) {
	bvh.nodes = new BVHNode[2 * bvh.triangle_count];

	// Construct index arrays for all three dimensions
	int * indices_x = new int[bvh.triangle_count];
	int * indices_y = new int[bvh.triangle_count];
	int * indices_z = new int[bvh.triangle_count];

	for (int i = 0; i < bvh.triangle_count; i++) {
		indices_x[i] = i;
		indices_y[i] = i;
		indices_z[i] = i;
	}

	std::sort(indices_x, indices_x + bvh.triangle_count, [&](int a, int b) { return bvh.triangles[a].get_center().x < bvh.triangles[b].get_center().x; });
	std::sort(indices_y, indices_y + bvh.triangle_count, [&](int a, int b) { return bvh.triangles[a].get_center().y < bvh.triangles[b].get_center().y; });
	std::sort(indices_z, indices_z + bvh.triangle_count, [&](int a, int b) { return bvh.triangles[a].get_center().z < bvh.triangles[b].get_center().z; });
		
	int * indices_3[3] = { indices_x, indices_y, indices_z };
		
	float * sah = new float[bvh.triangle_count];

	int * temp = new int[bvh.triangle_count];

	int node_index = 2;
	build_bvh(bvh.nodes[0], bvh.triangles, indices_3, bvh.nodes, node_index, 0, bvh.triangle_count, sah, temp);

	bvh.indices = indices_x;
	delete [] indices_y;
	delete [] indices_z;

	assert(node_index <= 2 * bvh.triangle_count);

	bvh.node_count = node_index;
	bvh.index_count = bvh.triangle_count;

	delete [] temp;
	delete [] sah;
}

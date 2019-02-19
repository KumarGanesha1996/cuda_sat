#include <cstdint>
#include <cstdio>
#include <vector>

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
	if (code != cudaSuccess) {
		fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		if (abort) exit(code);
	}
}

#define BATCH_SIZE 4096
#define WARPS_NB 10
#define abs8(n) ((n) & 0x7fu)
#define abs32(n) ((n) & 0x7fffffffu)

struct clause {
	/* Field 'flags':
	 *   0x01u - value of literal l[0] (taking into account the sign)
	 *   0x02u - value of literal l[1] (taking into account the sign)
	 *   0x04u - value of literal l[2] (taking into account the sign)
	 *   0x08u - literal l[0] was assigned a value
	 *   0x10u - literal l[1] was assigned a value
	 *   0x20u - literal l[2] was assigned a value
	 * Satisfied if: (flags & 0x07u) != 0x00u
	 * Has literals: (flags & 0x38u) != 0x38u
	 * Invalid if:   (flags & 0x3fu) == 0x2au
	 */
	int8_t l[3];
	uint8_t flags;
#define c_sat(c) (((c).flags & 0x07u) != 0x00u)
#define c_has(c) (((c).flags & 0x38u) != 0x38u)
#define c_inv(c) (((c).flags & 0x3fu) == 0x38u)
};

/************************* PREPROCESS ****************************/

__global__ void preprocess(clause *d_f1, unsigned int *d_v, int r) {
	int warp_id = WARPS_NB * blockIdx.x + (threadIdx.x >> 5); // check
	int lane_id = threadIdx.x & 31;
	clause *formula = d_f1 + warp_id * r;
	unsigned int *valid = d_v + warp_id; // check

	// dodac ifa jezeli jestesmy warpem niezerowym? on juz ma te dane przeciez?
	// o nie... musi byc osobna tablica... co jak warp 0 juz zabierze sie do roboty?
	for(int i = threadIdx.x & 31; i < r; ++i) {
		formula[i] = d_f1[i];
	}

	int number = warp_id;

	while(number) { // check
		int tmp = number / 3;
		int branch_id = number - 3 * tmp;
		number = tmp;
		clause fc;
		bool fc_found = false;
		unsigned int mask1 = 0xffffffffu; // check

		for(int i = lane_id; true; i += 32) {
			mask1 = __ballot_sync(mask1, i < r); // check for second loop

			if(i >= r) {
				break;
			}

			clause cl = formula[i];

			if(!fc_found) {
				int has_literals = c_has(cl); // check and/or improve
				int mask2 = __ballot_sync(mask1, has_literals); // check if it is OK

				if(!mask2) {
					continue;
				}

				fc_found = true;
				int *ptr_cl = (int *) &cl;
				int src_lane_id = __ffs(mask2) - 1;
				tmp = __shfl_sync(mask1, *ptr_cl, src_lane_id);
				fc = *((clause *) &tmp);

				if(!(fc.flags & (0x08u << branch_id))) {
					if(lane_id == 0) {
						*valid = 0;
					}

					return;
				}
			}

			for(int l = 0; l < 3; ++l) {
				for(int x = 0; x < branch_id; ++x) {
					if(!(cl.flags & (0x08u << l)) && abs8(cl.l[l]) == abs8(fc.l[x])) {
						cl.flags |= (0x08u + (fc.l[x] < 0)) << l;
					}
				}

				if(cl.l[l] == fc.l[branch_id]) {
					cl.flags |= (0x08u + (fc.l[branch_id] > 0)) << l;
				}
			}

			if(__any_sync(0xffffffffu, c_inv(cl))) {
				if(lane_id == 0) {
					*valid = 0;
				}

				return;
			}

			formula[i] = cl;
		}

		if(!fc_found) {
			// whole formula satisfied! I think...
			return;
		}
	}
}

/************************* SAT_KERNEL ****************************/

/* Triples the number of formulas in a batch and marks invalid/missing ones
 * 
 * d_f - array of formulas and a free space for new formulas
 * d_v - array of flags indicating whether a formula is valid or not
 * k - number of formulas to triple
 * r - total number of clauses
 */
__global__ void sat_kernel(clause *d_f1, clause *d_f2, unsigned int *d_v, int k, int r) {
	int lane_id = threadIdx.x & 31;
	int warp_id = WARPS_NB * blockIdx.x + (threadIdx.x >> 5);
	int formula_id = warp_id / 3;
	int branch_id = warp_id - 3 * formula_id;
	unsigned int *valid = d_v + k * branch_id + formula_id;
	clause *formula = d_f1 + formula_id * r;
	clause *destination = d_f2 + (branch_id * k + formula_id) * r;
	clause fc = formula[0]; // this might be slow, use __shfl_sync()?

	// check
	if(!(fc.flags & (0x08u << branch_id))) {
		if(lane_id == 0) {
			*valid = 0;
		}

		return;
	}

	for(int i = lane_id; i < r; i += 32) {
		clause cl = formula[i];

		if(c_sat(cl)) { // sprawdzic czy jest dobrze: jak jest nullowalna, to uciekaj
			break;
		}

		for(int l = 0; l < 3; ++l) {
			for(int x = 0; x < branch_id; ++x) {
				if(!(cl.flags & (0x08u << l)) && abs8(cl.l[l]) == abs8(fc.l[x])) {
					cl.flags |= (0x08u + (fc.l[x] < 0)) << l;
				}
			}

			if(cl.l[l] == fc.l[branch_id]) {
				cl.flags |= (0x08u + (fc.l[branch_id] > 0)) << l;
			}
		}

		// check
		if(__any_sync(0xffffffffu, c_inv(cl))) {
			if(lane_id == 0) {
				*valid = 0;
			}

			return;
		}

		destination[i] = cl;
	}
}

/*************************** SCAN_1D *****************************/

__device__ unsigned int id = 0;
__device__ unsigned int d_p[32];
__device__ unsigned int valid_f;

__inline__ __device__ unsigned int warp_scan(unsigned int v) {
	int lane_id = threadIdx.x & 31;

	for(int i = 1; i < 32; i <<= 1) {
		int _v = __shfl_up_sync(0xffffffffu, v, i);

		if(lane_id >= i) {
			v += abs32(_v);
		}
	}

	return v;
}

__global__ void scan_1d(unsigned int *d_v, int k, int range_parts, int range) {
	__shared__ unsigned int partials[33];
	__shared__ unsigned int prev;
	int tid = blockIdx.x * range + threadIdx.x;
	int warp_id = threadIdx.x >> 5;
	int lane_id = threadIdx.x & 31;

	if(tid == 0) {
		partials[0] = 0;
		prev = 0;
	}

	__syncthreads();

	for(int i = 0; i < range_parts && tid < k; tid += 1024) {
		unsigned int v = warp_scan(d_v[tid]);

		if(lane_id == 31) {
			partials[warp_id + 1] = v;
		}

		__syncthreads();

		if(warp_id == 0) {
			partials[lane_id] = warp_scan(partials[lane_id]);
		}

		__syncthreads();

		d_v[tid] = v + prev;

		__syncthreads();

		if((tid & 1023) == 1023) {
			prev = abs32(v);
		}
	}

	if((tid & 1023) == 1023) {
		d_p[blockIdx.x] = prev;
		__threadfence();

		if(atomicAdd(&id, 1) == gridDim.x - 1) {
			id = 0;
			d_p[lane_id] = warp_scan(d_p[lane_id]);
		}
	}
}

__global__ void propagate_1d(unsigned int *d_v, int k, int range_parts, int range) {
	__shared__ int prev;
	int tid = (blockIdx.x + 1) * range + threadIdx.x;

	if(threadIdx.x == 0) {
		prev = d_p[blockIdx.x];
	}

	__syncthreads();

	unsigned int v;

	for(int i = 0; i < range_parts && tid < k; tid += 1024) {
		v = d_v[tid] += prev;
	}

	if(tid == k + 1023) {
		valid_f = v;
	}
}

/************************** SCATTER_1D ***************************/

__global__ void scatter_1d(clause *d_f1, clause *d_f2, int *d_v, int k, int r) {
	int warp_id = (blockIdx.x << 5) + (threadIdx.x >> 5);
	unsigned int p = d_v[warp_id];
	unsigned int valid = p & 0x80000000u;
	clause *formula = d_f2 + warp_id * r;
	clause *destination = d_f1 + (valid ? abs32(p) - 1 : valid_f + warp_id - abs32(p)) * r;

	for(int i = threadIdx.x & 31; i < r; i += 32) {
		destination[i] = formula[i];
	}
}

/*************************** SCAN_2D *****************************/

__inline__ __device__ unsigned int warp_scan(unsigned int v, int reminder, int lane_id) {
	for(int i = 1; i < 32; i <<= 1) {
		int _v = __shfl_up_sync(0xffffffffu, v, i);

		if(lane_id >= i && i <= reminder) { // chyba dobrze
			v += abs32(_v);
		}
	}

	return v;
}

__global__ void scan_2d(clause *d_f1, int *d_v, int k, int r, int range_parts, int range) {
	__shared__ int partials[33];
	__shared__ int prev;
	int tid = blockIdx.x * range + threadIdx.x;
	int warp_id = threadIdx.x >> 5;
	int lane_id = threadIdx.x & 31;
	int range_start = tid;

	if(tid == 0) {
		partials[0] = 0;
		prev = 0;
	}

	__syncthreads();

	for(int i = 0; i < range_parts && tid < k; tid += 1024) {
		int reminder = tid % r; // da sie ifami, ale remainder zwiekszam o 1024%r if(remainder >= r) { remainder -= r; }
	clause cl = d_f1[tid];
	unsigned int satisfied = c_sat(cl) ? 0 : 0x80000001u;
	unsigned int v = warp_scan(satisfied, reminder, lane_id);

	if(lane_id == 31) {
		partials[warp_id + 1] = v;
	}

	__syncthreads();

	if(warp_id == 0) {
		partials[lane_id] = warp_scan(partials[lane_id]);
	}

	__syncthreads();

	if(tid - range_start <= reminder) { // chyba dobrze
		d_v[tid] = v + prev;
	}

	__syncthreads();

	if((tid & 1023) == 1023) {
		prev = abs32(v);
	}
	}

	if((tid & 1023) == 1023) {
		d_p[blockIdx.x] = prev;
		__threadfence();

		if(atomicAdd(&id, 1) == gridDim.x - 1) {
			id = 0;
			d_p[lane_id] = warp_scan(d_p[lane_id]);
		}
	}
}

// NIE MA 2D_PROPAGATE

/************************** SCATTER_2D ***************************/

__global__ void scatter_2d(clause *d_f1, clause *d_f2, int *d_v, int r) {
	int warp_id = (blockIdx.x << 5) + (threadIdx.x >> 5);
	int shift = warp_id * r;
	int *position = d_v + shift;
	clause *formula = d_f1 + shift;
	clause *destination = d_f2 + shift;

	for(int i = threadIdx.x & 31; i < r; i += 32) {
		int p = position[i]; // check!
		unsigned int satisfied = p & 0x80000000u; // check!
		destination[satisfied ? p - 1 : valid_f + warp_id - p] = formula[i];
	}
}

/**************************** SWAP *******************************/

__managed__ bool formula_satisfied = false; // pewnie wyzej umiescic i sprawdzic kiedys???

void swap() {

}

/************************** PIPELINE *****************************/

void pipeline(std::vector<clause> &formulas, int n, int r, int s) {
	// in main
}

/************************ EXTRACT_VARS ***************************/

// from a formula, extracts variables

void extract_vars(clause *formula, int r, std::vector<bool> &assignment) {
	for(int i = 0; i < r; ++i) {
		for(int j = 0; j < 3; ++j) {
			int8_t var = formula[i].l[j];
			bool val = formula[i].flags & (0x01u << j);
			bool set = formula[i].flags & (0x08u << j);

			if(set) {
				assignment[abs8(var)] = (var < 0) ^ val; 
			}
		}
	}
}

void print_formula(clause *formula, int r) {
	for(int i = 0; i < r; ++i) {
		uint8_t *ptr = (uint8_t *) &formula[i];

		for(int j = 0; j < sizeof(clause); ++j) {
			for(int k = 0; k < 8; ++k) {
				printf("%d", (ptr[j] >> 7-k) & 1);
			}

			printf(" ");
		}

		printf("\n");
	}

	printf("\n");
}

/**************************** MAIN *******************************/

int main() {
	int n, r;
	scanf("%d %d", &n, &r);
	// int nb_of_formulas = 1;
	int s = 1;

	while(3 * s <= BATCH_SIZE) {
		s *= 3;
	}

	std::vector<clause> formulas(BATCH_SIZE * r);

	for(int i = 0; i < r; ++i) {
		int j = 0;

		while(j < 3) {
			int var;
			scanf("%d", &var);

			if(var == 0) {
				break;
			}

			formulas[i].l[j] = (int8_t) var;
			++j;
		}

		while(j < 3) {
			formulas[i].flags &= 0x8u << j;
			++j;
		}
	}

	print_formula(formulas.data(), r);

	/*
	   int parts = (n + 32 * 1024 - 1) / (32 * 1024);
	   int range = parts * 1024;
	   int blocks = (n + range - 1)/range;
	   int *d_values, *d_groups, *d_groups_original;
	 */

	/*
	   clause *d_f1;
	   clause *d_f2;
	   unsigned int *d_v;
	   cudaMallocHost(&d_f1, BATCH_SIZE * r * sizeof(clause));
	   cudaMallocHost(&d_f2, BATCH_SIZE * r * sizeof(clause));
	   cudaMallocHost(&d_v, BATCH_SIZE * sizeof(unsigned int));
	   cudaMemcpyAsync(&d_f1, formulas.data(), r * sizeof(clause), cudaMemcpyDefault);

	   preprocess<<<0, 0>>>(d_f1, d_f2, d_v, s, r);

	   while(true) {
	   scan_1d<<<0, 0>>>(d_v, s, range_parts, range); // check nb_of_formulas
	// jezeli blokow jest 1, to nie rob propagate
	scatter_1d<<<0, 1024>>>(d_f1);
	scan_1d<<<0, 1024>>>(d_f1, d_v, range_parts, range);
	scatter_1d<<<0, 1024>>>(d_f1, d_f2, d_v, r);
	swap();
	sat_kernel<<<0, 0>>>(d_f1, d_f2, d_v, BATCH_SIZE, r);
	}

	cudaFree(d_f1);
	cudaFree(d_f2);
	cudaFree(d_v);
	 */
	/*
	   fill_groups<<<(m + 1023)/1024, 1024>>>(d_groups, d_groups_original, m);
	   block_prefix_scan<<<blocks, 1024>>>(d_values, d_groups, n, parts, range);
	 */
}


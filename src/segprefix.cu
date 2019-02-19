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
	uint8_t l[3];
	uint8_t flags;
#define c_sat(c) (((c).flags & 0x07u) != 0x00u)
#define c_has(c) (((c).flags & 0x38u) != 0x38u)
#define c_inv(c) (((c).flags & 0x3fu) == 0x38u)
};

__managed__ bool formula_satisfied = false;

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
						cl.flags |= (0x08u + ((fc.l[x] & 0x80u) == 0x80u)) << l;
					}
				}

				if(cl.l[l] == fc.l[branch_id]) {
					cl.flags |= (0x08u + ((fc.l[branch_id] & 0x80u) == 0)) << l;
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
					cl.flags |= (0x08u + ((fc.l[x] & 0x80u) == 0x80u)) << l;
				}
			}

			if(cl.l[l] == fc.l[branch_id]) {
				cl.flags |= (0x08u + ((fc.l[branch_id] & 0x80u) == 0)) << l;
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
__managed__ unsigned int nb_of_valid;

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

		// sprawdzic czy to zadziala <3
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
		nb_of_valid = v;
	}
}

/************************** SCATTER_1D ***************************/

__global__ void scatter_1d(clause *d_f1, clause *d_f2, int *d_v, int r) {
	int warp_id = (blockIdx.x << 5) + (threadIdx.x >> 5);
	unsigned int p = d_v[warp_id];
	unsigned int valid = p & 0x80000000u;
	clause *formula = d_f2 + warp_id * r;
	clause *destination = d_f1 + (valid ? abs32(p) - 1 : nb_of_valid + warp_id - abs32(p)) * r;

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
		// da sie ifami, ale remainder zwiekszam o 1024%r if(remainder >= r) { remainder -= r; }
		int reminder = tid % r;
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

// NIE MA 2D_PROPAGATE :<

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
		destination[satisfied ? p - 1 : nb_of_valid + warp_id - p] = formula[i];
	}
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

		for(int j = 0; j < 4; ++j) {
			for(int k = 0; k < 8; ++k) {
				printf("%d", (ptr[j] >> 7-k) & 1);
			}

			printf(" ");
		}

		printf(" - ");

		for(int j = 0; j < 3; ++j) {
			if(ptr[j] & 0x80u) {
				printf("%d", -abs8(ptr[j]));
			} else {
				printf("%d", ptr[j]);
			}

			if(j != 2) {
				printf("\t");
			}
		}

		printf("\n");
	}

	printf("\n");
}

/**************************** SWAP *******************************/

void swap() {

}

/************************** PIPELINE *****************************/

void pipeline(std::vector<clause> &storage, int n, int r, int s) {
	int nb_of_formulas = s;
	clause *d_f1;
	clause *d_f2;
	unsigned int *d_v;
	gpuErrchk(cudaMallocHost(&d_f1, s * r * sizeof(clause)));
	gpuErrchk(cudaMallocHost(&d_f2, s * r * sizeof(clause)));
	gpuErrchk(cudaMallocHost(&d_v, s * sizeof(unsigned int)));
	gpuErrchk(cudaMemcpy(&d_f1, storage.data(), r * sizeof(clause), cudaMemcpyDefault));
	storage.resize(0);

	// spawns ceil(s/32) warps, each warp generating a singe new formula
	preprocess<<<(nb_of_formulas + 31)/32, 1024>>>(d_f1, d_f2, d_v, nb_of_formulas, r);

	// czy powinna zwrocic prawdziwe 's'?

	while(nb_of_formulas) { // check
		std::swap(d_f1, d_f2);
		// jak ma sie to blokowanie do warunku w while-u?
		gpuErrchk(cudaDeviceSynchronize());

		if(formula_satisfied) {
			// DO SOMETHING
			return;
		}

		int range_parts = (nb_of_formulas + 32 * 1024 - 1) / (32 * 1024); // check
		int range = parts * 1024;
		int blocks = (s + range - 1) / range;
		scan_1d<<<blocks, 1024>>>(d_v, s, range_parts, range);

		if(blocks > 1) {
			propagate_1d<<<blocks - 1, 1024>>>(d_v, range_parts, range); 
		}

		scatter_1d<<<(nb_of_formulas + 31) / 32, 1024>>>(d_f1, d_f2, d_v, r);
		gpuErrchk(cudaDeviceSynchronize());

		nb_of_formulas = nb_of_valid;
		range_parts = (r * nb_of_formulas + 32 * 1024 - 1) / (32 * 1024); // check
		range = parts * 1024;
		blocks = (s + range - 1) / range;

		scan_2d<<<blocks, 1024>>>(d_v, r * nb_of_formulas, range_parts, range); // check

		if(blocks > 1) {
			propagate_2d<<<blocks - 1, 1024>>>(d_f1, d_f2, d_v, r); // check order
		}

		scatter_2d<<<(nb_of_formulas + 31) / 32, 1024>>>(d_f1, d_f2, d_v, r);

		int surplus = nb_of_formulas - s/3;

		if(surplus > 0) {
			int transfer = surplus * r;
			storage.resize(storage.size() + transfer);
			clause *dst = storage.data() + storage.size() - transfer;
			clause *src = d_f1 + nb_of_formulas * r - transfer;
			gpuErrchk(cudaMemcpy(dst, src, transfer * sizeof(clause), cudaMemcpyDefault));
			nb_of_formulas -= surplus;
		}

		if(surplus < 0) {
			int transfer = -surplus * r;
			clause *dst = d_f1 + nb_of_formulas * r;
			clause *src = storage.data() + storage.size() - transfer;
			gpuErrchk(cudaMemcpy(dst, src, transfer * sizeof(clause), cudaMemcpyDefault));
			storage.resize(storage.size() - transfer);
			nb_of_formulas += -surplus;
		}

		sat_kernel<<<(nb_of_formulas + 31) / 32, 32 * WARPS_NB>>>(d_f1, d_f2, d_v, nb_of_formulas, r);
		// czy nie blokujemy?
	}

	cudaFree(d_f1);
	cudaFree(d_f2);
	cudaFree(d_v);
}

/**************************** MAIN *******************************/

int main() {
	int n, r;
	scanf("%d %d", &n, &r);
	int s = 1;

	while(3 * s <= BATCH_SIZE) {
		s *= 3;
	}

	std::vector<clause> formulas(BATCH_SIZE * r);

	for(int i = 0; i < r; ++i) {
		int j = 0;

		while(j < 4) {
			int var;
			scanf("%d", &var);

			if(j == 3 || var == 0) {
				break;
			}

			if(var > 0) {
				formulas[i].l[j] = (int8_t) var;
			} else {
				formulas[i].l[j] = (int8_t) -var | 0x80u;
			}

			++j;
		}

		while(j < 3) {
			formulas[i].flags &= 0x8u << j;
			++j;
		}
	}

	print_formula(formulas.data(), r);
	pipeline(formulas, n, r, s);

}

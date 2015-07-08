/*
* Genoil's CUDA mining kernel for Ethereum
* based on Tim Hughes' opencl kernel.
* thanks to trpuvot,djm34,sp,cbuchner for things i took from ccminer.
*/

#include "ethash_cu_miner_kernel.h"
#include "ethash_cu_miner_kernel_globals.h"
#include "rotl64.cuh"
#include "device_launch_parameters.h"
#include "device_functions.h"
#include "vector_types.h"

#define ACCESSES 64
#define THREADS_PER_HASH (128 / 16)

#define FNV_PRIME	0x01000193

// Thanks for Lukas' code here
/*
#define SWAP64(n)					\
  (((n) << 56)						\
   | (((n) & 0xff00) << 40)			\
   | (((n) & 0xff0000) << 24)		\
   | (((n) & 0xff000000) << 8)		\
   | (((n) >> 8) & 0xff000000)		\
   | (((n) >> 24) & 0xff0000)		\
   | (((n) >> 40) & 0xff00)			\
   | ((n)  >> 56))
*/

#define SWAP64(v) \
  ((ROTL64L(v,  8) & 0x000000FF000000FF) | \
   (ROTL64L(v, 24) & 0x0000FF000000FF00) | \
   (ROTL64H(v, 40) & 0x00FF000000FF0000) | \
   (ROTL64H(v, 56) & 0xFF000000FF000000))

#define PACK64(result, lo, hi) asm("mov.b64 %0, {%1,%2};//pack64"  : "=l"(result) : "r"(lo), "r"(hi));
#define UNPACK64(lo, hi, input) asm("mov.b64 {%0, %1}, %2;//unpack64" : "=r"(lo),"=r"(hi) : "l"(input));


__device__ __constant__ uint64_t const keccak_round_constants[24] = {
	0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808AULL,
	0x8000000080008000ULL, 0x000000000000808BULL, 0x0000000080000001ULL,
	0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008AULL,
	0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000AULL,
	0x000000008000808BULL, 0x800000000000008BULL, 0x8000000000008089ULL,
	0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
	0x000000000000800AULL, 0x800000008000000AULL, 0x8000000080008081ULL,
	0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

__device__ static void keccak_f1600_block(uint64_t* s, uint32_t out_size)//, uint32_t in_size, uint32_t out_size)
{
	uint64_t t[5], u, v;

	for (size_t i = 0; i < 24; i++) {
		/* theta: c = a[0,i] ^ a[1,i] ^ .. a[4,i] */
		t[0] = s[0] ^ s[5] ^ s[10] ^ s[15] ^ s[20];
		t[1] = s[1] ^ s[6] ^ s[11] ^ s[16] ^ s[21];
		t[2] = s[2] ^ s[7] ^ s[12] ^ s[17] ^ s[22];
		t[3] = s[3] ^ s[8] ^ s[13] ^ s[18] ^ s[23];
		t[4] = s[4] ^ s[9] ^ s[14] ^ s[19] ^ s[24];

		/* theta: d[i] = c[i+4] ^ rotl(c[i+1],1) */
		/* theta: a[0,i], a[1,i], .. a[4,i] ^= d[i] */
		u = t[4] ^ ROTL64L(t[1], 1);
		s[0] ^= u; s[5] ^= u; s[10] ^= u; s[15] ^= u; s[20] ^= u;
		u = t[0] ^ ROTL64L(t[2], 1);
		s[1] ^= u; s[6] ^= u; s[11] ^= u; s[16] ^= u; s[21] ^= u;
		u = t[1] ^ ROTL64L(t[3], 1);
		s[2] ^= u; s[7] ^= u; s[12] ^= u; s[17] ^= u; s[22] ^= u;
		u = t[2] ^ ROTL64L(t[4], 1);
		s[3] ^= u; s[8] ^= u; s[13] ^= u; s[18] ^= u; s[23] ^= u;
		u = t[3] ^ ROTL64L(t[0], 1);
		s[4] ^= u; s[9] ^= u; s[14] ^= u; s[19] ^= u; s[24] ^= u;
		 
		/* rho pi: b[..] = rotl(a[..], ..) */
		u = s[1];

		s[1] = ROTL64H(s[6], 44);
		s[6] = ROTL64L(s[9], 20);
		s[9] = ROTL64H(s[22], 61);
		s[22] = ROTL64H(s[14], 39);
		s[14] = ROTL64L(s[20], 18);
		s[20] = ROTL64H(s[2], 62);
		s[2] = ROTL64H(s[12], 43);
		s[12] = ROTL64L(s[13], 25);
		s[13] = ROTL64L(s[19], 8);
		s[19] = ROTL64H(s[23], 56);
		s[23] = ROTL64H(s[15], 41);
		s[15] = ROTL64L(s[4], 27);
		s[4] = ROTL64L(s[24], 14);
		s[24] = ROTL64L(s[21], 2);
		s[21] = ROTL64H(s[8], 55);
		s[8] = ROTL64H(s[16], 45);
		s[16] = ROTL64H(s[5], 36);
		s[5] = ROTL64L(s[3], 28);
		s[3] = ROTL64L(s[18], 21);
		s[18] = ROTL64L(s[17], 15);
		s[17] = ROTL64L(s[11], 10);
		s[11] = ROTL64L(s[7], 6);
		s[7] = ROTL64L(s[10], 3);
		s[10] = ROTL64L(u, 1);

		/* chi: a[i,j] ^= ~b[i,j+1] & b[i,j+2] */
		u = s[0]; v = s[1]; s[0] ^= (~v) & s[2]; 
		
		// squeeze this in here
		/* iota: a[0,0] ^= round constant */
		s[0] ^= keccak_round_constants[i];

		// continue chi
		s[1] ^= (~s[2]) & s[3]; s[2] ^= (~s[3]) & s[4]; s[3] ^= (~s[4]) & u; s[4] ^= (~u) & v;
		if (i == 23 && out_size == 4) return;
		u = s[5]; v = s[6]; s[5] ^= (~v) & s[7]; s[6] ^= (~s[7]) & s[8]; s[7] ^= (~s[8]) & s[9]; 
		if (i == 23 && out_size == 8) return;
		s[8] ^= (~s[9]) & u; s[9] ^= (~u) & v;
		u = s[10]; v = s[11]; s[10] ^= (~v) & s[12]; s[11] ^= (~s[12]) & s[13]; s[12] ^= (~s[13]) & s[14]; s[13] ^= (~s[14]) & u; s[14] ^= (~u) & v;
		u = s[15]; v = s[16]; s[15] ^= (~v) & s[17]; s[16] ^= (~s[17]) & s[18]; s[17] ^= (~s[18]) & s[19]; s[18] ^= (~s[19]) & u; s[19] ^= (~u) & v;
		u = s[20]; v = s[21]; s[20] ^= (~v) & s[22]; s[21] ^= (~s[22]) & s[23]; s[22] ^= (~s[23]) & s[24]; s[23] ^= (~s[24]) & u; s[24] ^= (~u) & v;
	}
}

#define copy(dst, src, count) for (uint32_t i = 0; i < count; i++) { (dst)[i] = (src)[i]; }

#define countof(x) (sizeof(x) / sizeof(x[0]))

#define fnv(x,y) ((x) * FNV_PRIME ^(y))

__device__ uint4 fnv4(uint4 a, uint4 b)
{
	uint4 c;
	c.x = a.x * FNV_PRIME ^ b.x;	
	c.y = a.y * FNV_PRIME ^ b.y;
	c.z = a.z * FNV_PRIME ^ b.z;
	c.w = a.w * FNV_PRIME ^ b.w;
	return c;
}

__device__ uint32_t fnv_reduce(uint4 v)
{
	return fnv(fnv(fnv(v.x, v.y), v.z), v.w);
}

__device__ hash64_t init_hash(hash32_t const* header, uint64_t nonce)
{
	hash64_t init;

	// sha3_512(header .. nonce)
	uint64_t state[25];

	copy(state, header->uint64s, 4);
	state[4] = nonce;
	state[5] = 0x0000000000000001;
	state[6] = 0;
	state[7] = 0;
	state[8] = 0x8000000000000000;
	for (uint32_t i = 9; i < 25; i++)
	{
		state[i] = 0;
	}
	
	keccak_f1600_block(state, 8);
	copy(init.uint64s, state, 8);
	return init;
}

__device__ uint32_t inner_loop(uint4 mix, uint32_t thread_id, uint32_t* share, hash128_t const* g_dag)
{
	// share init0
	if (thread_id == 0)
		*share = mix.x;

	uint32_t init0 = *share;
	
	uint32_t a = 0;

	do
	{
		
		bool update_share = thread_id == ((a >> 2) & (THREADS_PER_HASH-1));

		//#pragma unroll 4
		for (uint32_t i = 0; i < 4; i++)
		{

			if (update_share)
			{
				uint32_t m[4] = { mix.x, mix.y, mix.z, mix.w };
				*share = fnv(init0 ^ (a + i), m[i]) % d_dag_size;
			}
			__threadfence_block();

#if __CUDA_ARCH__ >= 350
			mix = fnv4(mix, __ldg(&g_dag[*share].uint4s[thread_id]));
#else
			mix = fnv4(mix, g_dag[*share].uint4s[thread_id]);
#endif
			
		}
		
	} while ((a += 4) != ACCESSES);
	
	return fnv_reduce(mix);
}

__device__ hash32_t final_hash(hash64_t const* init, hash32_t const* mix)
{
	uint64_t state[25];

	hash32_t hash;

	// keccak_256(keccak_512(header..nonce) .. mix);
	copy(state, init->uint64s, 8);
	copy(state + 8, mix->uint64s, 4);
	state[12] = 0x0000000000000001;
	for (uint32_t i = 13; i < 16; i++)
	{
		state[i] = 0;
	}
	state[16] = 0x8000000000000000;
	for (uint32_t i = 17; i < 25; i++)
	{
		state[i] = 0;
	}

	keccak_f1600_block(state,4);

	// copy out
	copy(hash.uint64s, state, 4);
	return hash;
}

typedef union
{
	hash64_t init;	
	hash32_t mix;
} compute_hash_share;



__device__ hash32_t compute_hash_shuffle(
	hash32_t const* g_header,
	hash128_t const* g_dag,
	uint64_t nonce
	)
{
	uint32_t s0,i0;
	uint32_t s1,i1;
	uint32_t s2,i2;
	uint32_t s3,i3;
	uint32_t s4,i4;
	uint32_t s5,i5;
	uint32_t s6,i6;
	uint32_t s7,i7;
	uint32_t s8,i8;
	uint32_t s9,i9;
	uint32_t s10,i10;
	uint32_t s11,i11;
	uint32_t s12,i12;
	uint32_t s13,i13;
	uint32_t s14,i14;
	uint32_t s15,i15;

	// sha3_512(header .. nonce)
	uint64_t state[25];

	copy(state, g_header->uint64s, 4);
	state[4] = nonce;
	state[5] = 0x0000000000000001;
	for (uint32_t i = 6; i < 25; i++)
	{
		state[i] = 0;
	}
	state[8] = 0x8000000000000000;
	keccak_f1600_block(state, 8);

	UNPACK64(i0, i1,	state[0]);
	UNPACK64(i2, i3,	state[1]);
	UNPACK64(i4, i5,	state[2]);
	UNPACK64(i6, i7,	state[3]);
	UNPACK64(i8, i9,	state[4]);
	UNPACK64(i10, i11,	state[5]);
	UNPACK64(i12, i13,	state[6]);
	UNPACK64(i14, i15,	state[7]);

	// Threads work together in this phase in groups of 8.
	uint32_t const thread_id = threadIdx.x & (THREADS_PER_HASH - 1);
	uint32_t const hash_id = threadIdx.x >> 3;

	int i = 0;
	int start_lane = hash_id << 3;

	do
	{
		s0 = __shfl(i0, start_lane + i);
		s1 = __shfl(i1, start_lane + i);
		s2 = __shfl(i2, start_lane + i);
		s3 = __shfl(i3, start_lane + i);
		s4 = __shfl(i4, start_lane + i);
		s5 = __shfl(i5, start_lane + i);
		s6 = __shfl(i6, start_lane + i);
		s7 = __shfl(i7, start_lane + i);
		s8 = __shfl(i8, start_lane + i);
		s9 = __shfl(i9, start_lane + i);
		s10 = __shfl(i10, start_lane + i);
		s11 = __shfl(i11, start_lane + i);
		s12 = __shfl(i12, start_lane + i);
		s13 = __shfl(i13, start_lane + i);
		s14 = __shfl(i14, start_lane + i);
		s15 = __shfl(i15, start_lane + i);

		uint4 mix;
		uint32_t t3 = thread_id & 3;
		if (t3 == 0) {
			mix = make_uint4(s0, s1, s2, s3);
		}
		else if (t3 == 1) {
			mix = make_uint4(s4, s5, s6, s7);
		}
		else if (t3 == 2) {
			mix = make_uint4(s8, s9, s10, s11);
		}
		else {
			mix = make_uint4(s12, s13, s14, s15);
		}
			
		s0 = (uint32_t)__shfl((int)(mix.x), start_lane);

		//uint32_t thread_mix = inner_loop_shuffle(thread_init, thread_id, &s0, g_dag, start_lane);

		uint32_t init0 = s0;
		uint32_t a = 0;

		do
		{
			int t = ((a >> 2) & (THREADS_PER_HASH - 1));

			//#pragma unroll 4
			for (uint32_t i = 0; i < 4; i++)
			{
				if (thread_id == t)
				{
					uint32_t m[4] = { mix.x, mix.y, mix.z, mix.w };
					s0 = fnv(init0 ^ (a + i), m[i]) % d_dag_size;
				}
				s0 = (uint32_t)__shfl((int)s0, start_lane + t);

#if __CUDA_ARCH__ >= 350
				mix = fnv4(mix, __ldg(&g_dag[s0].uint4s[thread_id]));
#else
				mix = fnv4(mix, g_dag[s0].uint4s[thread_id]);
#endif

			}

		} while ((a += 4) != ACCESSES);

		uint32_t thread_mix = fnv_reduce(mix);

		// update mix
		s0 = __shfl(thread_mix, start_lane + 0);
		s1 = __shfl(thread_mix, start_lane + 1);
		s2 = __shfl(thread_mix, start_lane + 2);
		s3 = __shfl(thread_mix, start_lane + 3);
		s4 = __shfl(thread_mix, start_lane + 4);
		s5 = __shfl(thread_mix, start_lane + 5);
		s6 = __shfl(thread_mix, start_lane + 6);
		s7 = __shfl(thread_mix, start_lane + 7);

		if (i == thread_id) {	
			//move mix into state:
			PACK64(state[8], s0, s1);
			PACK64(state[9], s2, s3);
			PACK64(state[10], s4, s5);
			PACK64(state[11], s6, s7);
		}
		
	} while (++i != THREADS_PER_HASH);

	hash32_t hash;

	// keccak_256(keccak_512(header..nonce) .. mix);
	state[12] = 0x0000000000000001;
	for (uint32_t i = 13; i < 25; i++)
	{
		state[i] = 0;
	}
	state[16] = 0x8000000000000000;
	keccak_f1600_block(state, 4);

	// copy out
	copy(hash.uint64s, state, 4);
	return hash;
}

__device__ hash32_t compute_hash(
	hash32_t const* g_header,
	hash128_t const* g_dag,
	uint64_t nonce
	)
{
	extern __shared__  compute_hash_share share[];

	// Compute one init hash per work item.
	hash64_t init = init_hash(g_header, nonce);

	// Threads work together in this phase in groups of 8.
	uint32_t const thread_id = threadIdx.x & (THREADS_PER_HASH-1);
	uint32_t const hash_id   = threadIdx.x >> 3;

	hash32_t mix;
	uint32_t i = 0;
	
	do
	{
		// share init with other threads
		if (i == thread_id)
			share[hash_id].init = init;
		
		uint4 thread_init = share[hash_id].init.uint4s[thread_id & 3];
		
		uint32_t thread_mix = inner_loop(thread_init, thread_id, share[hash_id].mix.uint32s, g_dag);

		share[hash_id].mix.uint32s[thread_id] = thread_mix;
		

		if (i == thread_id)
			mix = share[hash_id].mix;
		

	} while (++i != THREADS_PER_HASH );

	return final_hash(&init, &mix);
}

__global__ void 
__launch_bounds__(128, 7)
ethash_search(
	uint32_t* g_output,
	hash32_t const* g_header,
	hash128_t const* g_dag,
	uint64_t start_nonce,
	uint64_t target
	)
{

	uint32_t const gid = blockIdx.x * blockDim.x + threadIdx.x;	
	//hash32_t hash = compute_hash(g_header, g_dag, start_nonce + gid);
	hash32_t hash = compute_hash_shuffle(g_header, g_dag, start_nonce + gid);

	if (SWAP64(hash.uint64s[0]) < target)
	{
		atomicInc(g_output,d_max_outputs);
		g_output[g_output[0]] = gid;
	}
	
}

void run_ethash_hash(
	hash32_t* g_hashes,
	hash32_t const* g_header,
	hash128_t const* g_dag,
	uint64_t start_nonce
) 
{
}

void run_ethash_search(
	uint32_t blocks,
	uint32_t threads,
	cudaStream_t stream,
	uint32_t* g_output,
	hash32_t const* g_header,
	hash128_t const* g_dag,
	uint64_t start_nonce,
	uint64_t target
)
{
//	ethash_search <<<blocks, threads, 0, stream >>>(g_output, g_header, g_dag, start_nonce, target);
	ethash_search <<<blocks, threads, (sizeof(compute_hash_share) * threads) / THREADS_PER_HASH, stream>>>(g_output, g_header, g_dag, start_nonce, target);
}

cudaError set_constants(
	uint32_t * dag_size,
	uint32_t * max_outputs
	)
{
	cudaError result;
	result = cudaMemcpyToSymbol(d_dag_size, dag_size, sizeof(uint32_t));
	result = cudaMemcpyToSymbol(d_max_outputs, max_outputs, sizeof(uint32_t));
	return result;
}

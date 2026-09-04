/*
 * gpu_bench - CUDA transfer bandwidth and FP32 throughput for local-bench.
 *
 * Reports the three numbers that actually bound a small-GPU workload: how fast
 * data crosses PCIe in each direction, how fast the device moves its own
 * memory, and sustained FP32 FMA throughput.
 *
 * usage: gpu_bench <h2d|d2h|d2d|fp32> <seconds>
 * output: transfer modes  RESULT <gib_per_sec> <checksum>
 *         fp32 mode       RESULT <gflops> <checksum>
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cuda_runtime.h>

#define CHECK(call)                                                            \
	do {                                                                   \
		cudaError_t _e = (call);                                       \
		if (_e != cudaSuccess) {                                       \
			fprintf(stderr, "cuda error: %s at line %d\n",         \
				cudaGetErrorString(_e), __LINE__);             \
			return 1;                                              \
		}                                                              \
	} while (0)

static double now_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Independent accumulators so the FMA pipelines stay saturated rather than
 * stalling on a single dependency chain. */
#define FMA_ITERS 512
__global__ void fma_kernel(float *out, float seed, int iters)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	/* Contractive coefficients keep all four chains near 1.0. An
	 * unbounded chain overflows to inf within a few thousand iterations,
	 * which makes the checksum useless as evidence the work really ran. */
	float a = 1.0f + (float)idx * 1e-6f;
	float c = a * 0.5f, d = a * 0.25f, e = a * 0.125f;
	for (int i = 0; i < iters; i++) {
		a = fmaf(a, 0.9999f, 0.0001f);
		c = fmaf(c, 0.9998f, 0.0002f);
		e = fmaf(e, 0.9997f, 0.0003f);
		d = fmaf(d, 0.9996f, 0.0004f);
	}
	out[idx] = a + c + e + d;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <h2d|d2h|d2d|fp32> <seconds>\n", argv[0]);
		return 2;
	}
	const char *mode = argv[1];
	double target = atof(argv[2]);
	if (target <= 0) {
		fprintf(stderr, "seconds must be > 0\n");
		return 2;
	}

	int ndev = 0;
	CHECK(cudaGetDeviceCount(&ndev));
	if (ndev < 1) {
		fprintf(stderr, "no CUDA device\n");
		return 1;
	}
	CHECK(cudaSetDevice(0));

	if (!strcmp(mode, "fp32")) {
		int blocks = 1024, threads = 256;
		int n = blocks * threads;
		float *d_out = NULL;
		CHECK(cudaMalloc(&d_out, n * sizeof(float)));
		/* Warm up so context creation and JIT are not timed. */
		fma_kernel<<<blocks, threads>>>(d_out, 1.0f, FMA_ITERS);
		CHECK(cudaDeviceSynchronize());

		long long launches = 0;
		double start = now_sec(), elapsed;
		do {
			fma_kernel<<<blocks, threads>>>(d_out, 1.0f, FMA_ITERS);
			CHECK(cudaDeviceSynchronize());
			launches++;
			elapsed = now_sec() - start;
		} while (elapsed < target);

		float host0 = 0;
		CHECK(cudaMemcpy(&host0, d_out, sizeof(float), cudaMemcpyDeviceToHost));
		cudaFree(d_out);
		/* 4 FMAs per inner iteration, 2 flops per FMA. */
		double flops = (double)launches * n * FMA_ITERS * 4.0 * 2.0;
		printf("RESULT %.6f %.0f\n", flops / elapsed / 1e9, (double)host0);
		return 0;
	}

	size_t bytes = 256ULL * 1024 * 1024;
	double gib = (double)bytes / (1024.0 * 1024.0 * 1024.0);
	long long passes = 0;
	double elapsed = 0.0;

	if (!strcmp(mode, "d2d")) {
		void *a = NULL, *b = NULL;
		CHECK(cudaMalloc(&a, bytes));
		CHECK(cudaMalloc(&b, bytes));
		CHECK(cudaMemset(a, 1, bytes));
		CHECK(cudaMemcpy(b, a, bytes, cudaMemcpyDeviceToDevice));
		CHECK(cudaDeviceSynchronize());
		double start = now_sec();
		do {
			CHECK(cudaMemcpy(b, a, bytes, cudaMemcpyDeviceToDevice));
			CHECK(cudaDeviceSynchronize());
			passes++;
			elapsed = now_sec() - start;
		} while (elapsed < target);
		cudaFree(a);
		cudaFree(b);
		/* Device-to-device moves the payload twice: once read, once written. */
		printf("RESULT %.6f 0\n", passes * gib * 2.0 / elapsed);
		return 0;
	}

	if (strcmp(mode, "h2d") && strcmp(mode, "d2h")) {
		fprintf(stderr, "unknown mode: %s\n", mode);
		return 2;
	}

	/* Pinned host memory: pageable transfers measure the driver's staging
	 * copy rather than the link itself. */
	void *h = NULL, *d = NULL;
	CHECK(cudaMallocHost(&h, bytes));
	CHECK(cudaMalloc(&d, bytes));
	memset(h, 1, bytes);
	int h2d = !strcmp(mode, "h2d");
	CHECK(cudaMemcpy(d, h, bytes, cudaMemcpyHostToDevice));
	CHECK(cudaDeviceSynchronize());

	double start = now_sec();
	do {
		if (h2d)
			CHECK(cudaMemcpy(d, h, bytes, cudaMemcpyHostToDevice));
		else
			CHECK(cudaMemcpy(h, d, bytes, cudaMemcpyDeviceToHost));
		CHECK(cudaDeviceSynchronize());
		passes++;
		elapsed = now_sec() - start;
	} while (elapsed < target);

	cudaFreeHost(h);
	cudaFree(d);
	printf("RESULT %.6f 0\n", passes * gib / elapsed);
	return 0;
}

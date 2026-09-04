/*
 * mem_bw - main-memory bandwidth and latency microbenchmarks for local-bench.
 *
 * Buffers are sized by the caller and are expected to be far larger than the
 * last-level cache, so these numbers describe DRAM rather than cache.
 *
 * usage: mem_bw <read|write|copy|triad|latency> <mib> <seconds>
 * output: bandwidth modes  RESULT <gib_per_sec> <checksum>
 *         latency mode     RESULT <ns_per_access> <checksum>
 *
 * For copy and triad, <mib> is the size of EACH buffer, not the total
 * footprint; bandwidth counts bytes read plus bytes written.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static double now_sec(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void *alloc_touched(size_t bytes)
{
	/* Page-aligned, and faulted in up front so the timed loop never pays
	 * for first-touch page faults. */
	void *p = NULL;
	if (posix_memalign(&p, 4096, bytes) != 0)
		return NULL;
	memset(p, 1, bytes);
	return p;
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "usage: %s <read|write|copy|triad|latency> <mib> <seconds>\n",
			argv[0]);
		return 2;
	}
	const char *mode = argv[1];
	size_t mib = (size_t)strtoull(argv[2], NULL, 10);
	double target = atof(argv[3]);
	if (mib == 0 || target <= 0) {
		fprintf(stderr, "mib and seconds must be > 0\n");
		return 2;
	}
	size_t bytes = mib * 1024ULL * 1024ULL;
	size_t n64 = bytes / sizeof(uint64_t);

	double checksum = 0.0;
	double elapsed = 0.0;
	uint64_t passes = 0;
	size_t bytes_per_pass = 0;

	if (!strcmp(mode, "latency")) {
		/* Pointer chase around one random cycle covering the whole
		 * buffer. Each step depends on the previous load, so the
		 * prefetcher cannot hide the latency. */
		size_t n = bytes / sizeof(size_t);
		size_t *idx = alloc_touched(bytes);
		if (!idx) {
			fprintf(stderr, "allocation of %zu bytes failed\n", bytes);
			return 1;
		}
		for (size_t i = 0; i < n; i++)
			idx[i] = i;
		/* Fisher-Yates then link into a single cycle, guaranteeing every
		 * element is visited exactly once. The shuffle uses a fixed-seed
		 * xorshift rather than libc random() so the access pattern is
		 * bit-identical on every machine and the latency figures stay
		 * comparable. */
		uint64_t rs = 88172645463325252ULL;
		for (size_t i = n - 1; i > 0; i--) {
			rs ^= rs << 13;
			rs ^= rs >> 7;
			rs ^= rs << 17;
			size_t j = (size_t)(rs % (uint64_t)(i + 1));
			size_t t = idx[i];
			idx[i] = idx[j];
			idx[j] = t;
		}
		size_t *next = alloc_touched(bytes);
		if (!next) {
			fprintf(stderr, "allocation of %zu bytes failed\n", bytes);
			return 1;
		}
		for (size_t i = 0; i < n; i++)
			next[idx[i]] = idx[(i + 1) % n];
		free(idx);

		size_t steps_per_pass = n;
		size_t p = 0;
		double start = now_sec();
		do {
			for (size_t i = 0; i < steps_per_pass; i++)
				p = next[p];
			passes++;
			elapsed = now_sec() - start;
		} while (elapsed < target);
		checksum = (double)p;
		free(next);
		printf("RESULT %.6f %.0f\n",
		       elapsed * 1e9 / ((double)passes * (double)steps_per_pass),
		       checksum);
		return 0;
	}

	uint64_t *a = alloc_touched(bytes);
	uint64_t *b = NULL;
	uint64_t *c = NULL;
	if (!a) {
		fprintf(stderr, "allocation of %zu bytes failed\n", bytes);
		return 1;
	}
	if (!strcmp(mode, "copy")) {
		b = alloc_touched(bytes);
		if (!b)
			goto oom;
		bytes_per_pass = 2 * bytes;
	} else if (!strcmp(mode, "triad")) {
		b = alloc_touched(bytes);
		c = alloc_touched(bytes);
		if (!b || !c)
			goto oom;
		bytes_per_pass = 3 * bytes;
	} else if (!strcmp(mode, "read") || !strcmp(mode, "write")) {
		bytes_per_pass = bytes;
	} else {
		fprintf(stderr, "unknown mode: %s\n", mode);
		return 2;
	}

	uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
	double *da = (double *)a, *db = (double *)b, *dc = (double *)c;
	double start = now_sec();
	do {
		if (!strcmp(mode, "read")) {
			/* Four accumulators so the summation dependency chain
			 * does not become the bottleneck instead of memory. */
			for (size_t i = 0; i < n64; i += 4) {
				s0 += a[i];
				s1 += a[i + 1];
				s2 += a[i + 2];
				s3 += a[i + 3];
			}
		} else if (!strcmp(mode, "write")) {
			uint64_t v = passes + 1;
			for (size_t i = 0; i < n64; i++)
				a[i] = v;
		} else if (!strcmp(mode, "copy")) {
			memcpy(b, a, bytes);
		} else {
			double scalar = 3.0;
			for (size_t i = 0; i < n64; i++)
				da[i] = db[i] + scalar * dc[i];
		}
		passes++;
		elapsed = now_sec() - start;
	} while (elapsed < target);

	if (!strcmp(mode, "read"))
		checksum = (double)(s0 + s1 + s2 + s3);
	else if (!strcmp(mode, "write") || !strcmp(mode, "copy"))
		checksum = (double)a[0] + (double)(b ? b[n64 - 1] : 0);
	else
		checksum = da[0] + da[n64 - 1];

	printf("RESULT %.6f %.0f\n",
	       ((double)passes * (double)bytes_per_pass / elapsed) / (1024.0 * 1024.0 * 1024.0),
	       checksum);
	free(a);
	free(b);
	free(c);
	return 0;

oom:
	fprintf(stderr, "allocation of %zu bytes failed\n", bytes);
	return 1;
}

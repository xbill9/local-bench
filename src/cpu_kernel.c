/*
 * cpu_kernel - single-threaded CPU microbenchmarks for local-bench.
 *
 * Self-calibrating: runs fixed-size chunks of work until the target duration
 * has elapsed, then reports completed operations per second. Fixed chunk sizes
 * mean the score is a rate, not a wall time, so it stays comparable across
 * machines of very different speeds.
 *
 * Every workload folds its work into a checksum that is printed, so the
 * optimiser cannot discard the loop body.
 *
 * usage: cpu_kernel <int|float|sieve> <seconds>
 * output: RESULT <ops_per_sec> <checksum>
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

/* Dependent integer mix: multiply/xor/rotate chain. Latency-bound, so it
 * measures ALU latency and clock rather than issue width. */
#define INT_CHUNK 20000000ULL
static uint64_t work_int(uint64_t seed)
{
	uint64_t x = seed;
	for (uint64_t i = 0; i < INT_CHUNK; i++) {
		x ^= x >> 33;
		x *= 0xff51afd7ed558ccdULL;
		x ^= x >> 29;
		x += i;
		x = (x << 7) | (x >> 57);
	}
	return x;
}

/* Four independent double-precision accumulators: enough parallelism to keep
 * the FPU pipelines busy, so this tracks throughput rather than latency. */
#define FLT_CHUNK 20000000ULL
static double work_float(double seed)
{
	double a = seed, b = seed * 1.5, c = seed * 2.5, d = seed * 3.5;
	for (uint64_t i = 0; i < FLT_CHUNK / 4; i++) {
		a = a * 1.0000001 + 0.5;
		b = b * 0.9999999 + 0.25;
		c = c * 1.0000002 - 0.125;
		d = d * 0.9999998 + 0.0625;
	}
	return a + b + c + d;
}

/* Sieve of Eratosthenes over 4M entries: branchy, and the working set is a few
 * MB, so it exercises the branch predictor and L2/L3 rather than the ALU. */
#define SIEVE_N 4000000ULL
static uint64_t work_sieve(unsigned char *flags)
{
	memset(flags, 1, SIEVE_N);
	flags[0] = flags[1] = 0;
	for (uint64_t i = 2; i * i < SIEVE_N; i++)
		if (flags[i])
			for (uint64_t j = i * i; j < SIEVE_N; j += i)
				flags[j] = 0;
	uint64_t count = 0;
	for (uint64_t i = 0; i < SIEVE_N; i++)
		count += flags[i];
	return count;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <int|float|sieve> <seconds>\n", argv[0]);
		return 2;
	}
	const char *mode = argv[1];
	double target = atof(argv[2]);
	if (target <= 0) {
		fprintf(stderr, "seconds must be > 0\n");
		return 2;
	}

	unsigned char *flags = NULL;
	uint64_t chunk_ops;
	if (!strcmp(mode, "int")) {
		chunk_ops = INT_CHUNK;
	} else if (!strcmp(mode, "float")) {
		chunk_ops = FLT_CHUNK;
	} else if (!strcmp(mode, "sieve")) {
		chunk_ops = SIEVE_N;
		flags = malloc(SIEVE_N);
		if (!flags) {
			fprintf(stderr, "allocation of %llu bytes failed\n",
				(unsigned long long)SIEVE_N);
			return 1;
		}
	} else {
		fprintf(stderr, "unknown workload: %s\n", mode);
		return 2;
	}

	uint64_t ichk = 0x12345678ULL;
	double fchk = 1.0;
	uint64_t total_ops = 0;
	double start = now_sec(), elapsed = 0.0;

	/* At least one chunk always runs, so a machine slower than the target
	 * duration still produces a valid (if long) measurement. */
	do {
		if (!strcmp(mode, "int"))
			ichk = work_int(ichk);
		else if (!strcmp(mode, "float"))
			fchk = work_float(fchk);
		else
			ichk += work_sieve(flags);
		total_ops += chunk_ops;
		elapsed = now_sec() - start;
	} while (elapsed < target);

	free(flags);
	printf("RESULT %.6f %llu\n", (double)total_ops / elapsed,
	       (unsigned long long)(ichk ^ (uint64_t)fchk));
	return 0;
}

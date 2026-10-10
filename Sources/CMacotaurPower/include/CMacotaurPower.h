#ifndef CMACOTAUR_POWER_H
#define CMACOTAUR_POWER_H

// Live power and clock telemetry without root on Apple Silicon, from the
// private IOReport library (loaded with dlopen, so a missing library or symbol
// only removes sources) and the AppleSMC user client. Every source is optional:
// mp_capabilities says which ones this Mac has.

#include <stdint.h>

typedef struct MPMeter MPMeter;

enum {
    MP_GPU_ENERGY = 1 << 0,    // Energy Model "GPU Energy" (nJ), summed over channels
    MP_GPU_PMP = 1 << 1,       // PMP "Energy" AGX power histograms
    MP_GPU_STATES = 1 << 2,    // GPU Stats "GPUPH" residency (busy share)
    MP_GPU_CLOCK = 1 << 3,     // GPUPH mapped through a validated pmgr frequency table
    MP_POWER_ZONE = 1 << 4,    // GPU power controller states (PWRCTRL)
    MP_DRAM_BW = 1 << 5,       // PMP "DCS BW" AMCC RD + WR
    MP_SYSTEM_POWER = 1 << 6,  // SMC PSTR
    MP_FANS = 1 << 7,          // SMC FNum > 0 and F<n>Ac readable
    MP_PROCESS_CPU = 1 << 8,   // proc_pid_rusage ri_energy_nj of this process
};

typedef struct {
    double seconds;            // since the previous mp_sample (or mp_open on the first call)
    double gpu_joules;         // NAN = unavailable (Energy Model "GPU Energy" summed, else PMP AGX)
    int    gpu_joules_source;  // 0 none, 1 energy model, 2 pmp
    double gpu_busy;           // 0...1; NAN = unavailable
    double gpu_mhz;            // active-residency weighted; NAN = unavailable
    double gpu_max_mhz;        // NAN = unavailable
    double power_zone_share;   // share of GPU on-time in a limiting controller state; NAN = unavailable
    double dram_gb;            // read + write over the interval; NAN = unavailable
    double system_watts;       // SMC PSTR now; NAN = unavailable
    double process_cpu_joules; // this process; NAN = unavailable
    int    fan_count;          // -1 unknown, 0 none
    double fan_rpm[4];         // NAN where unreadable
} MPSample;

MPMeter *mp_open(void);                    // never NULL; every source optional
uint32_t mp_capabilities(const MPMeter *); // sources found at open, minus any found dead since
void mp_sample(MPMeter *, MPSample *out);  // call from one queue only
void mp_close(MPMeter *);
int mp_fan_count(void);                    // quick SMC read, -1 unknown

/// Writes a short human-readable description of the sources found (for
/// `--power-debug`). Returns the number of bytes written, excluding the NUL.
int mp_describe(const MPMeter *, char *buffer, int size);

#endif

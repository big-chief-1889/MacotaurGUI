// Live power, clock and fan readings, sampled for as long as the app runs:
//   - IOReport (private, /usr/lib/libIOReport.dylib) is loaded with dlopen and
//     every function with dlsym, so a Mac or macOS without it only loses those
//     sources. Never use the PMGR mJ channels ("GPU", "CPU Energy", "DRAM"):
//     they are frozen on M5 / macOS 27.
//   - GPU energy: Energy Model "GPU Energy" (nJ), summed over every channel of
//     that name (multi-die chips have one per die). If it stays at 0 for 5
//     samples while the GPU is busy, it is marked dead and PMP AGX power
//     histograms are used instead.
//   - GPU clock: GPU Stats "GPUPH" residency mapped through the pmgr
//     "voltage-states9" frequency table, trusted only when the table looks sane
//     and covers every P-state that had residency.
//   - DRAM traffic: PMP "DCS BW" AMCC RD + WR histograms.
//   - SMC: PSTR (whole-Mac watts), FNum and F<n>Ac (fans).
//   - proc_pid_rusage of this process: its own CPU energy.

#include "CMacotaurPower.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

// MARK: - IOReport function table

typedef struct IOReportSubscription *IOReportSubscriptionRef;
typedef CFMutableDictionaryRef (*FnCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*FnMergeChannels)(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
typedef IOReportSubscriptionRef (*FnCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*FnCreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*FnCreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int64_t (*FnSimpleGetIntegerValue)(CFDictionaryRef, int32_t *);
typedef CFStringRef (*FnChannelGetString)(CFDictionaryRef);
typedef int32_t (*FnChannelGetFormat)(CFDictionaryRef);
typedef int32_t (*FnStateGetCount)(CFDictionaryRef);
typedef CFStringRef (*FnStateGetNameForIndex)(CFDictionaryRef, int32_t);
typedef int64_t (*FnStateGetResidency)(CFDictionaryRef, int32_t);
typedef int (*FnIterate)(CFDictionaryRef, int (^)(CFDictionaryRef));

typedef struct {
    FnCopyChannelsInGroup copyChannelsInGroup;
    FnMergeChannels mergeChannels;
    FnCreateSubscription createSubscription;
    FnCreateSamples createSamples;
    FnCreateSamplesDelta createSamplesDelta;
    FnSimpleGetIntegerValue simpleGetIntegerValue;
    FnChannelGetString getGroup, getSubGroup, getChannelName, getUnitLabel;
    FnChannelGetFormat getFormat;
    FnStateGetCount stateGetCount;
    FnStateGetNameForIndex stateGetNameForIndex;
    FnStateGetResidency stateGetResidency;
    FnIterate iterate;
} IOReportAPI;

enum { kFormatSimple = 1, kFormatState = 2 };

// MARK: - SMC

#define FOURCC(s) ((uint32_t)(s)[0] << 24 | (uint32_t)(s)[1] << 16 | (uint32_t)(s)[2] << 8 | (uint32_t)(s)[3])

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVersion vers; SMCPLimit pLimit; SMCKeyInfo info;
    char result, status, cmd; uint32_t data32; char bytes[32];
} SMCParam;

static int smcCall(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t size = sizeof(SMCParam);
    return IOConnectCallStructMethod(c, 2, in, sizeof(SMCParam), out, &size) != KERN_SUCCESS || out->result;
}

static int smcKeyInfo(io_connect_t c, const char *key, SMCKeyInfo *info) {
    SMCParam in = {0}, out = {0};
    in.key = FOURCC(key);
    in.cmd = 9;  // key info
    if (smcCall(c, &in, &out)) return -1;
    *info = out.info;
    return 0;
}

static int smcRead(io_connect_t c, const char *key, SMCKeyInfo info, char bytes[32]) {
    SMCParam in = {0}, out = {0};
    in.key = FOURCC(key);
    in.info.dataSize = info.dataSize;
    in.cmd = 5;  // read bytes
    if (smcCall(c, &in, &out)) return -1;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

static double smcFloat(io_connect_t c, const char *key, SMCKeyInfo info) {
    char b[32];
    if (info.dataType != FOURCC("flt ") || info.dataSize != 4 || smcRead(c, key, info, b)) return NAN;
    float f;
    memcpy(&f, b, 4);
    return isfinite(f) ? f : NAN;
}

static io_connect_t smcOpen(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t c = 0;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &c);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? c : 0;
}

/// FNum: -1 when unreadable (never inferred as "no fans"), else the count.
static int smcFanCount(io_connect_t c) {
    SMCKeyInfo info;
    char b[32];
    if (!c || smcKeyInfo(c, "FNum", &info) || info.dataSize < 1 || smcRead(c, "FNum", info, b)) return -1;
    return (unsigned char)b[0];
}

// MARK: - Meter

#define MAX_STATES 64

struct MPMeter {
    void *lib;
    IOReportAPI api;
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
    double prevT;
    uint32_t caps;

    double mhzTable[MAX_STATES];
    int mhzCount;
    double mhzMax;

    io_connect_t smc;
    SMCKeyInfo pstrInfo;
    int fanCount;
    SMCKeyInfo fanInfo[4];

    uint64_t prevEnergyNJ;
    int energyZeroRun;
};

static mach_timebase_info_data_t timebase;

static double nowSeconds(void) {
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

static const char *cstr(CFStringRef s, char buf[256]) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, 256, kCFStringEncodingUTF8);
    return buf;
}

static double joulesPerUnit(const IOReportAPI *api, CFDictionaryRef ch) {
    char u[256];
    cstr(api->getUnitLabel(ch), u);
    if (!strcmp(u, "mJ")) return 1e-3;
    if (!strcmp(u, "uJ")) return 1e-6;
    if (!strcmp(u, "nJ")) return 1e-9;
    if (!strcmp(u, "J")) return 1;
    return 0;
}

static int loadIOReport(MPMeter *m) {
    m->lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!m->lib) return -1;
    IOReportAPI *a = &m->api;
#define SYM(field, name) if (!(a->field = (__typeof__(a->field))dlsym(m->lib, name))) return -1
    SYM(copyChannelsInGroup, "IOReportCopyChannelsInGroup");
    SYM(mergeChannels, "IOReportMergeChannels");
    SYM(createSubscription, "IOReportCreateSubscription");
    SYM(createSamples, "IOReportCreateSamples");
    SYM(createSamplesDelta, "IOReportCreateSamplesDelta");
    SYM(simpleGetIntegerValue, "IOReportSimpleGetIntegerValue");
    SYM(getGroup, "IOReportChannelGetGroup");
    SYM(getSubGroup, "IOReportChannelGetSubGroup");
    SYM(getChannelName, "IOReportChannelGetChannelName");
    SYM(getUnitLabel, "IOReportChannelGetUnitLabel");
    SYM(getFormat, "IOReportChannelGetFormat");
    SYM(stateGetCount, "IOReportStateGetCount");
    SYM(stateGetNameForIndex, "IOReportStateGetNameForIndex");
    SYM(stateGetResidency, "IOReportStateGetResidency");
    SYM(iterate, "IOReportIterate");
#undef SYM
    return 0;
}

static CFMutableDictionaryRef copyChannels(MPMeter *m, const char *group, const char *subgroup) {
    CFStringRef g = CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8);
    CFStringRef s = subgroup ? CFStringCreateWithCString(NULL, subgroup, kCFStringEncodingUTF8) : NULL;
    CFMutableDictionaryRef c = m->api.copyChannelsInGroup(g, s, 0, 0, 0);
    CFRelease(g);
    if (s) CFRelease(s);
    return c;
}

/// pmgr "voltage-states9": (frequency, voltage) pairs, OFF first. Older SoCs
/// list Hz, newer ones kHz (or MHz). Trusted only if the frequencies never
/// decrease and the top one is a plausible GPU clock.
static void loadFrequencyTable(MPMeter *m) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it)) return;
    io_object_t dev;
    while ((dev = IOIteratorNext(it))) {
        io_name_t name;
        if (!IORegistryEntryGetName(dev, name) && !strcmp(name, "pmgr") && m->mhzCount == 0) {
            CFTypeRef data = IORegistryEntryCreateCFProperty(dev, CFSTR("voltage-states9"), NULL, 0);
            if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
                const uint32_t *v = (const uint32_t *)CFDataGetBytePtr(data);
                int n = (int)(CFDataGetLength(data) / 8);
                n = n < MAX_STATES ? n : MAX_STATES;
                uint32_t top = 0;
                for (int i = 0; i < n; i++) top = v[2 * i] > top ? v[2 * i] : top;
                double scale = top > 10000000 ? 1e-6 : top > 10000 ? 1e-3 : 1;
                int ok = n >= 2;
                for (int i = 0; i < n; i++) {
                    m->mhzTable[i] = v[2 * i] * scale;
                    if (i > 0 && m->mhzTable[i] < m->mhzTable[i - 1]) ok = 0;
                }
                double max = n > 0 ? m->mhzTable[n - 1] : 0;
                if (ok && max >= 300 && max <= 3000) {
                    m->mhzCount = n;
                    m->mhzMax = max;
                }
            }
            if (data) CFRelease(data);
        }
        IOObjectRelease(dev);
    }
    IOObjectRelease(it);
}

static int isOffState(const char *s) { return !strcmp(s, "OFF") || !strcmp(s, "IDLE") || !strcmp(s, "DOWN"); }

/// A histogram channel whose state names are bin upper edges ("4GB/s",
/// "0.250W"): sum(count * bin centre), plus the sample count.
static double histogramSum(const IOReportAPI *a, CFDictionaryRef ch, double *count) {
    int k = a->stateGetCount(ch);
    double sum = 0, n = 0, lo = 0;
    for (int i = 0; i < k; i++) {
        char name[256];
        double hi = atof(cstr(a->stateGetNameForIndex(ch, i), name));
        double c = (double)a->stateGetResidency(ch, i);
        sum += c * 0.5 * (lo + hi);
        n += c;
        lo = hi;
    }
    *count = n;
    return sum;
}

typedef struct {
    double gpuNJ;
    int energyChannels;
    double pmpGPUW, maxN, rd, wr;
    int pmpGPU, dram;
    double stateTicks[MAX_STATES];
    int stateOff[MAX_STATES];
    int nStates;
    double ctrlOn, ctrlPerf;
    int ctrl;
} Delta;

static void readDelta(MPMeter *m, CFDictionaryRef d, Delta *out) {
    memset(out, 0, sizeof *out);
    const IOReportAPI *a = &m->api;
    __block Delta acc;
    memset(&acc, 0, sizeof acc);
    a->iterate(d, ^int(CFDictionaryRef ch) {
        char g[256], sg[256], n[256];
        cstr(a->getGroup(ch), g);
        cstr(a->getSubGroup(ch), sg);
        cstr(a->getChannelName(ch), n);
        int format = a->getFormat(ch);
        if (!strcmp(g, "Energy Model") && format == kFormatSimple) {
            if (!strcmp(n, "GPU Energy")) {
                acc.gpuNJ += (double)a->simpleGetIntegerValue(ch, NULL) * joulesPerUnit(a, ch) * 1e9;
                acc.energyChannels++;
            }
        } else if (!strcmp(g, "PMP") && format == kFormatState) {
            double c = 0;
            if (!strcmp(sg, "Energy") && !strncmp(n, "AGX", 3)) {
                acc.pmpGPUW += histogramSum(a, ch, &c);
                acc.pmpGPU = 1;
            } else if (!strcmp(sg, "DCS BW") && (!strcmp(n, "AMCC RD") || !strcmp(n, "AMCC WR"))) {
                double s = histogramSum(a, ch, &c);
                if (!strcmp(n, "AMCC RD")) acc.rd += s; else acc.wr += s;
                acc.dram = 1;
            } else if (!strcmp(sg, "Energy")) {
                histogramSum(a, ch, &c);
            } else {
                return 0;
            }
            if (c > acc.maxN) acc.maxN = c;
        } else if (!strcmp(g, "GPU Stats") && format == kFormatState && !strcmp(n, "GPUPH")) {
            int k = a->stateGetCount(ch);
            k = k < MAX_STATES ? k : MAX_STATES;
            for (int i = 0; i < k; i++) {
                char s[256];
                acc.stateTicks[i] += (double)a->stateGetResidency(ch, i);
                acc.stateOff[i] = isOffState(cstr(a->stateGetNameForIndex(ch, i), s));
            }
            if (k > acc.nStates) acc.nStates = k;
        } else if (!strcmp(g, "GPU Stats") && format == kFormatState && !strcmp(n, "PWRCTRL")) {
            int k = a->stateGetCount(ch);
            for (int i = 0; i < k; i++) {
                char s[256];
                cstr(a->stateGetNameForIndex(ch, i), s);
                double t = (double)a->stateGetResidency(ch, i);
                if (!strcmp(s, "IDLE_OFF")) continue;
                acc.ctrlOn += t;
                if (!strcmp(s, "PERF")) acc.ctrlPerf += t;
            }
            acc.ctrl = 1;
        }
        return 0;
    });
    *out = acc;
}

static const double kPMPNominalHz = 4395;

MPMeter *mp_open(void) {
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    MPMeter *m = calloc(1, sizeof(MPMeter));
    if (!m) return NULL;
    m->fanCount = -1;

    if (loadIOReport(m) == 0) {
        CFMutableDictionaryRef chans = copyChannels(m, "Energy Model", NULL);
        const char *extra[][2] = {{"GPU Stats", "GPU Performance States"}, {"GPU Stats", "GPU Power Controller States"},
                                  {"PMP", "Energy"}, {"PMP", "DCS BW"}};
        for (size_t i = 0; i < sizeof extra / sizeof extra[0]; i++) {
            CFMutableDictionaryRef c = copyChannels(m, extra[i][0], extra[i][1]);
            if (!c) continue;
            if (chans) {
                m->api.mergeChannels(chans, c, NULL);
                CFRelease(c);
            } else {
                chans = c;
            }
        }
        if (chans) {
            m->sub = m->api.createSubscription(NULL, chans, &m->subbed, 0, NULL);
            CFRelease(chans);
        }
        if (m->sub) {
            m->prev = m->api.createSamples(m->sub, m->subbed, NULL);
            m->prevT = nowSeconds();
        }
        if (m->prev) {
            // Discover the sources from what one sample holds.
            Delta d;
            readDelta(m, m->prev, &d);
            if (d.energyChannels > 0) m->caps |= MP_GPU_ENERGY;
            if (d.pmpGPU) m->caps |= MP_GPU_PMP;
            if (d.nStates > 0) m->caps |= MP_GPU_STATES;
            if (d.ctrl) m->caps |= MP_POWER_ZONE;
            if (d.dram) m->caps |= MP_DRAM_BW;
            if (d.nStates > 0) {
                loadFrequencyTable(m);
                if (m->mhzCount > 0) m->caps |= MP_GPU_CLOCK;
            }
        }
    }

    m->smc = smcOpen();
    if (m->smc) {
        if (!smcKeyInfo(m->smc, "PSTR", &m->pstrInfo) && m->pstrInfo.dataType == FOURCC("flt ")
            && !isnan(smcFloat(m->smc, "PSTR", m->pstrInfo)))
            m->caps |= MP_SYSTEM_POWER;
        m->fanCount = smcFanCount(m->smc);
        if (m->fanCount > 0) {
            int readable = 0;
            for (int i = 0; i < m->fanCount && i < 4; i++) {
                char key[5];
                snprintf(key, sizeof key, "F%dAc", i);
                if (!smcKeyInfo(m->smc, key, &m->fanInfo[i]) && !isnan(smcFloat(m->smc, key, m->fanInfo[i]))) readable++;
            }
            if (readable > 0) m->caps |= MP_FANS;
        }
    }

    struct rusage_info_v6 ru;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ru) == 0) {
        m->prevEnergyNJ = ru.ri_energy_nj;
        m->caps |= MP_PROCESS_CPU;
    }
    return m;
}

uint32_t mp_capabilities(const MPMeter *m) { return m ? m->caps : 0; }

void mp_sample(MPMeter *m, MPSample *out) {
    memset(out, 0, sizeof *out);
    out->gpu_joules = out->gpu_busy = out->gpu_mhz = out->gpu_max_mhz = NAN;
    out->power_zone_share = out->dram_gb = out->system_watts = out->process_cpu_joules = NAN;
    out->fan_count = -1;
    for (int i = 0; i < 4; i++) out->fan_rpm[i] = NAN;
    if (!m) return;

    double t = nowSeconds();
    double seconds = m->prevT > 0 ? t - m->prevT : 0;
    out->seconds = seconds;

    if (m->sub && m->prev) {
        CFDictionaryRef cur = m->api.createSamples(m->sub, m->subbed, NULL);
        if (cur) {
            CFDictionaryRef delta = m->api.createSamplesDelta(m->prev, cur, NULL);
            if (delta) {
                Delta d;
                readDelta(m, delta, &d);
                CFRelease(delta);

                double total = 0, active = 0, weighted = 0;
                int beyondTable = 0;
                for (int i = 0; i < d.nStates; i++) {
                    total += d.stateTicks[i];
                    if (d.stateOff[i]) continue;
                    active += d.stateTicks[i];
                    if (i < m->mhzCount) weighted += d.stateTicks[i] * m->mhzTable[i];
                    else if (d.stateTicks[i] > 0) beyondTable = 1;
                }
                if ((m->caps & MP_GPU_STATES) && total > 0) out->gpu_busy = active / total;
                if ((m->caps & MP_GPU_CLOCK) && !beyondTable) {
                    out->gpu_max_mhz = m->mhzMax;
                    if (active > 0) out->gpu_mhz = weighted / active;
                }
                if ((m->caps & MP_POWER_ZONE) && d.ctrlOn > 0) out->power_zone_share = 1 - d.ctrlPerf / d.ctrlOn;

                double rate = seconds > 0 && d.maxN / seconds > kPMPNominalHz ? d.maxN / seconds : kPMPNominalHz;
                double dt = 1 / rate;
                if ((m->caps & MP_DRAM_BW) && seconds > 0) out->dram_gb = (d.rd + d.wr) * dt;

                if (m->caps & MP_GPU_ENERGY) {
                    // Liveness: a counter that stays at 0 while the GPU works is dead.
                    double busy = isnan(out->gpu_busy) ? 1 : out->gpu_busy;
                    if (d.gpuNJ <= 0 && busy > 0.2) m->energyZeroRun++;
                    else if (d.gpuNJ > 0) m->energyZeroRun = 0;
                    if (m->energyZeroRun >= 5) m->caps &= ~(uint32_t)MP_GPU_ENERGY;
                }
                if (m->caps & MP_GPU_ENERGY) {
                    out->gpu_joules = d.gpuNJ / 1e9;
                    out->gpu_joules_source = 1;
                } else if ((m->caps & MP_GPU_PMP) && seconds > 0) {
                    out->gpu_joules = d.pmpGPUW * dt;
                    out->gpu_joules_source = 2;
                }
            }
            CFRelease(m->prev);
            m->prev = cur;
        }
    }
    m->prevT = t;

    if (m->smc) {
        if (m->caps & MP_SYSTEM_POWER) out->system_watts = smcFloat(m->smc, "PSTR", m->pstrInfo);
        out->fan_count = m->fanCount;
        if (m->caps & MP_FANS) {
            for (int i = 0; i < m->fanCount && i < 4; i++) {
                char key[5];
                snprintf(key, sizeof key, "F%dAc", i);
                out->fan_rpm[i] = smcFloat(m->smc, key, m->fanInfo[i]);
            }
        }
    }

    if (m->caps & MP_PROCESS_CPU) {
        struct rusage_info_v6 ru;
        if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ru) == 0) {
            out->process_cpu_joules = (double)(ru.ri_energy_nj - m->prevEnergyNJ) / 1e9;
            m->prevEnergyNJ = ru.ri_energy_nj;
        }
    }
}

void mp_close(MPMeter *m) {
    if (!m) return;
    if (m->prev) CFRelease(m->prev);
    if (m->subbed) CFRelease(m->subbed);
    // The subscription itself is not released: IOReport documents no way to.
    if (m->smc) IOServiceClose(m->smc);
    // The library stays loaded: dyld keeps shared-cache images anyway.
    free(m);
}

int mp_fan_count(void) {
    io_connect_t c = smcOpen();
    if (!c) return -1;
    int n = smcFanCount(c);
    IOServiceClose(c);
    return n;
}

int mp_describe(const MPMeter *m, char *buffer, int size) {
    if (!buffer || size <= 0) return 0;
    if (!m) return snprintf(buffer, (size_t)size, "no meter");
    int n = snprintf(buffer, (size_t)size,
                     "IOReport %s; GPU energy %s; PMP GPU %s; GPUPH %s; clock table %d entries, max %.0f MHz%s; "
                     "power controller %s; DRAM %s; SMC %s; PSTR %s; fans %d%s; process energy %s",
                     m->lib ? "loaded" : "missing", m->caps & MP_GPU_ENERGY ? "yes" : "no", m->caps & MP_GPU_PMP ? "yes" : "no",
                     m->caps & MP_GPU_STATES ? "yes" : "no", m->mhzCount, m->mhzMax, m->caps & MP_GPU_CLOCK ? "" : " (unused)",
                     m->caps & MP_POWER_ZONE ? "yes" : "no", m->caps & MP_DRAM_BW ? "yes" : "no", m->smc ? "open" : "closed",
                     m->caps & MP_SYSTEM_POWER ? "yes" : "no", m->fanCount, m->caps & MP_FANS ? " (readable)" : "",
                     m->caps & MP_PROCESS_CPU ? "yes" : "no");
    return n < size ? n : size - 1;
}

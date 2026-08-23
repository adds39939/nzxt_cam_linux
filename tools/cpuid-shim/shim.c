/* cpuidsdk64.dll shim for Wine.
 *
 * The CPUID SDK needs its ring-0 driver (cpuz162) to read hardware, which cannot
 * work under Wine: initialisation fails with 0x45A and CAM reports no CPU at all.
 * This shim loads the genuine SDK, lets it do everything it can from userspace
 * (topology, model, codename, socket), reports initialisation as successful, and
 * substitutes the readings that need the driver with values taken from Linux.
 *
 * Calls reach the SDK through thunks.S: some readings are returned in XMM0 and
 * several entry points take arguments on the stack, neither of which a plain C
 * thunk can forward.
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

struct ctx { ULONG_PTR slot, a, b, c, d, s5, s6, s7, s8, s9, s10, rax, xmm; };

typedef ULONG_PTR (*fnx_t)(ULONG_PTR, ULONG_PTR, ULONG_PTR, ULONG_PTR);
fnx_t   slot_fn[64];
extern void *thunk_table[64];

static unsigned slot_hash[64];
static int      nslots;
static HMODULE  realmod;
static ULONG_PTR base;
static FILE *lg;
static CRITICAL_SECTION cs;

static void L(const char *fmt, ...)
{
    va_list ap;
    if (!lg) return;
    EnterCriticalSection(&cs);
    va_start(ap, fmt); vfprintf(lg, fmt, ap); va_end(ap);
    fputc('\n', lg); fflush(lg);
    LeaveCriticalSection(&cs);
}

/* ---- Linux sensor sources, read through Wine's Z: mapping of / ------------ */

static int read_long( const char *path, long *out )
{
    FILE *f = fopen( path, "r" );
    long v;

    if (!f) return 0;
    if (fscanf( f, "%ld", &v ) != 1) { fclose( f ); return 0; }
    fclose( f );
    *out = v;
    return 1;
}

static int hwmon_dir( const char *want, char *dir, size_t len )
{
    int i;

    for (i = 0; i < 32; i++)
    {
        char path[256], name[64];
        FILE *f;

        snprintf( path, sizeof(path), "Z:\\sys\\class\\hwmon\\hwmon%d\\name", i );
        if (!(f = fopen( path, "r" ))) continue;
        if (!fgets( name, sizeof(name), f )) { fclose( f ); continue; }
        fclose( f );
        name[strcspn( name, "\r\n" )] = 0;
        if (!strcmp( name, want ))
        {
            snprintf( dir, len, "Z:\\sys\\class\\hwmon\\hwmon%d", i );
            return 1;
        }
    }
    return 0;
}

/* CPU package temperature: k10temp on AMD, coretemp on Intel. */
static float cpu_package_temp(void)
{
    static char dir[256];
    static int resolved;
    char path[320];
    long value;

    if (!resolved)
    {
        if (!hwmon_dir( "k10temp", dir, sizeof(dir) ) &&
            !hwmon_dir( "coretemp", dir, sizeof(dir) )) return -1.0f;
        resolved = 1;
    }
    snprintf( path, sizeof(path), "%s\\temp1_input", dir );
    if (!read_long( path, &value )) return -1.0f;
    return (float)value / 1000.0f;
}

/* Per-core clock. CAM multiplies this by the 100 MHz bus clock, so return the
 * multiplier. SMT means SDK core i is Linux cpu 2*i. */
static float core_multiplier( unsigned core )
{
    char path[160];
    long khz;

    snprintf( path, sizeof(path),
              "Z:\\sys\\devices\\system\\cpu\\cpu%u\\cpufreq\\scaling_cur_freq", core * 2 );
    if (!read_long( path, &khz )) return -1.0f;
    return (float)khz / 100000.0f;
}

/* ---- interception --------------------------------------------------------- */

void on_call(struct ctx *x) { (void)x; }

void on_ret(struct ctx *x)
{
    unsigned bits;
    float value;

    switch (slot_hash[x->slot])
    {
    case 0xa3fd47fa:            /* Init: fails with 0x45A without the driver */
        if (x->c) *(unsigned *)x->c = 0;
        if (x->d) *(unsigned *)x->d = 0;
        x->rax = 1;
        break;

    case 0x602cc059:            /* CPU package temperature, in XMM0 (-1 = n/a) */
        value = cpu_package_temp();
        memcpy( &bits, &value, sizeof(bits) );
        x->xmm = bits;
        break;

    case 0x039a0734:            /* per-core clock multiplier, in XMM0 */
        value = core_multiplier( (unsigned)x->c );
        if (value > 0.0f)
        {
            memcpy( &bits, &value, sizeof(bits) );
            x->xmm = bits;
        }
        break;
    }
}

typedef void *(*qi_t)(unsigned);
static qi_t real_qi;

__declspec(dllexport) void * QueryInterface(unsigned hash)
{
    void *fn;
    int i;

    if (!real_qi) return NULL;
    if (!(fn = real_qi(hash))) return NULL;

    for (i = 0; i < nslots; i++) if (slot_hash[i] == hash) return thunk_table[i];
    if (nslots >= 64) return fn;
    slot_hash[nslots] = hash;
    slot_fn[nslots] = (fnx_t)fn;
    return thunk_table[nslots++];
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *rsv)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        char path[MAX_PATH], *p;

        InitializeCriticalSection(&cs);
        if (getenv("NZXT_CAM_SDK_LOG")) lg = fopen("C:\\sdkproxy.log", "w");
        GetModuleFileNameA(h, path, MAX_PATH);
        if ((p = strrchr(path, '\\'))) p[1] = 0;
        strcat(path, "cpuidsdk64_real.dll");
        realmod = LoadLibraryA(path);
        base = (ULONG_PTR)realmod;
        if (realmod) real_qi = (qi_t)GetProcAddress(realmod, "QueryInterface");
        L("shim up: real=%p qi=%p", (void *)realmod, (void *)real_qi);
    }
    return TRUE;
}

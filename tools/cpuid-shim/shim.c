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

/* GPU readings, refreshed into a file by the launcher. The kernel's hwmon and DRM
 * interfaces cover AMD, Intel and nouveau with no dependency at all; only NVIDIA's
 * proprietary driver registers no hwmon node, and there the launcher falls back to
 * nvidia-smi. Either way this side just reads six fields:
 *
 *   temperature C, load %, clock MHz, fan, power W, fan unit
 *
 * A field is "-" when the driver does not expose it, which becomes -1 here: that is
 * the SDK's own "no reading" value, so CAM shows n/a for it and nothing else changes.
 */
struct gpu_readings
{
    float temperature, load, clock, fan, power;
    int fan_is_rpm;
    int valid;
};

/* "-" (or anything unparseable) means the driver does not expose this one. */
static float gpu_field( const char *token )
{
    char *end;
    float value;

    while (*token == ' ') token++;
    if (*token == '-' && (token[1] == '\0' || token[1] == ' ' || token[1] == '\n'))
        return -1.0f;
    value = (float)strtod( token, &end );
    return (end == token) ? -1.0f : value;
}

static void read_gpu( struct gpu_readings *out )
{
    static struct gpu_readings cached;
    static DWORD last;
    DWORD now = GetTickCount();
    char line[256], *field[6] = { 0 };
    unsigned n = 0;
    char *p;
    FILE *f;

    if (cached.valid && now - last < 1000) { *out = cached; return; }
    last = now;
    memset( &cached, 0, sizeof(cached) );

    if ((f = fopen( "C:\\windows\\temp\\nzxt-cam-gpu", "r" )))
    {
        if (fgets( line, sizeof(line), f ))
        {
            for (p = line; *p && n < 6; )
            {
                field[n++] = p;
                if (!(p = strchr( p, ',' ))) break;
                *p++ = '\0';
            }
            if (n >= 5)
            {
                cached.temperature = gpu_field( field[0] );
                cached.load        = gpu_field( field[1] );
                cached.clock       = gpu_field( field[2] );
                cached.fan         = gpu_field( field[3] );
                cached.power       = gpu_field( field[4] );
                /* CAM's fan field is RPM. A percentage is not that, so unless the
                 * driver really reports RPM the fan stays unreported rather than
                 * showing a number in the wrong unit. */
                cached.fan_is_rpm  = (n >= 6 && field[5] && strstr( field[5], "rpm" ) != NULL);
                if (!cached.fan_is_rpm) cached.fan = -1.0f;
                cached.valid = 1;
            }
        }
        fclose( f );
    }
    *out = cached;
}

/* ---- CAM's GPU record match ------------------------------------------------
 *
 * Each GPU entry cam_helper builds has an SDK-linkage pair: a flag at +0x38 that
 * is 1 once the entry has been paired with a CPUID SDK GPU device, and that
 * device's ordinal at +0x3c. Before attaching sensor readings it looks for the
 * entry whose flag is 1 and whose ordinal matches the class-0x20 device it is
 * currently on.
 *
 * Under Wine the flag is never set -- a hardware watchpoint on the field shows
 * nothing writes it, and the whole SDK-derived half of the entry stays zero --
 * because the linkage comes from the SDK's own GPU enumeration, which cannot
 * exist without the driver. There is nothing to fix at the Wine level: the
 * pairing has to come from us.
 *
 * So relax the flag test to accept the value the field actually has, rather than
 * removing the test. The ordinal comparison at +0x3c still runs, so entries are
 * still paired one-to-one and a second GPU cannot be given the first one's
 * readings -- which is what deleting the branch would have risked.
 *
 *   42 83 7c 38 38 01   cmpl $0x1,0x38(%rax,%r15,1)     <- the 01 becomes 00
 *   75 xx               jne  <next entry>
 *
 * Found by signature, and applied only on a single unambiguous match, so a CAM
 * update that moves this code disables the change instead of corrupting something.
 */
static void accept_unlinked_gpu_entries(void)
{
    static const unsigned char sig[] = { 0x42, 0x83, 0x7c, 0x38, 0x38, 0x01, 0x75 };
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)GetModuleHandleA( NULL );
    IMAGE_NT_HEADERS *nt;
    IMAGE_SECTION_HEADER *sec;
    ULONG_PTR mod = (ULONG_PTR)dos;
    unsigned char *found = NULL;
    unsigned i, matches = 0;

    if (!dos || dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS *)(mod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    sec = IMAGE_FIRST_SECTION( nt );

    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, sec++)
    {
        unsigned char *base;
        SIZE_T off;

        if (memcmp( sec->Name, ".text", 5 )) continue;
        base = (unsigned char *)(mod + sec->VirtualAddress);
        for (off = 0; off + sizeof(sig) < sec->Misc.VirtualSize; off++)
        {
            if (memcmp( base + off, sig, sizeof(sig) )) continue;
            found = base + off + 5;        /* the immediate */
            matches++;
        }
    }

    if (matches != 1)
    {
        L("GPU entry match: %u signature matches, leaving alone", matches);
        return;
    }
    {
        DWORD old;

        if (!VirtualProtect( found, 1, PAGE_EXECUTE_READWRITE, &old )) return;
        *found = 0x00;
        VirtualProtect( found, 1, old, &old );
        L("GPU entry match relaxed at %p", found);
    }
}

/* ---- D3DKMT ---------------------------------------------------------------
 *
 * cam_helper resolves these by name, so replacing what GetProcAddress hands back
 * is enough. Wine implements only two KMTQAITYPE_* queries; CAM wants
 * KMTQAITYPE_ADAPTERADDRESS (6), the adapter's PCI bus/device/function. */
struct query_adapter_info { unsigned adapter, type; void *data; unsigned size; };
struct adapter_address { unsigned bus, device, function; };

static long (WINAPI *real_query_adapter_info)( struct query_adapter_info * );
static FARPROC (WINAPI *real_get_proc_address)( HMODULE, const char * );

static long WINAPI query_adapter_info_hook( struct query_adapter_info *desc )
{
    long status = real_query_adapter_info( desc );

    if (status && desc && desc->type == 6 && desc->data &&
        desc->size >= sizeof(struct adapter_address))
    {
        struct adapter_address *addr = desc->data;
        DWORD bus = 0, device = 0, function = 0;
        HKEY key = 0;
        DWORD size = sizeof(DWORD);

        /* gpu-pci-fixup has already put the host's PCI address on the device node. */
        if (!RegOpenKeyExA( HKEY_LOCAL_MACHINE,
                            "System\\CurrentControlSet\\Enum\\PCI", 0,
                            KEY_ENUMERATE_SUB_KEYS, &key ))
        {
            char id[256];
            DWORD len = sizeof(id);

            if (!RegEnumKeyExA( key, 0, id, &len, NULL, NULL, NULL, NULL ))
            {
                char path[512];
                HKEY dev;

                snprintf( path, sizeof(path), "System\\CurrentControlSet\\Enum\\PCI\\%s\\00000000", id );
                if (!RegOpenKeyExA( HKEY_LOCAL_MACHINE, path, 0, KEY_QUERY_VALUE, &dev ))
                {
                    DWORD value = 0;
                    size = sizeof(value);
                    if (!RegQueryValueExA( dev, "BusNumber", NULL, NULL, (BYTE *)&value, &size ))
                        bus = value;
                    size = sizeof(value);
                    if (!RegQueryValueExA( dev, "Address", NULL, NULL, (BYTE *)&value, &size ))
                    {
                        device = value >> 16;
                        function = value & 0xffff;
                    }
                    RegCloseKey( dev );
                }
            }
            RegCloseKey( key );
        }
        addr->bus = bus;
        addr->device = device;
        addr->function = function;
        status = 0;
    }
    return status;
}

static FARPROC WINAPI get_proc_address_hook( HMODULE module, const char *name )
{
    FARPROC ret = real_get_proc_address( module, name );

    if (ret && (ULONG_PTR)name > 0xffff && !strcmp( name, "D3DKMTQueryAdapterInfo" ))
    {
        real_query_adapter_info = (void *)ret;
        ret = (FARPROC)query_adapter_info_hook;
    }
    return ret;
}

static void patch_import( const char *dll_name, const char *func_name, void *replacement,
                          void **original )
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)GetModuleHandleA( NULL );
    IMAGE_NT_HEADERS *nt;
    IMAGE_IMPORT_DESCRIPTOR *desc;
    ULONG_PTR mod = (ULONG_PTR)dos;
    DWORD rva;

    if (!dos || dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS *)(mod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return;

    for (desc = (IMAGE_IMPORT_DESCRIPTOR *)(mod + rva); desc->Name; desc++)
    {
        IMAGE_THUNK_DATA *names, *addrs;

        if (_stricmp( (const char *)(mod + desc->Name), dll_name )) continue;
        names = (IMAGE_THUNK_DATA *)(mod + desc->OriginalFirstThunk);
        addrs = (IMAGE_THUNK_DATA *)(mod + desc->FirstThunk);
        for (; names->u1.AddressOfData; names++, addrs++)
        {
            IMAGE_IMPORT_BY_NAME *by_name;
            DWORD old;

            if (IMAGE_SNAP_BY_ORDINAL( names->u1.Ordinal )) continue;
            by_name = (IMAGE_IMPORT_BY_NAME *)(mod + names->u1.AddressOfData);
            if (strcmp( (const char *)by_name->Name, func_name )) continue;
            if (!VirtualProtect( addrs, sizeof(*addrs), PAGE_READWRITE, &old )) return;
            *original = (void *)addrs->u1.Function;
            addrs->u1.Function = (ULONG_PTR)replacement;
            VirtualProtect( addrs, sizeof(*addrs), old, &old );
            return;
        }
    }
}

static int readable( const void *p, SIZE_T n )
{
    MEMORY_BASIC_INFORMATION mbi;

    if (!p || (ULONG_PTR)p < 0x10000) return 0;
    if (!VirtualQuery( p, &mbi, sizeof(mbi) )) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    return (ULONG_PTR)p + n <= (ULONG_PTR)mbi.BaseAddress + mbi.RegionSize;
}

/* ---- interception --------------------------------------------------------- */

static unsigned real_device_count;      /* the SDK's own devices; ours is appended */

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

    /* The SDK enumerates no GPU without its driver, so append one device of the
     * class cam_helper treats as a GPU and answer its sensor queries from Linux.
     * Sensor classes: 0x2000 temperature, 0x3000 fan, 0x5000 power,
     * 0xe000 load, 0xf000 clock. */
    case 0xaec15d82:            /* device count */
        real_device_count = (unsigned)x->rax;
        x->rax = real_device_count + 1;
        break;

    case 0x67a4cf49:            /* device class */
        if (x->b == real_device_count) x->rax = 0x20;
        break;

    case 0x0ac21584:            /* sensor count for (device, class) */
        if (x->b == real_device_count)
        {
            struct gpu_readings gpu;

            read_gpu( &gpu );
            switch ((unsigned)x->c) {
            case 0x2000: case 0x3000: case 0x5000: case 0xe000: case 0xf000:
                x->rax = gpu.valid ? 1 : 0;
                break;
            }
        }
        break;

    case 0xac2b5856:            /* sensor value: id, name, value, min, max, avg */
        if (x->b == real_device_count && x->c == 0)
        {
            struct gpu_readings gpu;
            const char *name = NULL;
            float value = -1.0f;
            unsigned bits;

            read_gpu( &gpu );
            if (gpu.valid) switch ((unsigned)x->d) {
            case 0x2000: value = gpu.temperature; name = "GPU"; break;
            case 0x3000: value = gpu.fan;         name = "GPU Fan"; break;
            case 0x5000: value = gpu.power;       name = "GPU Power"; break;
            case 0xe000: value = gpu.load;        name = "GPU Load"; break;
            case 0xf000: value = gpu.clock;       name = "GPU Clock"; break;
            }
            if (name)
            {
                memcpy( &bits, &value, sizeof(bits) );
                if (readable( (void *)x->s5,  sizeof(unsigned) )) *(unsigned *)x->s5  = (unsigned)x->d;
                if (readable( (void *)x->s6,  sizeof(void *) ))
                    *(void **)x->s6 = SysAllocStringByteLen( name, (UINT)strlen( name ) );
                if (readable( (void *)x->s7,  sizeof(unsigned) )) *(unsigned *)x->s7  = bits;
                if (readable( (void *)x->s8,  sizeof(unsigned) )) *(unsigned *)x->s8  = bits;
                if (readable( (void *)x->s9,  sizeof(unsigned) )) *(unsigned *)x->s9  = bits;
                if (readable( (void *)x->s10, sizeof(unsigned) )) *(unsigned *)x->s10 = bits;
                x->rax = 1;
            }
        }
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
        accept_unlinked_gpu_entries();
        patch_import( "kernel32.dll", "GetProcAddress",
                      get_proc_address_hook, (void **)&real_get_proc_address );
        L("shim up: real=%p qi=%p", (void *)realmod, (void *)real_qi);
    }
    return TRUE;
}

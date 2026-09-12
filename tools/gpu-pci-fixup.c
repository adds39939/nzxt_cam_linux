/* Give display adapters their PCI location in the registry.
 *
 * CAM will not report a GPU unless it can read DEVPKEY_Device_BusNumber and
 * DEVPKEY_Device_Address for the adapter's device node: cam_helper asks for them
 * through CM_Get_DevNode_PropertyW, and abandons the adapter when either fails,
 * long before it gets as far as D3DKMT. Wine registers the GPU but leaves those
 * properties unset, so every card is skipped and the UI shows
 * "No supported graphics cards were found".
 *
 * Wine's cfgmgr32 maps those two keys onto the legacy registry values BusNumber
 * and Address under the device node, so filling them in is enough. The values
 * come from Linux: match the PCI ids in the Windows instance id against
 * /sys/bus/pci/devices and use the address the kernel reports.
 *
 * Run once per launch, before CAM starts.
 */
#include <windows.h>
#include <stdio.h>

/* Make Wine build its display device tree, before enumerating it below.
 *
 * win32u builds that tree lazily: the first process in a wineserver session to ask
 * for display information is the one that enumerates the GPUs, creates a device node
 * for each and deletes the nodes of any that have gone. A node that comes back is
 * reused rather than rebuilt, so the values written here survive -- which is why
 * writing them once per launch is normally enough.
 *
 * It is not enough when the set of GPUs changes, because then the nodes really are
 * new. A driver update does exactly that: the adapter Wine reports comes from the
 * Vulkan and OpenGL drivers, so it changes with them, the old node is deleted and the
 * replacement is created the first time something asks -- which, with nothing else
 * asking, is CAM itself, after this has run. CAM then reads the one node this pass
 * never saw, finds no BusNumber on it, and drops the adapter: no GPU on the
 * dashboard, and no GPU temperature, until the next launch.
 *
 * So ask first, and be that process. What follows then enumerates the same nodes CAM
 * will read, whether they are the ones from last launch or brand new.
 */
static void settle_display_devices( void )
{
    DISPLAY_DEVICEA device;

    device.cb = sizeof(device);
    /* The answer is of no interest -- asking is what builds the tree. */
    EnumDisplayDevicesA( NULL, 0, &device, 0 );
}

/* /sys/bus/pci/devices/0000:01:00.0 -> bus 1, device 0, function 0 */
static int linux_pci_address( unsigned vendor, unsigned device,
                              unsigned *bus, unsigned *dev, unsigned *func )
{
    WIN32_FIND_DATAA find;
    HANDLE handle = FindFirstFileA( "Z:\\sys\\bus\\pci\\devices\\*", &find );
    int found = 0;

    if (handle == INVALID_HANDLE_VALUE) return 0;
    do
    {
        char path[MAX_PATH];
        unsigned v = 0, d = 0, dom, b, dv, fn;
        FILE *f;

        if (find.cFileName[0] == '.') continue;
        if (sscanf( find.cFileName, "%x:%x:%x.%x", &dom, &b, &dv, &fn ) != 4) continue;

        snprintf( path, sizeof(path), "Z:\\sys\\bus\\pci\\devices\\%s\\vendor", find.cFileName );
        if (!(f = fopen( path, "r" ))) continue;
        if (fscanf( f, "%x", &v ) != 1) v = 0;
        fclose( f );

        snprintf( path, sizeof(path), "Z:\\sys\\bus\\pci\\devices\\%s\\device", find.cFileName );
        if (!(f = fopen( path, "r" ))) continue;
        if (fscanf( f, "%x", &d ) != 1) d = 0;
        fclose( f );

        if (v != vendor || d != device) continue;
        *bus = b; *dev = dv; *func = fn;
        found = 1;
    } while (!found && FindNextFileA( handle, &find ));
    FindClose( handle );
    return found;
}

static void fixup_device( const char *hardware_id, const char *instance )
{
    unsigned vendor = 0, device = 0, bus, dev, func;
    char path[512], location[64];
    HKEY key;
    DWORD value;

    if (sscanf( hardware_id, "VEN_%4x&DEV_%4x", &vendor, &device ) != 2) return;
    if (!linux_pci_address( vendor, device, &bus, &dev, &func ))
    {
        printf( "  %s: no matching PCI device on the host\n", hardware_id );
        return;
    }

    snprintf( path, sizeof(path), "System\\CurrentControlSet\\Enum\\PCI\\%s\\%s",
              hardware_id, instance );
    if (RegOpenKeyExA( HKEY_LOCAL_MACHINE, path, 0, KEY_SET_VALUE, &key )) return;

    value = bus;
    RegSetValueExA( key, "BusNumber", 0, REG_DWORD, (BYTE *)&value, sizeof(value) );
    value = (dev << 16) | func;            /* DEVPKEY_Device_Address for PCI */
    RegSetValueExA( key, "Address", 0, REG_DWORD, (BYTE *)&value, sizeof(value) );
    snprintf( location, sizeof(location), "PCI bus %u, device %u, function %u", bus, dev, func );
    RegSetValueExA( key, "LocationInformation", 0, REG_SZ,
                    (BYTE *)location, (DWORD)strlen( location ) + 1 );
    RegCloseKey( key );
    printf( "  %s\\%s -> bus %u, device %u, function %u\n", hardware_id, instance, bus, dev, func );
}

int main(void)
{
    HKEY pci;
    DWORD i;

    settle_display_devices();

    if (RegOpenKeyExA( HKEY_LOCAL_MACHINE, "System\\CurrentControlSet\\Enum\\PCI", 0,
                       KEY_ENUMERATE_SUB_KEYS, &pci ))
    {
        printf( "no PCI device nodes\n" );
        return 0;
    }
    printf( "Setting PCI location on display adapters:\n" );
    for (i = 0; ; i++)
    {
        char hardware_id[256];
        DWORD len = sizeof(hardware_id);
        HKEY hw;
        DWORD j;

        if (RegEnumKeyExA( pci, i, hardware_id, &len, NULL, NULL, NULL, NULL )) break;
        if (RegOpenKeyExA( pci, hardware_id, 0, KEY_ENUMERATE_SUB_KEYS, &hw )) continue;
        for (j = 0; ; j++)
        {
            char instance[256];
            DWORD ilen = sizeof(instance);

            if (RegEnumKeyExA( hw, j, instance, &ilen, NULL, NULL, NULL, NULL )) break;
            fixup_device( hardware_id, instance );
        }
        RegCloseKey( hw );
    }
    RegCloseKey( pci );
    return 0;
}

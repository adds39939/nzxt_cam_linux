/*
 * usbtree-fixup - give Wine's USB devices a Windows-shaped PnP tree.
 *
 * On Windows a composite USB device is the parent of its interfaces:
 *
 *     USB\VID_xxxx&PID_yyyy\<instance>          (composite, Address = hub port)
 *       +- USB\VID_xxxx&PID_yyyy&MI_00\<inst>   (interface)
 *       +- USB\VID_xxxx&PID_yyyy&MI_01\<inst>
 *            +- HID\VID_xxxx&PID_yyyy&MI_01\...
 *
 * Wine's tree is flat: wineusb and winebus enumerate the same physical device
 * independently and parent every node directly to their own synthetic root, so
 * walking from a HID interface never reaches the USB device or its port number.
 * Software that correlates a HID interface with its WinUSB sibling by walking to
 * the hub and port (NZXT CAM does exactly this) therefore sees nothing.
 *
 * This re-points DEVPKEY_Device_Parent of every USB interface node at the
 * matching composite, publishes the composite's children, and fills in
 * DEVPKEY_Device_Address from the port number Wine already encodes in the
 * composite's instance ID (usbver&revision&busnum&portnum).
 *
 * Wine's PnP manager rewrites Parent on every boot, so this has to run after
 * device enumeration and before the application starts.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#define ENUM_USB L"SYSTEM\\CurrentControlSet\\Enum\\USB"
/* DEVPKEY_Device_Parent / _Children live under Properties\{fmtid}\{pid} */
#define PROP_FMTID  L"{4340A6C5-93FA-4706-972C-7B648008A5A7}"
#define PID_PARENT  L"0008"
#define PID_CHILDREN L"0009"
#define DEVPROP_TYPE_STRING       0x00000012
#define DEVPROP_TYPE_STRING_LIST  0x00002012

struct node
{
    WCHAR device[256];    /* VID_1E71&PID_3012[&MI_01] */
    WCHAR instance[256];  /* 512&258&3&4              */
    WCHAR id[512];        /* USB\VID_...\512&258&3&4  */
};

static struct node *nodes;
static unsigned node_count, node_capacity;
static int verbose;

static void add_node( const WCHAR *device, const WCHAR *instance )
{
    struct node *n;

    if (node_count == node_capacity)
    {
        unsigned cap = node_capacity ? node_capacity * 2 : 32;
        struct node *tmp = realloc( nodes, cap * sizeof(*nodes) );
        if (!tmp) return;
        nodes = tmp;
        node_capacity = cap;
    }
    n = &nodes[node_count++];
    wcscpy( n->device, device );
    wcscpy( n->instance, instance );
    swprintf( n->id, ARRAYSIZE(n->id), L"USB\\%s\\%s", device, instance );
}

/* "VID_1E71&PID_3012&MI_01" -> "VID_1E71&PID_3012", or NULL if not an interface */
static const WCHAR *interface_base( const WCHAR *device, WCHAR *buf, size_t len )
{
    const WCHAR *mi = wcsstr( device, L"&MI_" );
    if (!mi) return NULL;
    if ((size_t)(mi - device) >= len) return NULL;
    memcpy( buf, device, (mi - device) * sizeof(WCHAR) );
    buf[mi - device] = 0;
    return buf;
}

static LONG set_prop( const WCHAR *id, const WCHAR *pid, DWORD type, const void *data, DWORD size )
{
    WCHAR path[1024];
    HKEY key;
    LONG err;

    swprintf( path, ARRAYSIZE(path), L"%s\\%s\\Properties\\%s\\%s",
              L"SYSTEM\\CurrentControlSet\\Enum", id, PROP_FMTID, pid );
    if ((err = RegCreateKeyExW( HKEY_LOCAL_MACHINE, path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL )))
        return err;
    err = RegSetValueExW( key, NULL, 0, type, data, size );
    RegCloseKey( key );
    return err;
}

/* The composite instance is "<usbver>&<revision>&<busnum>&<portnum>". */
static BOOL port_from_instance( const WCHAR *instance, DWORD *port )
{
    const WCHAR *p = instance;
    int fields = 0;
    WCHAR *end;

    while (*p)
    {
        if (*p == '&') fields++;
        p++;
    }
    if (fields != 3) return FALSE;
    if (!(p = wcsrchr( instance, '&' ))) return FALSE;
    *port = wcstoul( p + 1, &end, 10 );
    return end != p + 1;
}

static void enumerate( void )
{
    WCHAR device[256];
    DWORD i = 0, len;
    HKEY usb;

    if (RegOpenKeyExW( HKEY_LOCAL_MACHINE, ENUM_USB, 0, KEY_ENUMERATE_SUB_KEYS, &usb ))
        return;

    for (len = ARRAYSIZE(device); !RegEnumKeyExW( usb, i, device, &len, NULL, NULL, NULL, NULL );
         i++, len = ARRAYSIZE(device))
    {
        WCHAR instance[256];
        DWORD j = 0, ilen;
        HKEY dev;

        if (RegOpenKeyExW( usb, device, 0, KEY_ENUMERATE_SUB_KEYS, &dev )) continue;
        for (ilen = ARRAYSIZE(instance);
             !RegEnumKeyExW( dev, j, instance, &ilen, NULL, NULL, NULL, NULL );
             j++, ilen = ARRAYSIZE(instance))
            add_node( device, instance );
        RegCloseKey( dev );
    }
    RegCloseKey( usb );
}

int wmain( int argc, WCHAR **argv )
{
    unsigned i, j;
    int fixed = 0;

    if (argc > 1 && !wcscmp( argv[1], L"-v" )) verbose = 1;

    enumerate();
    if (verbose) wprintf( L"usbtree-fixup: %u USB device node(s)\n", node_count );

    for (i = 0; i < node_count; i++)
    {
        WCHAR base[256], children[4096];
        const struct node *composite = NULL;
        size_t clen = 0;
        DWORD port;

        /* only composites drive the fixup; skip interface nodes */
        if (wcsstr( nodes[i].device, L"&MI_" )) continue;
        composite = &nodes[i];

        for (j = 0; j < node_count; j++)
        {
            if (!interface_base( nodes[j].device, base, ARRAYSIZE(base) )) continue;
            if (wcscmp( base, composite->device )) continue;

            if (set_prop( nodes[j].id, PID_PARENT, DEVPROP_TYPE_STRING,
                          composite->id, (wcslen( composite->id ) + 1) * sizeof(WCHAR) ))
                continue;
            if (verbose) wprintf( L"  %s\n    parent -> %s\n", nodes[j].id, composite->id );
            fixed++;

            if (clen + wcslen( nodes[j].id ) + 2 < ARRAYSIZE(children))
            {
                wcscpy( children + clen, nodes[j].id );
                clen += wcslen( nodes[j].id ) + 1;
            }
        }

        if (clen)
        {
            children[clen++] = 0;
            set_prop( composite->id, PID_CHILDREN, DEVPROP_TYPE_STRING_LIST,
                      children, (DWORD)(clen * sizeof(WCHAR)) );
        }

        /* Address is a plain REG_DWORD value on the device key, not a property. */
        if (port_from_instance( composite->instance, &port ))
        {
            WCHAR path[1024];
            HKEY key;

            swprintf( path, ARRAYSIZE(path), L"SYSTEM\\CurrentControlSet\\Enum\\%s", composite->id );
            if (!RegOpenKeyExW( HKEY_LOCAL_MACHINE, path, 0, KEY_SET_VALUE, &key ))
            {
                RegSetValueExW( key, L"Address", 0, REG_DWORD, (const BYTE *)&port, sizeof(port) );
                RegCloseKey( key );
                if (verbose) wprintf( L"  %s\n    port   -> %lu\n", composite->id, port );
            }
        }
    }

    if (verbose) wprintf( L"usbtree-fixup: re-parented %d interface node(s)\n", fixed );
    free( nodes );
    return 0;
}

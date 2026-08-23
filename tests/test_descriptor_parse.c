/* Unit-test winusb.dll's configuration-descriptor walking against the real
 * NZXT Kraken Elite V2 (1e71:3012) descriptor. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef uint8_t UCHAR; typedef uint16_t USHORT; typedef uint32_t ULONG;
#define USB_INTERFACE_DESCRIPTOR_TYPE 4
#define USB_ENDPOINT_DESCRIPTOR_TYPE  5
enum { UsbdPipeTypeControl, UsbdPipeTypeIsochronous, UsbdPipeTypeBulk, UsbdPipeTypeInterrupt };

#pragma pack(push,1)
typedef struct { UCHAR bLength,bDescriptorType,bInterfaceNumber,bAlternateSetting,bNumEndpoints,
                 bInterfaceClass,bInterfaceSubClass,bInterfaceProtocol,iInterface; } USB_INTERFACE_DESCRIPTOR;
typedef struct { UCHAR bLength,bDescriptorType,bEndpointAddress,bmAttributes; USHORT wMaxPacketSize; UCHAR bInterval; } USB_ENDPOINT_DESCRIPTOR;
#pragma pack(pop)
typedef struct { ULONG PipeType; UCHAR PipeId; USHORT MaximumPacketSize; UCHAR Interval; } WINUSB_PIPE_INFORMATION;

struct winusb_handle { UCHAR *config; ULONG config_len; UCHAR interface_index; };

/* --- verbatim from dlls/winusb/main.c --- */
static const USB_INTERFACE_DESCRIPTOR *find_interface_impl(struct winusb_handle *device, UCHAR index, UCHAR alt, ULONG *offset)
{
    ULONG pos = 0;
    while (pos + 2 <= device->config_len) {
        const UCHAR *desc = device->config + pos;
        UCHAR length = desc[0], type = desc[1];
        if (!length || pos + length > device->config_len) break;
        if (type == USB_INTERFACE_DESCRIPTOR_TYPE) {
            const USB_INTERFACE_DESCRIPTOR *iface = (const USB_INTERFACE_DESCRIPTOR *)desc;
            if (iface->bInterfaceNumber == index && iface->bAlternateSetting == alt) {
                if (offset) *offset = pos;
                return iface;
            }
        }
        pos += length;
    }
    return NULL;
}
static int query_pipe(struct winusb_handle *device, UCHAR alt, UCHAR index, WINUSB_PIPE_INFORMATION *info)
{
    const USB_INTERFACE_DESCRIPTOR *iface; ULONG offset, pos, found = 0;
    if (!(iface = find_interface_impl(device, device->interface_index, alt, &offset))) return 0;
    pos = offset + iface->bLength;
    while (pos + 2 <= device->config_len) {
        const UCHAR *desc = device->config + pos;
        UCHAR length = desc[0], type = desc[1];
        if (!length || pos + length > device->config_len) break;
        if (type == USB_INTERFACE_DESCRIPTOR_TYPE) break;
        if (type == USB_ENDPOINT_DESCRIPTOR_TYPE) {
            const USB_ENDPOINT_DESCRIPTOR *ep = (const USB_ENDPOINT_DESCRIPTOR *)desc;
            if (found++ == index) {
                info->PipeId = ep->bEndpointAddress;
                info->MaximumPacketSize = ep->wMaxPacketSize;
                info->Interval = ep->bInterval;
                switch (ep->bmAttributes & 3) {
                    case 0: info->PipeType = UsbdPipeTypeControl; break;
                    case 1: info->PipeType = UsbdPipeTypeIsochronous; break;
                    case 2: info->PipeType = UsbdPipeTypeBulk; break;
                    default: info->PipeType = UsbdPipeTypeInterrupt; break;
                }
                return 1;
            }
        }
        pos += length;
    }
    return 0;
}
static UCHAR pipe_type_for_endpoint(struct winusb_handle *device, UCHAR endpoint)
{
    ULONG pos = 0;
    while (pos + 2 <= device->config_len) {
        const UCHAR *desc = device->config + pos;
        UCHAR length = desc[0], type = desc[1];
        if (!length || pos + length > device->config_len) break;
        if (type == USB_ENDPOINT_DESCRIPTOR_TYPE) {
            const USB_ENDPOINT_DESCRIPTOR *ep = (const USB_ENDPOINT_DESCRIPTOR *)desc;
            if (ep->bEndpointAddress == endpoint)
                return (ep->bmAttributes & 3) == 3 ? UsbdPipeTypeInterrupt : UsbdPipeTypeBulk;
        }
        pos += length;
    }
    return UsbdPipeTypeBulk;
}
/* --- end --- */

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (cond) printf("  ok   " msg "\n", ##__VA_ARGS__); \
    else { printf("  FAIL " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

int main(void)
{
    struct winusb_handle dev = {0};
    WINUSB_PIPE_INFORMATION pipe;
    const USB_INTERFACE_DESCRIPTOR *iface;
    FILE *f = fopen("kraken_elite_v2_config.bin", "rb");
    static UCHAR buf[4096]; size_t n;

    if (!f) { printf("cannot open kraken_config.bin\n"); return 1; }
    n = fread(buf, 1, sizeof(buf), f); fclose(f);
    dev.config = buf; dev.config_len = n;
    printf("config descriptor: %zu bytes\n", n);

    printf("interface 0 (vendor-specific, LCD bulk):\n");
    dev.interface_index = 0;
    iface = find_interface_impl(&dev, 0, 0, NULL);
    CHECK(iface != NULL, "interface 0 found");
    CHECK(iface && iface->bInterfaceClass == 255, "class is vendor-specific (255)");
    CHECK(iface && iface->bNumEndpoints == 1, "has 1 endpoint");
    CHECK(query_pipe(&dev, 0, 0, &pipe), "QueryPipe(0) succeeds");
    CHECK(pipe.PipeId == 0x02, "pipe id is 0x02 (got 0x%02x)", pipe.PipeId);
    CHECK(pipe.PipeType == UsbdPipeTypeBulk, "pipe type is Bulk (got %u)", pipe.PipeType);
    CHECK(pipe.MaximumPacketSize == 512, "max packet 512 (got %u)", pipe.MaximumPacketSize);
    CHECK(!query_pipe(&dev, 0, 1, &pipe), "QueryPipe(1) stops at next interface");

    printf("interface 1 (HID, control) -- must skip the HID descriptor:\n");
    dev.interface_index = 1;
    iface = find_interface_impl(&dev, 1, 0, NULL);
    CHECK(iface != NULL, "interface 1 found");
    CHECK(iface && iface->bInterfaceClass == 3, "class is HID (3)");
    CHECK(query_pipe(&dev, 0, 0, &pipe), "QueryPipe(0) succeeds past HID descriptor");
    CHECK(pipe.PipeId == 0x81, "pipe 0 is 0x81 IN (got 0x%02x)", pipe.PipeId);
    CHECK(pipe.PipeType == UsbdPipeTypeInterrupt, "pipe 0 is Interrupt (got %u)", pipe.PipeType);
    CHECK(query_pipe(&dev, 0, 1, &pipe), "QueryPipe(1) succeeds");
    CHECK(pipe.PipeId == 0x01, "pipe 1 is 0x01 OUT (got 0x%02x)", pipe.PipeId);
    CHECK(!query_pipe(&dev, 0, 2, &pipe), "QueryPipe(2) fails");

    printf("pipe_type_for_endpoint:\n");
    CHECK(pipe_type_for_endpoint(&dev, 0x02) == UsbdPipeTypeBulk, "0x02 -> Bulk");
    CHECK(pipe_type_for_endpoint(&dev, 0x81) == UsbdPipeTypeInterrupt, "0x81 -> Interrupt");
    CHECK(pipe_type_for_endpoint(&dev, 0x01) == UsbdPipeTypeInterrupt, "0x01 -> Interrupt");

    printf("missing alt setting:\n");
    CHECK(find_interface_impl(&dev, 0, 7, NULL) == NULL, "alt 7 not found");
    CHECK(find_interface_impl(&dev, 9, 0, NULL) == NULL, "interface 9 not found");

    printf("\n%s (%d failures)\n", fails ? "FAILURES" : "ALL PASS", fails);
    return fails != 0;
}

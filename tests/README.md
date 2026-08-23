# Tests

`test_descriptor_parse.c` exercises the configuration-descriptor walking used by
`winusb.dll` (`find_interface`, `QueryPipe`, `pipe_type_for_endpoint`) against
`kraken_elite_v2_config.bin` — the real descriptor read from an NZXT Kraken
Elite V2 (`1e71:3012`) via `/sys/bus/usb/devices/*/descriptors`.

It covers the two cases most likely to be wrong on a composite device:

- interface 1 has a HID descriptor (type 33) between it and its endpoints, which
  the endpoint walk must skip rather than stop on;
- interface 0's endpoint walk must stop at the next interface descriptor instead
  of running on into interface 1's endpoints.

```bash
cd tests && gcc -O1 -Wall -o test_descriptor_parse test_descriptor_parse.c && ./test_descriptor_parse
```

The logic is duplicated from `dlls/winusb/main.c` so it can be built natively;
keep them in sync when changing the parser.

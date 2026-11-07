/* check_offsets.c - compile-time check of the numbers hard-coded in driver/mmonet.asm.
 *
 * These come from the mingw-w64 driver headers, independently of the assembly. Compiling
 * this file is the test: a wrong number is a build error. It produces no program.
 */
#include <stddef.h>
#include <ddk/ntddk.h>

#define SAME(a, b) _Static_assert((a) == (b), #a " is not " #b)

_Static_assert(sizeof(void *) == 8, "x64 only");

SAME(offsetof(DRIVER_OBJECT, DriverUnload), 0x68);
SAME(offsetof(DRIVER_OBJECT, MajorFunction), 0x70);
SAME(IRP_MJ_CREATE, 0);
SAME(IRP_MJ_CLOSE, 2);
SAME(IRP_MJ_DEVICE_CONTROL, 0x0E);

SAME(offsetof(IRP, AssociatedIrp.SystemBuffer), 0x18);
SAME(offsetof(IRP, IoStatus.Status), 0x30);
SAME(offsetof(IRP, IoStatus.Information), 0x38);
SAME(offsetof(IRP, Tail.Overlay.CurrentStackLocation), 0xB8);

SAME(offsetof(IO_STACK_LOCATION, Parameters.DeviceIoControl.OutputBufferLength), 0x08);
SAME(offsetof(IO_STACK_LOCATION, Parameters.DeviceIoControl.InputBufferLength), 0x10);
SAME(offsetof(IO_STACK_LOCATION, Parameters.DeviceIoControl.IoControlCode), 0x18);

SAME(offsetof(UNICODE_STRING, Length), 0);
SAME(offsetof(UNICODE_STRING, MaximumLength), 2);
SAME(offsetof(UNICODE_STRING, Buffer), 8);

SAME(FILE_DEVICE_UNKNOWN, 0x22);
SAME(FILE_DEVICE_SECURE_OPEN, 0x100);
SAME(CTL_CODE(0x8000, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS), 0x80002000);
SAME((unsigned long)STATUS_INVALID_DEVICE_REQUEST, 0xC0000010);
SAME((unsigned long)STATUS_BUFFER_TOO_SMALL, 0xC0000023);

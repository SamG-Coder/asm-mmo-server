/* test_driver.c - runs the driver's code in user mode against a fake kernel.
 *
 * This checks the driver's logic: setup, failure cleanup, request handling and unload. It
 * can't prove that the kernel structure offsets match real Windows, because the fake
 * structures here use the same offsets. Only loading the driver in the VM can prove that.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct { uint16_t len, cap; uint32_t pad; const wchar_t *chars; } Ustr;

static int created, linked, deleted_dev, deleted_link, completed;
static int fail_device, fail_link;
static int last_status;
static char fake_device;

int IoCreateDevice(void *drv, uint32_t ext, Ustr *name, uint32_t type, uint32_t ch,
                   uint8_t excl, void **out) {
    (void)drv; (void)ext; (void)excl;
    if (fail_device) return (int)0xC0000001;
    if (wcscmp(name->chars, L"\\Device\\MmoNet") || name->len != 28 || name->cap != 30) {
        printf("  FAIL bad device name\n");
        return (int)0xC0000002;
    }
    if (type != 0x22 || ch != 0x100) printf("  FAIL bad device type or flags\n");
    *out = &fake_device;
    created++;
    return 0;
}
void IoDeleteDevice(void *dev) { if (dev == &fake_device) deleted_dev++; }
int IoCreateSymbolicLink(Ustr *link, Ustr *dev) {
    if (wcscmp(link->chars, L"\\DosDevices\\MmoNet") || link->len != 36 || link->cap != 38 ||
        wcscmp(dev->chars, L"\\Device\\MmoNet")) {
        printf("  FAIL bad link name\n");
        return (int)0xC0000002;
    }
    if (fail_link) return (int)0xC0000003;
    linked++;
    return 0;
}
int IoDeleteSymbolicLink(Ustr *link) {
    if (!wcscmp(link->chars, L"\\DosDevices\\MmoNet")) deleted_link++;
    return 0;
}
void IofCompleteRequest(uint8_t *irp, int8_t boost) {
    (void)boost;
    last_status = *(int *)(irp + 0x30);
    completed++;
}

#ifdef TEST_IMAGE
/* Load the finished mmonet.sys the way the kernel's loader does, rather than linking its
   object file: map the sections, apply relocations and resolve imports to the fakes above. */
#include <windows.h>
static int (*DriverEntry)(void *drv, void *path);

static void *fake_export(const char *name) {
    if (!strcmp(name, "IoCreateDevice")) return (void *)IoCreateDevice;
    if (!strcmp(name, "IoDeleteDevice")) return (void *)IoDeleteDevice;
    if (!strcmp(name, "IoCreateSymbolicLink")) return (void *)IoCreateSymbolicLink;
    if (!strcmp(name, "IoDeleteSymbolicLink")) return (void *)IoDeleteSymbolicLink;
    if (!strcmp(name, "IofCompleteRequest")) return (void *)IofCompleteRequest;
    return NULL;
}

static void die_image(const char *why) {
    printf("FAIL %s\n", why);
    exit(1);
}

static void map_image(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) die_image("can't open the driver file");
    static uint8_t file[1 << 20];
    size_t size = fread(file, 1, sizeof file, f);
    fclose(f);
    if (size < sizeof(IMAGE_DOS_HEADER)) die_image("file too small");

    IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(file + ((IMAGE_DOS_HEADER *)file)->e_lfanew);
    IMAGE_OPTIONAL_HEADER64 *opt = &nt->OptionalHeader;
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64)
        die_image("not an x64 image");
    if (opt->Subsystem != IMAGE_SUBSYSTEM_NATIVE) die_image("not a native-subsystem image");
    if (!opt->CheckSum) die_image("no PE checksum (the kernel requires one for drivers)");
    printf("ok   x64 native image with a checksum\n");

    uint8_t *base = VirtualAlloc(NULL, opt->SizeOfImage, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!base) die_image("can't allocate image");
    memcpy(base, file, opt->SizeOfHeaders);
    IMAGE_SECTION_HEADER *sec = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        uint32_t c = sec[i].Characteristics;
        if ((c & IMAGE_SCN_MEM_EXECUTE) && (c & IMAGE_SCN_MEM_WRITE))
            die_image("a section is writable and executable (memory integrity forbids this)");
        memcpy(base + sec[i].VirtualAddress, file + sec[i].PointerToRawData, sec[i].SizeOfRawData);
    }
    printf("ok   no section is both writable and executable\n");

    /* Relocations: these are what make the static name pointers valid. */
    uint64_t delta = (uint64_t)base - opt->ImageBase;
    if (!delta) die_image("loaded at the preferred base, so relocations went untested");
    IMAGE_DATA_DIRECTORY *dir = &opt->DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
    int applied = 0;
    for (uint32_t off = 0; off < dir->Size;) {
        IMAGE_BASE_RELOCATION *block = (IMAGE_BASE_RELOCATION *)(base + dir->VirtualAddress + off);
        uint16_t *item = (uint16_t *)(block + 1);
        int count = (int)((block->SizeOfBlock - sizeof *block) / 2);
        for (int i = 0; i < count; i++) {
            int type = item[i] >> 12;
            if (type == IMAGE_REL_BASED_DIR64) {
                *(uint64_t *)(base + block->VirtualAddress + (item[i] & 0xFFF)) += delta;
                applied++;
            } else if (type != IMAGE_REL_BASED_ABSOLUTE) {
                die_image("unsupported relocation type");
            }
        }
        off += block->SizeOfBlock;
    }
    if (!applied) die_image("no relocations, but the driver has static pointers");
    printf("ok   %d relocations applied at a different base\n", applied);

    dir = &opt->DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    int imports = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); d->Name; d++) {
        if (_stricmp((char *)(base + d->Name), "ntoskrnl.exe")) die_image("imports from something other than ntoskrnl");
        IMAGE_THUNK_DATA64 *names = (IMAGE_THUNK_DATA64 *)(base + d->OriginalFirstThunk);
        IMAGE_THUNK_DATA64 *iat = (IMAGE_THUNK_DATA64 *)(base + d->FirstThunk);
        for (; names->u1.AddressOfData; names++, iat++) {
            if (names->u1.Ordinal & IMAGE_ORDINAL_FLAG64) die_image("import by ordinal");
            const char *name = ((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name;
            void *fn = fake_export(name);
            if (!fn) die_image(name);
            iat->u1.Function = (uint64_t)fn;
            imports++;
        }
    }
    printf("ok   %d imports resolved, all from ntoskrnl\n", imports);

    for (int i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        DWORD old;
        DWORD prot = (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) ? PAGE_EXECUTE_READ : PAGE_READWRITE;
        if (sec[i].Misc.VirtualSize)
            VirtualProtect(base + sec[i].VirtualAddress, sec[i].Misc.VirtualSize, prot, &old);
    }
    DriverEntry = (int (*)(void *, void *))(base + opt->AddressOfEntryPoint);
}
#else
extern int DriverEntry(void *drv, void *path);
#endif

typedef int (*Dispatch)(void *, void *);
typedef void (*Unload)(void *);

static int failures;
/* Evaluates c once: the conditions call into the driver and have side effects. */
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) failures++; } while (0)

static int call_ioctl(uint8_t *drv, uint32_t code, uint32_t in, uint32_t out, uint64_t *buf,
                      uint64_t *info) {
    uint8_t irp[0x100] = {0}, stack[0x48] = {0};
    *(uint64_t **)(irp + 0x18) = buf;
    *(uint8_t **)(irp + 0xB8) = stack;
    *(uint32_t *)(stack + 0x08) = out;
    *(uint32_t *)(stack + 0x10) = in;
    *(uint32_t *)(stack + 0x18) = code;
    int before = completed;
    int r = (*(Dispatch *)(drv + 0x70 + 0x0E * 8))(&fake_device, irp);
    if (completed != before + 1) { printf("FAIL request not completed exactly once\n"); failures++; }
    if (r != last_status) { printf("FAIL returned status differs from IRP status\n"); failures++; }
    *info = *(uint64_t *)(irp + 0x38);
    return r;
}

int main(int argc, char **argv) {
    uint8_t drv[0x200];
    uint64_t info, buf;

#ifdef TEST_IMAGE
    map_image(argc > 1 ? argv[1] : "build/driver/mmonet.sys");
#else
    (void)argc;
    (void)argv;
#endif

    memset(drv, 0, sizeof drv);
    fail_device = 1;
    CHECK(DriverEntry(drv, NULL) < 0, "device failure is reported");
    CHECK(*(void **)(drv + 0x68) == NULL, "no unload handler after device failure");
    fail_device = 0;

    memset(drv, 0, sizeof drv);
    fail_link = 1;
    CHECK(DriverEntry(drv, NULL) == (int)0xC0000003, "link failure returns its status");
    CHECK(deleted_dev == 1, "link failure deletes the device");
    CHECK(*(void **)(drv + 0x68) == NULL, "no unload handler after link failure");
    fail_link = 0;
    deleted_dev = 0;

    memset(drv, 0, sizeof drv);
    CHECK(DriverEntry(drv, NULL) == 0, "driver starts");
    CHECK(*(void **)(drv + 0x70) && *(void **)(drv + 0x70 + 2 * 8) && *(void **)(drv + 0x70 + 0xE * 8),
          "handlers installed");

    uint8_t irp[0x100] = {0};
    CHECK((*(Dispatch *)(drv + 0x70))(&fake_device, irp) == 0 && last_status == 0, "open succeeds");

    buf = 0x0123456789ABCDEFull;
    CHECK(call_ioctl(drv, 0x80002000, 8, 8, &buf, &info) == 0, "ping succeeds");
    CHECK(buf == (0x0123456789ABCDEFull ^ 0x4D4D4F4E45543031ull), "ping reply is correct");
    CHECK(info == 8, "ping reports 8 bytes");

    buf = 7;
    CHECK(call_ioctl(drv, 0x80002000, 4, 8, &buf, &info) == (int)0xC0000023, "short input refused");
    CHECK(buf == 7 && info == 0, "short input leaves the buffer alone");
    CHECK(call_ioctl(drv, 0x80002000, 8, 4, &buf, &info) == (int)0xC0000023, "short output refused");
    CHECK(buf == 7 && info == 0, "short output leaves the buffer alone");
    CHECK(call_ioctl(drv, 0x80002004, 8, 8, &buf, &info) == (int)0xC0000010, "unknown request refused");
    CHECK(buf == 7 && info == 0, "unknown request leaves the buffer alone");

    (*(Unload *)(drv + 0x68))(drv);
    CHECK(deleted_link == 1 && deleted_dev == 1, "unload removes link and device");

    printf(failures ? "FAILED: %d\n" : "all driver logic tests passed\n", failures);
    return failures != 0;
}

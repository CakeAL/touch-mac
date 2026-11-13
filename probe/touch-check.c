
// clang -Wall -Wextra -O2 touch-check.c \
//   -framework IOKit \
//   -framework CoreFoundation \
//   -o touch-check

// ./touch-check

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <inttypes.h>

static const CFStringRef keys[] = {
    CFSTR("displayUUID"),
    CFSTR("CGDirectDisplayID"),
    CFSTR("DigitizerCollectionDispatch"),
    CFSTR("DisplayIntegrated"),
    CFSTR("HIDVirtualDevice"),
    CFSTR("HIDDefaultBehavior"),
    CFSTR("Transport"),
    CFSTR("Product"),
    CFSTR("PrimaryUsagePage"),
    CFSTR("PrimaryUsage")
};

#define KEY_COUNT (sizeof(keys) / sizeof(keys[0]))

static void value_to_string(CFTypeRef value,
                            char *buf, size_t len) {
    if (!value) {
        snprintf(buf, len, "<missing>");
        return;
    }

    CFStringRef description = CFCopyDescription(value);
    if (!description) {
        snprintf(buf, len, "<unprintable>");
        return;
    }

    if (!CFStringGetCString(
            description, buf, (CFIndex)len,
            kCFStringEncodingUTF8)) {
        snprintf(buf, len, "<conversion failed>");
    }

    CFRelease(description);
}

static void get_key_name(CFStringRef key,
                         char *buf, size_t len) {
    if (!CFStringGetCString(
            key, buf, (CFIndex)len,
            kCFStringEncodingUTF8)) {
        snprintf(buf, len, "?");
    }
}

static int is_target(io_registry_entry_t entry,
                     const char *product) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        entry, CFSTR("Product"),
        kCFAllocatorDefault, 0);

    int matched = 0;

    if (value && CFGetTypeID(value) ==
                     CFStringGetTypeID()) {
        CFStringRef target = CFStringCreateWithCString(
            kCFAllocatorDefault,
            product,
            kCFStringEncodingUTF8);

        if (target) {
            matched = CFStringCompare(
                (CFStringRef)value, target, 0
            ) == kCFCompareEqualTo;

            CFRelease(target);
        }
    }

    if (value) CFRelease(value);
    return matched;
}

static void inspect(io_registry_entry_t entry,
                    const char *label) {
    uint64_t registryID = 0;
    char className[128] = {0};
    char entryName[128] = {0};

    IORegistryEntryGetRegistryEntryID(
        entry, &registryID);

    IOObjectGetClass(entry, className);
    IORegistryEntryGetName(entry, entryName);

    printf("\n====================================\n");
    printf("%s\n", label);
    printf("====================================\n");
    printf("RegistryID: 0x%" PRIx64 "\n", registryID);
    printf("Class:      %s\n", className);
    printf("Name:       %s\n\n", entryName);

    for (size_t i = 0; i < KEY_COUNT; i++) {
        char keyName[128] = {0};
        char direct[1024] = {0};
        char inherited[1024] = {0};

        get_key_name(
            keys[i], keyName, sizeof(keyName));

        CFTypeRef directValue =
            IORegistryEntryCreateCFProperty(
                entry, keys[i],
                kCFAllocatorDefault, 0);

        CFTypeRef inheritedValue =
            IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane,
                keys[i], kCFAllocatorDefault,
                kIORegistryIterateParents |
                kIORegistryIterateRecursively);

        value_to_string(
            directValue, direct, sizeof(direct));

        value_to_string(
            inheritedValue, inherited,
            sizeof(inherited));

        printf("%-30s\n", keyName);
        printf("  Direct : %s\n", direct);
        printf("  Search : %s\n", inherited);

        if (directValue) CFRelease(directValue);
        if (inheritedValue) CFRelease(inheritedValue);
    }
}

int main(int argc, char **argv) {
    const char *product =
        argc > 1 ? argv[1] : "SAMSUNG_Android";

    io_iterator_t iterator = IO_OBJECT_NULL;

    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleUserHIDEventService"),
        &iterator);

    if (kr != KERN_SUCCESS) {
        printf("Matching failed: 0x%08x\n",
               (unsigned)kr);
        return 1;
    }

    io_service_t service;
    int found = 0;

    while ((service = IOIteratorNext(iterator))) {
        if (!is_target(service, product)) {
            IOObjectRelease(service);
            continue;
        }

        found = 1;

        inspect(service, "HID EVENT SERVICE");

        io_registry_entry_t current = service;
        IOObjectRetain(current);

        for (int depth = 0; depth < 8; depth++) {
            io_registry_entry_t parent =
                IO_OBJECT_NULL;

            kr = IORegistryEntryGetParentEntry(
                current, kIOServicePlane, &parent);

            IOObjectRelease(current);

            if (kr != KERN_SUCCESS ||
                parent == IO_OBJECT_NULL) {
                break;
            }

            char label[64];
            snprintf(label, sizeof(label),
                     "PARENT LEVEL %d", depth + 1);

            inspect(parent, label);

            current = parent;
        }

        if (kr == KERN_SUCCESS) {
            IOObjectRelease(current);
        }

        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);

    if (!found) {
        printf("No HID Event Service found for: %s\n",
               product);
        printf("Check with:\n");
        printf("hidutil list --matching "
               "'{\"PrimaryUsagePage\":13,"
               "\"PrimaryUsage\":4}'\n");
        return 1;
    }

    return 0;
}

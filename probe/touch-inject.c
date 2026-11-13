// clang touch-inject.c \
//   -framework IOKit \
//   -framework CoreFoundation \
//   -o touch-inject

// ./touch-inject
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdint.h>

static io_service_t byID(uint64_t id)
{
    return IOServiceGetMatchingService(
        kIOMainPortDefault,
        IORegistryEntryIDMatching(id));
}

static void printProperty(io_service_t service,
                          CFStringRef key,
                          int searchParents)
{
    CFTypeRef value = searchParents
                          ? IORegistryEntrySearchCFProperty(
                                service, kIOServicePlane, key,
                                kCFAllocatorDefault,
                                kIORegistryIterateParents |
                                    kIORegistryIterateRecursively)
                          : IORegistryEntryCreateCFProperty(
                                service, key, kCFAllocatorDefault, 0);

    if (!value)
    {
        printf("  NULL\n");
        return;
    }

    CFStringRef desc = CFCopyDescription(value);
    char buf[1024] = {0};
    if (desc &&
        CFStringGetCString(desc, buf, sizeof(buf),
                           kCFStringEncodingUTF8))
    {
        printf("  %s\n", buf);
    }

    if (desc)
        CFRelease(desc);
    CFRelease(value);
}

int main(void)
{
    io_service_t device = byID(0x10004bf39ULL);
    io_service_t event = byID(0x10004bf39ULL);

    if (!device || !event)
    {
        puts("Device not found. Check RegistryIDs.");
        if (device)
            IOObjectRelease(device);
        if (event)
            IOObjectRelease(event);
        return 1;
    }

    CFStringRef uuid = CFSTR(
        "8BF51424-0C57-4680-A7F9-9092F20311B9");

    int32_t displayID = 3;
    CFNumberRef display = CFNumberCreate(
        NULL, kCFNumberSInt32Type, &displayID);

    const CFStringRef keys[] = {
        CFSTR("displayUUID"),
        CFSTR("CGDirectDisplayID"),
        CFSTR("DigitizerCollectionDispatch")};

    const CFTypeRef values[] = {
        uuid,
        display,
        kCFBooleanTrue};

    for (int i = 0; i < 3; i++)
    {
        kern_return_t kr = IORegistryEntrySetCFProperty(
            device, keys[i], values[i]);

        char keyName[128];
        CFStringGetCString(keys[i], keyName,
                           sizeof(keyName),
                           kCFStringEncodingUTF8);

        printf("%s: set result = 0x%08x\n",
               keyName, (unsigned)kr);

        printf("  Device direct readback:");
        printProperty(device, keys[i], 0);
        printf("  Event direct readback:");
        printProperty(event, keys[i], 0);
        printf("  Event parent search:");
        printProperty(event, keys[i], 1);
    }

    CFRelease(display);
    IOObjectRelease(device);
    IOObjectRelease(event);
    return 0;
}

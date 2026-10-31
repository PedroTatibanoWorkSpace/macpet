#include "CSensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>

// Declarações da API privada do IOHIDEventSystem (a mesma usada pelo Stats e pelo powermetrics).
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kTemperatureField (kIOHIDEventTypeTemperature << 16)

static IOHIDEventSystemClientRef client = NULL;
static CFArrayRef services = NULL;

static void ensure_services(void) {
    if (services) return;

    int page = 0xff00, usage = 5; // AppleVendor / TemperatureSensor
    CFNumberRef pageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {pageRef, usageRef};
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client) {
        IOHIDEventSystemClientSetMatching(client, matching);
        services = IOHIDEventSystemClientCopyServices(client);
    }
    CFRelease(matching);
    CFRelease(pageRef);
    CFRelease(usageRef);
}

/// Agrega os sensores cujo nome contém `needle`. `use_max` = 1 retorna o máximo, senão a média.
static double read_sensors(const char *needle, int use_max) {
    ensure_services();
    if (!services) return -1;

    double acc = use_max ? -1 : 0;
    int count = 0;
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef nameRef = (CFStringRef)IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!nameRef) continue;
        char name[128] = {0};
        CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(nameRef);
        if (!strstr(name, needle)) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, kTemperatureField);
        CFRelease(event);
        if (value <= 0 || value > 150) continue; // sensores desligados reportam valores negativos

        if (use_max) {
            if (value > acc) acc = value;
        } else {
            acc += value;
        }
        count++;
    }
    if (count == 0) return -1;
    return use_max ? acc : acc / count;
}

double csensors_cpu_temperature(void) {
    return read_sensors("tdie", 1);
}

double csensors_battery_temperature(void) {
    return read_sensors("battery", 0);
}

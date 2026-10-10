#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Steam exposes at most sixteen emulated gamepad indices.
constexpr int kGamepadCount = 16;

struct JoystickGUID {
    uint8_t data[16];
};

// SDL2's public GUID format uses a CRC-16/IBM of the original HID name.
// Check the complete GUID, not just the Xbox VID/PID shared by real devices.
static JoystickGUID virtualGamepadGUID(unsigned slot, uint16_t version) {
    char name[64];
    snprintf(name, sizeof(name), "Microsoft GamePad-%u", slot + 1);
    uint16_t crc = 0;
    for (const unsigned char *p = (const unsigned char *)name; *p; ++p) {
        crc ^= *p;
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ ((crc & 1) ? 0xa001 : 0);
        }
    }
    return {{3, 0, (uint8_t)crc, (uint8_t)(crc >> 8), 0x5e, 4, 0, 0, 0x8e, 2, 0, 0,
             (uint8_t)version, (uint8_t)(version >> 8), 0, 0}};
}

static int virtualGamepadSlot(JoystickGUID guid, const char *transport, const char *manufacturer,
                              const char *product, int vendor, int model, uint16_t version) {
    if (!transport || strcmp(transport, "Virtual") || !manufacturer ||
        strcmp(manufacturer, "Microsoft") || !product || vendor != 0x045e || model != 0x028e) {
        return -1;
    }
    unsigned number = 0;
    char extra;
    if (sscanf(product, "GamePad-%u%c", &number, &extra) != 1 || number < 1 ||
        number > kGamepadCount) {
        return -1;
    }
    // SDL HIDAPI uses the same GUID plus its documented driver signature.
    // Darwin IOKit leaves that byte zero. Both can enumerate Steam's device.
    if (guid.data[14] != 0 && guid.data[14] != 'h') {
        return -1;
    }
    guid.data[14] = 0;
    JoystickGUID expected = virtualGamepadGUID(number - 1, version);
    return !memcmp(&guid, &expected, sizeof(guid)) ? (int)number - 1 : -1;
}

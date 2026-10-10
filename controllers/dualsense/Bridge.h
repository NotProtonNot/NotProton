#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Immutable session configuration is initialized before Wine starts using HID/audio.
bool DSBBridgeEnabled(void);
bool DSBRawControllerEnabled(void);
bool DSBDirectPCMEnabled(void);
void DSBSendPacket(uint32_t kind, float left, float right, const uint8_t *report, size_t size);

#define DSB_INTERPOSE(new, old)                                                                    \
    __attribute__((used)) static struct {                                                          \
        const void *a, *b;                                                                         \
    } ip_##old __attribute__((section("__DATA,__interpose"))) = {(void *)new, (void *)old}

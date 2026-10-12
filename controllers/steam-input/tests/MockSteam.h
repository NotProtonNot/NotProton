#pragma once
#include <cstdint>

struct RumbleEvent {
    uint64_t handle;
    uint16_t left, right;
};
struct SessionStats {
    unsigned pipes, releasedPipes, users, releasedUsers, initializations, shutdowns;
};

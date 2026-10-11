// A Windows named-pipe client exercises the same endpoint used by Discord's SDK.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../protocol.h"

static BOOL exact(HANDLE pipe, void *bytes, DWORD length, BOOL writing)
{
    DWORD offset = 0;
    while (offset < length) {
        DWORD count = 0;
        BOOL ok = writing ? WriteFile(pipe, (char *)bytes + offset, length - offset, &count, NULL)
                          : ReadFile(pipe, (char *)bytes + offset, length - offset, &count, NULL);
        if (!ok || !count) return FALSE;
        offset += count;
    }
    return TRUE;
}

struct echo {
    HANDLE pipe;
    DWORD size;
    unsigned seed;
};

static DWORD WINAPI write_echo(void *parameter)
{
    struct echo *e = parameter;
    unsigned char buffer[1009];
    for (DWORD offset = 0; offset < e->size;) {
        DWORD n = e->size - offset;
        if (n > sizeof(buffer)) n = sizeof(buffer);
        for (DWORD i = 0; i < n; ++i) buffer[i] = (unsigned char)((offset + i) * 31 + e->seed);
        if (!exact(e->pipe, buffer, n, TRUE)) return 1;
        offset += n;
    }
    return 0;
}

static int thread_count(void)
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 1;
    PROCESSENTRY32 entry = {.dwSize = sizeof(entry)};
    DWORD pid = 0;
    if (Process32First(snapshot, &entry)) {
        do {
            if (!strcmp(entry.szExeFile, "notproton-discord.exe")) { pid = entry.th32ProcessID; break; }
        } while (Process32Next(snapshot, &entry));
    }
    CloseHandle(snapshot);
    if (!pid) return 1;
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 1;
    THREADENTRY32 thread = {.dwSize = sizeof(thread)};
    unsigned count = 0;
    if (Thread32First(snapshot, &thread)) {
        do {
            if (thread.th32OwnerProcessID == pid) ++count;
        } while (Thread32Next(snapshot, &thread));
    }
    CloseHandle(snapshot);
    printf("%u\n", count);
    return count ? 0 : 1;
}

static int rpc(HANDLE pipe, const char *id)
{
    char json[256];
    int length = snprintf(json, sizeof(json), "{\"v\":1,\"client_id\":\"%s\"}", id);
    if (length < 0 || length >= (int)sizeof(json)) return 1;
    uint32_t header[] = {0, (uint32_t)length};
    if (!exact(pipe, header, sizeof(header), TRUE) || !exact(pipe, json, length, TRUE) ||
        !exact(pipe, header, sizeof(header), FALSE) || header[0] != 1 || header[1] > 65536) return 1;
    char *body = calloc(header[1] + 1, 1);
    if (!body) return 1;
    BOOL ready = exact(pipe, body, header[1], FALSE) && strstr(body, "\"READY\"") != NULL;
    free(body);
    if (!ready) return 1;
    puts("  ok    Discord handshake: READY");
    char ping[] = "{\"nonce\":\"notproton-ipc-test\"}";
    header[0] = 3;
    header[1] = sizeof(ping) - 1;
    if (!exact(pipe, header, sizeof(header), TRUE) || !exact(pipe, ping, header[1], TRUE) ||
        !exact(pipe, header, sizeof(header), FALSE) || header[0] != 4 || header[1] != sizeof(ping) - 1) {
        fprintf(stderr, "unexpected PONG header: opcode=%u length=%u\n", header[0], header[1]);
        return 1;
    }
    char pong[sizeof(ping)] = {0};
    if (!exact(pipe, pong, header[1], FALSE) || strcmp(ping, pong)) return 1;
    puts("  ok    Discord PING/PONG: round trip");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "threads")) return thread_count();
    if (argc < 3) return 64;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 100; ++attempt) {
        pipe = CreateFileA(DISCORD_PIPE, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (pipe != INVALID_HANDLE_VALUE) break;
        Sleep(50);
    }
    if (pipe == INVALID_HANDLE_VALUE) { fprintf(stderr, "pipe unavailable: %lu\n", GetLastError()); return 1; }
    int status = 1;
    if (!strcmp(argv[1], "rpc")) status = rpc(pipe, argv[2]);
    else if (!strcmp(argv[1], "wait")) {
        puts("connected");
        fflush(stdout);
        char byte;
        DWORD count;
        BOOL result = ReadFile(pipe, &byte, 1, &count, NULL);
        status = !result || !count ? 0 : 1;
    } else if (!strcmp(argv[1], "echo")) {
        struct echo e = {pipe, (DWORD)strtoul(argv[2], NULL, 10), argc > 3 ? (unsigned)atoi(argv[3]) : 7};
        HANDLE writer = CreateThread(NULL, 0, write_echo, &e, 0, NULL);
        if (!writer) { CloseHandle(pipe); return 1; }
        unsigned char buffer[4093];
        status = 0;
        for (DWORD offset = 0; offset < e.size;) {
            DWORD n = e.size - offset;
            if (n > sizeof(buffer)) n = sizeof(buffer);
            if (!exact(pipe, buffer, n, FALSE)) { status = 1; break; }
            for (DWORD i = 0; i < n; ++i)
                if (buffer[i] != (unsigned char)((offset + i) * 31 + e.seed)) status = 1;
            offset += n;
        }
        if (status) CancelSynchronousIo(writer);
        WaitForSingleObject(writer, INFINITE);
        DWORD result;
        GetExitCodeThread(writer, &result);
        CloseHandle(writer);
        if (result) status = 1;
        if (!status) printf("  ok    Windows pipe: %lu bytes, seed %u\n", e.size, e.seed);
    }
    CloseHandle(pipe);
    return status;
}

// Relay Discord's Windows named pipe to the native host over loopback TCP.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "protocol.h"

static HANDLE stopping;
static unsigned short port;
static char token[BRIDGE_TOKEN_LENGTH + 1];

struct session {
    HANDLE pipe, closed;
    SOCKET socket;
};

struct listener {
    HANDLE pipe, worker;
    OVERLAPPED connection;
    bool pending;
};

enum endpoint { PIPE_IO, SOCKET_IO };
enum operation { READ_IO, WRITE_IO };

struct direction {
    struct session *session;
    enum endpoint source;
};

static bool wait_io(HANDLE handle, enum endpoint endpoint, OVERLAPPED *op, HANDLE closed, DWORD *count)
{
    HANDLE events[] = {stopping, closed, op->hEvent};
    DWORD flags = 0;
    DWORD result = WaitForMultipleObjects(3, events, FALSE, INFINITE);
    if (result != WAIT_OBJECT_0 + 2) {
        CancelIoEx(handle, op);
        // The buffer and OVERLAPPED must remain alive until cancellation completes.
        if (endpoint == SOCKET_IO) WSAGetOverlappedResult((SOCKET)handle, op, count, TRUE, &flags);
        else GetOverlappedResult(handle, op, count, TRUE);
        return false;
    }
    return endpoint == SOCKET_IO ? WSAGetOverlappedResult((SOCKET)handle, op, count, FALSE, &flags)
                                 : GetOverlappedResult(handle, op, count, FALSE);
}

static bool transfer(struct session *s, enum endpoint endpoint, enum operation operation,
                     char *buffer, DWORD length, DWORD *count, OVERLAPPED *op)
{
    if (WaitForSingleObject(stopping, 0) == WAIT_OBJECT_0 ||
        WaitForSingleObject(s->closed, 0) == WAIT_OBJECT_0) return false;
    ResetEvent(op->hEvent);
    bool success;
    int error;
    HANDLE handle = endpoint == SOCKET_IO ? (HANDLE)s->socket : s->pipe;
    if (endpoint == SOCKET_IO) {
        WSABUF bytes = {length, buffer};
        DWORD flags = 0;
        int result = operation == WRITE_IO ? WSASend(s->socket, &bytes, 1, count, 0, op, NULL)
                                           : WSARecv(s->socket, &bytes, 1, count, &flags, op, NULL);
        success = result == 0;
        error = success ? 0 : WSAGetLastError();
    } else {
        success = operation == WRITE_IO ? WriteFile(s->pipe, buffer, length, count, op)
                                        : ReadFile(s->pipe, buffer, length, count, op);
        error = success ? 0 : (int)GetLastError();
    }
    if (!success && error == ERROR_IO_PENDING) success = wait_io(handle, endpoint, op, s->closed, count);
    return success && *count > 0;
}

static DWORD WINAPI pump(void *parameter)
{
    struct direction *d = parameter;
    struct session *s = d->session;
    enum endpoint destination = d->source == PIPE_IO ? SOCKET_IO : PIPE_IO;
    OVERLAPPED op = {0};
    op.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (op.hEvent) {
        char buffer[BRIDGE_BUFFER];
        DWORD count;
        while (transfer(s, d->source, READ_IO, buffer, sizeof(buffer), &count, &op)) {
            DWORD offset = 0;
            while (offset < count) {
                DWORD written;
                if (!transfer(s, destination, WRITE_IO, buffer + offset, count - offset, &written, &op))
                    goto finished;
                offset += written;
            }
        }
finished:
        CloseHandle(op.hEvent);
    }
    SetEvent(s->closed);
    return 0;
}

static SOCKET connect_host(unsigned char role)
{
    SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_handle == INVALID_SOCKET) return INVALID_SOCKET;
    WSAEVENT event = WSACreateEvent();
    if (event == WSA_INVALID_EVENT) { closesocket(socket_handle); return INVALID_SOCKET; }
    if (WSAEventSelect(socket_handle, event, FD_CONNECT)) {
        WSACloseEvent(event);
        closesocket(socket_handle);
        return INVALID_SOCKET;
    }
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    int result = connect(socket_handle, (struct sockaddr *)&address, sizeof(address));
    bool connected = result == 0;
    if (!connected && WSAGetLastError() == WSAEWOULDBLOCK) {
        HANDLE events[] = {stopping, event};
        WSANETWORKEVENTS network;
        if (WaitForMultipleObjects(2, events, FALSE, 2000) == WAIT_OBJECT_0 + 1 &&
            !WSAEnumNetworkEvents(socket_handle, event, &network))
            connected = (network.lNetworkEvents & FD_CONNECT) && !network.iErrorCode[FD_CONNECT_BIT];
    }
    if (WSAEventSelect(socket_handle, NULL, 0)) connected = false;
    u_long blocking = 0;
    if (ioctlsocket(socket_handle, FIONBIO, &blocking)) connected = false;
    WSACloseEvent(event);
    if (connected) {
        DWORD timeout = 2000;
        if (setsockopt(socket_handle, SOL_SOCKET, SO_SNDTIMEO, (char *)&timeout, sizeof(timeout))) {
            closesocket(socket_handle);
            return INVALID_SOCKET;
        }
        unsigned char hello[BRIDGE_HELLO_SIZE];
        memcpy(hello, token, BRIDGE_TOKEN_LENGTH);
        hello[BRIDGE_TOKEN_LENGTH] = role;
        size_t sent = 0;
        while (sent < sizeof(hello)) {
            int n = send(socket_handle, (char *)hello + sent, (int)(sizeof(hello) - sent), 0);
            if (n <= 0) break;
            sent += n;
        }
        if (sent == sizeof(hello)) return socket_handle;
    }
    closesocket(socket_handle);
    return INVALID_SOCKET;
}

static DWORD WINAPI serve(void *parameter)
{
    struct session s = {.pipe = parameter, .socket = connect_host(BRIDGE_STREAM)};
    if (s.socket != INVALID_SOCKET) {
        s.closed = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (s.closed) {
            struct direction directions[] = {{&s, PIPE_IO}, {&s, SOCKET_IO}};
            HANDLE writer = CreateThread(NULL, 0, pump, &directions[0], 0, NULL);
            if (writer) {
                pump(&directions[1]);
                WaitForSingleObject(writer, INFINITE);
                CloseHandle(writer);
            }
            CloseHandle(s.closed);
        }
        closesocket(s.socket);
    }
    return 0;
}

static bool listen_pipe(struct listener *listener)
{
    HANDLE event = listener->connection.hEvent;
    memset(&listener->connection, 0, sizeof(listener->connection));
    listener->connection.hEvent = event;
    ResetEvent(event);
    BOOL connected = ConnectNamedPipe(listener->pipe, &listener->connection);
    DWORD error = connected ? ERROR_SUCCESS : GetLastError();
    listener->pending = error == ERROR_IO_PENDING;
    // A client can connect between CreateNamedPipe and ConnectNamedPipe.
    if (connected || error == ERROR_PIPE_CONNECTED) return SetEvent(event);
    return listener->pending;
}

static int accept_clients(struct listener *listeners, SOCKET control)
{
    WSAEVENT event = WSACreateEvent();
    if (event == WSA_INVALID_EVENT) return 1;
    int status = 1;
    if (WSAEventSelect(control, event, FD_READ | FD_CLOSE)) goto finished;
    for (;;) {
        HANDLE events[BRIDGE_CLIENTS + 1] = {event};
        for (unsigned i = 0; i < BRIDGE_CLIENTS; ++i)
            events[i + 1] = listeners[i].worker ? listeners[i].worker : listeners[i].connection.hEvent;
        DWORD result = WaitForMultipleObjects(BRIDGE_CLIENTS + 1, events, FALSE, INFINITE);
        // The control connection stays silent until the native host shuts down.
        if (result == WAIT_OBJECT_0) { status = 0; break; }
        if (result < WAIT_OBJECT_0 + 1 || result > WAIT_OBJECT_0 + BRIDGE_CLIENTS) break;
        struct listener *listener = &listeners[result - WAIT_OBJECT_0 - 1];
        if (listener->worker) {
            CloseHandle(listener->worker);
            listener->worker = NULL;
        } else {
            DWORD count;
            bool connected = !listener->pending ||
                GetOverlappedResult(listener->pipe, &listener->connection, &count, FALSE);
            listener->pending = false;
            if (connected) listener->worker = CreateThread(NULL, 0, serve, listener->pipe, 0, NULL);
            if (listener->worker) continue;
        }
        DisconnectNamedPipe(listener->pipe);
        if (!listen_pipe(listener)) break;
    }
finished:
    WSAEventSelect(control, NULL, 0);
    WSACloseEvent(event);
    return status;
}

int main(void)
{
    char port_text[16];
    DWORD length = GetEnvironmentVariableA("NOTPROTON_DISCORD_PORT", port_text, sizeof(port_text));
    if (!length || length >= sizeof(port_text)) return 64;
    char *end;
    unsigned long value = strtoul(port_text, &end, 10);
    if (*end || !value || value > 65535) return 64;
    port = (unsigned short)value;
    if (GetEnvironmentVariableA("NOTPROTON_DISCORD_TOKEN", token, sizeof(token)) != BRIDGE_TOKEN_LENGTH) return 64;
    SetEnvironmentVariableA("NOTPROTON_DISCORD_PORT", NULL);
    SetEnvironmentVariableA("NOTPROTON_DISCORD_TOKEN", NULL);
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 1;
    stopping = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stopping) { WSACleanup(); return 1; }
    struct listener listeners[BRIDGE_CLIENTS] = {0};
    for (unsigned i = 0; i < BRIDGE_CLIENTS; ++i) listeners[i].pipe = INVALID_HANDLE_VALUE;
    unsigned count = 0;
    int status = 1;
    for (; count < BRIDGE_CLIENTS; ++count) {
        DWORD flags = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
        if (!count) flags |= FILE_FLAG_FIRST_PIPE_INSTANCE;
        struct listener *listener = &listeners[count];
        listener->pipe = CreateNamedPipeA(DISCORD_PIPE, flags,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            BRIDGE_CLIENTS, BRIDGE_BUFFER, BRIDGE_BUFFER, 0, NULL);
        if (listener->pipe == INVALID_HANDLE_VALUE) break;
        listener->connection.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!listener->connection.hEvent || !listen_pipe(listener)) break;
    }
    if (count == BRIDGE_CLIENTS) {
        SOCKET control = connect_host(BRIDGE_CONTROL);
        if (control != INVALID_SOCKET) {
            status = accept_clients(listeners, control);
            closesocket(control);
        }
    } else fprintf(stderr, "NotProton Discord: cannot own pipe (%lu)\n", GetLastError());
    SetEvent(stopping);
    for (unsigned i = 0; i < BRIDGE_CLIENTS; ++i) {
        struct listener *listener = &listeners[i];
        if (listener->worker) {
            WaitForSingleObject(listener->worker, INFINITE);
            CloseHandle(listener->worker);
        }
        if (listener->pending) {
            DWORD count;
            CancelIoEx(listener->pipe, &listener->connection);
            GetOverlappedResult(listener->pipe, &listener->connection, &count, TRUE);
        }
        if (listener->connection.hEvent) CloseHandle(listener->connection.hEvent);
        if (listener->pipe != INVALID_HANDLE_VALUE) CloseHandle(listener->pipe);
    }
    CloseHandle(stopping);
    WSACleanup();
    return status;
}

/*
 * Exports the macdrv entry points DXMT's winemetal.so looks up with dlsym. Upstream Wine
 * hides them, and DXMT's view of struct macdrv_win_data predates the client_view rename,
 * so get_win_data hands out a copy in the layout DXMT expects.
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <stdlib.h>

#include "macdrv.h"

struct dxmt_win_data
{
    HWND          hwnd;
    macdrv_window cocoa_window;
    macdrv_view   cocoa_view;
    macdrv_view   client_cocoa_view;
    struct macdrv_win_data *real;
};

static struct dxmt_win_data *dxmt_get_win_data(HWND hwnd)
{
    struct macdrv_win_data *real = get_win_data(hwnd);
    struct dxmt_win_data *data;

    if (!real) return NULL;
    if (!real->client_view)
    {
        /* Wine 11 only gives a window a client view once something renders into it. Make
         * one the way the GL and Vulkan paths do; the surface lives as long as the window. */
        release_win_data(real);
        macdrv_CreateClientSurface(hwnd, 0);
        if (!(real = get_win_data(hwnd))) return NULL;
    }
    if (!(data = calloc(1, sizeof(*data))))
    {
        release_win_data(real);
        return NULL;
    }
    data->hwnd = real->hwnd;
    data->cocoa_window = real->cocoa_window;
    data->cocoa_view = real->client_view;
    data->client_cocoa_view = real->client_view;
    data->real = real;
    return data;
}

static void dxmt_release_win_data(struct dxmt_win_data *data)
{
    if (!data) return;
    release_win_data(data->real);
    free(data);
}

static void dxmt_init_display_devices(BOOL force)
{
}

struct macdrv_functions_t
{
    void (*macdrv_init_display_devices)(BOOL);
    struct dxmt_win_data *(*get_win_data)(HWND hwnd);
    void (*release_win_data)(struct dxmt_win_data *data);
    macdrv_window (*macdrv_get_cocoa_window)(HWND hwnd, BOOL require_on_screen);
    macdrv_metal_device (*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(macdrv_metal_device d);
    macdrv_metal_view (*macdrv_view_create_metal_view)(macdrv_view v, macdrv_metal_device d);
    macdrv_metal_layer (*macdrv_view_get_metal_layer)(macdrv_metal_view v);
    void (*macdrv_view_release_metal_view)(macdrv_metal_view v);
};

__attribute__((visibility("default"))) struct macdrv_functions_t macdrv_functions =
{
    dxmt_init_display_devices,
    dxmt_get_win_data,
    dxmt_release_win_data,
    macdrv_get_cocoa_window,
    macdrv_create_metal_device,
    macdrv_release_metal_device,
    macdrv_view_create_metal_view,
    macdrv_view_get_metal_layer,
    macdrv_view_release_metal_view,
};

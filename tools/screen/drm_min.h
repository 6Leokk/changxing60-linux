/* Minimal DRM/KMS UAPI definitions -- just enough to set a mode and paint a dumb buffer.
 *
 * The 7552N's OpenWrt rootfs has no libdrm and no /dev/fb0 (the kernel is built without fbdev and
 * without DRM_FBDEV_EMULATION), so the status page talks to /dev/dri/card0 with the raw ioctls
 * instead of linking a library. Layouts below are the stable kernel ABI (include/uapi/drm/drm_mode.h).
 */
#ifndef MU300_DRM_MIN_H
#define MU300_DRM_MIN_H

#include <stdint.h>
#include <sys/ioctl.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef int32_t s32;

#define DRM_MODE_CONNECTED 1

struct drm_mode_modeinfo {
	u32 clock;
	u16 hdisplay, hsync_start, hsync_end, htotal, hskew;
	u16 vdisplay, vsync_start, vsync_end, vtotal, vscan;
	u32 vrefresh;
	u32 flags;
	u32 type;
	char name[32];
};

struct drm_mode_card_res {
	u64 fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
	u32 count_fbs, count_crtcs, count_connectors, count_encoders;
	u32 min_width, max_width, min_height, max_height;
};

struct drm_mode_get_connector {
	u64 encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
	u32 count_modes, count_props, count_encoders;
	u32 encoder_id, connector_id, connector_type, connector_type_id;
	u32 connection, mm_width, mm_height, subpixel, pad;
};

struct drm_mode_get_encoder {
	u32 encoder_id, encoder_type, crtc_id, possible_crtcs, possible_clones;
};

struct drm_mode_create_dumb {
	u32 height, width, bpp, flags;
	u32 handle, pitch;
	u64 size;
};

struct drm_mode_map_dumb {
	u32 handle, pad;
	u64 offset;
};

struct drm_mode_fb_cmd {
	u32 fb_id, width, height, pitch, bpp, depth, handle;
};

struct drm_mode_crtc {
	u64 set_connectors_ptr;
	u32 count_connectors, crtc_id, fb_id, x, y, gamma_size, mode_valid;
	struct drm_mode_modeinfo mode;
};

struct drm_mode_crtc_page_flip {
	u32 crtc_id, fb_id, flags, reserved;
	u64 user_data;
};

/* Events come back through read() on the DRM fd as {type, length} + payload; the flip event's
 * payload is drm_event_vblank. Needed for the double buffering in mu300-screen.c. */
struct drm_event {
	u32 type, length;
};

#define DRM_EVENT_VBLANK        0x01
#define DRM_EVENT_FLIP_COMPLETE 0x02

struct drm_event_vblank {
	struct drm_event base;
	u64 user_data;
	u32 tv_sec, tv_usec, sequence, crtc_id;
};

#define DRM_MODE_PAGE_FLIP_EVENT 0x01

#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_IOW(nr, type) _IOW(DRM_IOCTL_BASE, nr, type)
#define DRM_IO(nr) _IO(DRM_IOCTL_BASE, nr)

#define DRM_IOCTL_MODE_GETRESOURCES DRM_IOWR(0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETCRTC      DRM_IOWR(0xA1, struct drm_mode_crtc)
#define DRM_IOCTL_MODE_SETCRTC      DRM_IOWR(0xA2, struct drm_mode_crtc)
#define DRM_IOCTL_MODE_GETENCODER   DRM_IOWR(0xA6, struct drm_mode_get_encoder)
#define DRM_IOCTL_MODE_GETCONNECTOR DRM_IOWR(0xA7, struct drm_mode_get_connector)
#define DRM_IOCTL_MODE_ADDFB        DRM_IOWR(0xAE, struct drm_mode_fb_cmd)
#define DRM_IOCTL_MODE_RMFB         DRM_IOWR(0xAF, unsigned int)
#define DRM_IOCTL_MODE_PAGE_FLIP    DRM_IOWR(0xB0, struct drm_mode_crtc_page_flip)
#define DRM_IOCTL_MODE_CREATE_DUMB  DRM_IOWR(0xB2, struct drm_mode_create_dumb)
#define DRM_IOCTL_MODE_MAP_DUMB     DRM_IOWR(0xB3, struct drm_mode_map_dumb)
#define DRM_IOCTL_MODE_DESTROY_DUMB DRM_IOWR(0xB4, struct drm_mode_create_dumb)

#endif /* MU300_DRM_MIN_H */

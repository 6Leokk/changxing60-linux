// SPDX-License-Identifier: GPL-2.0
/*
 * No-op stand-in for the apsys DVFS notifier that the ZTE DRM driver votes through.
 *
 * The F50 config this kernel is built from has CONFIG_DVFS_APSYS_SPRD=m, so
 * include/linux/apsys_dvfs.h declares dpu_dvfs_notifier_call_chain() extern (not the stub
 * branch it has for CONFIG=n) and dpu_r4p0/r5p0/r6p0.c link against it. The device does not
 * run the apsys DVFS subsystem at all -- apsys-dvfs.ko is absent from the module set the rootfs
 * boots with -- and with no DPU notifier ever registered the real function is merely
 * atomic_notifier_call_chain() over an empty chain, i.e. NOTIFY_DONE.
 *
 * Defining that same no-op inside sprd-drm matches the CONFIG=n branch upstream compiles
 * ("return 0") and keeps the panel from having to drag a voltage-voting subsystem in beside the
 * display power domain. The one call site is a fire-and-forget DPU clock vote whose return value
 * is discarded, so dropping the vote costs nothing: the DPU then just runs at whatever rate the
 * clock framework hands it.
 *
 * Deliberately NOT exported. It only has to satisfy this module's own reference, and leaving it
 * unexported means a later apsys-dvfs.ko cannot collide with it, nor does sprd-drm.ko put a
 * vendor symbol into the global namespace that another module might bind to by accident.
 */
#include <linux/kernel.h>

int dpu_dvfs_notifier_call_chain(void *data)
{
	(void)data;

	return 0;
}

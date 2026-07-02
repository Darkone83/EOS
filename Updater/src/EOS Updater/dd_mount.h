/*---------------------------------------------------------------------------
    dd_mount.h -- mount the Xbox HDD partitions to drive letters.

    The kernel only auto-mounts D: (the running title's directory). Anything
    that touches C/E/F/G/X/Y/Z must symlink the letter to its partition device
    first. Call Mount_HddPartitions() once at boot before scanning drives.
    Idempotent -- safe to call again (already-mounted just returns an error
    code we ignore).
---------------------------------------------------------------------------*/
#ifndef DD_MOUNT_H
#define DD_MOUNT_H

void Mount_HddPartitions(void);

/* Re-point D: at the folder this XBE actually launched from (derived from the
   kernel's XeImageFileName). The kernel usually auto-maps D: to the running
   title's directory, but when DarkDash is booted as the *dashboard* (e.g. by
   Cerbios) that mapping can be absent or point elsewhere -- so all the "D:\..."
   asset paths resolve to nothing. Calling this first makes D: correct
   regardless of how we were launched. Returns 1 on success, 0 on failure
   (caller can then fall back to assuming the kernel's D:). */
int Mount_SelfToD(void);

/* Launch the XBE at a DOS path ("E:\Apps\Foo\default.xbe"). Remaps D: to the
   target partition then XLaunchNewImage()s it. Does not return on success;
   returns non-zero on failure. */
int Mount_LaunchXbe(const char* dosPath);

#endif /* DD_MOUNT_H */
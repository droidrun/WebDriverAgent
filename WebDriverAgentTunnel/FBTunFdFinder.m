/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * The utun descriptor scan is adapted from Tun2SocksKit (MIT License,
 * Copyright (c) 2023 Ebrahim Tahernejad,
 * https://github.com/EbrahimTahernejad/Tun2SocksKit).
 */

#import "FBTunFdFinder.h"

#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// From <sys/kern_control.h>, which is not part of the iOS SDK.
#define FB_CTLIOCGINFO 0xc0644e03UL

struct fb_ctl_info {
  uint32_t ctl_id;
  char ctl_name[96];
};

struct fb_sockaddr_ctl {
  unsigned char sc_len;
  unsigned char sc_family;
  uint16_t ss_sysaddr;
  uint32_t sc_id;
  uint32_t sc_unit;
  uint32_t sc_reserved[5];
};

int FBTunnelFindTunFd(void)
{
  struct fb_ctl_info ctlInfo;
  memset(&ctlInfo, 0, sizeof(ctlInfo));
  strlcpy(ctlInfo.ctl_name, "com.apple.net.utun_control", sizeof(ctlInfo.ctl_name));
  for (int fd = 0; fd <= 1024; fd++) {
    struct fb_sockaddr_ctl addr;
    memset(&addr, 0, sizeof(addr));
    socklen_t len = sizeof(addr);
    if (0 != getpeername(fd, (struct sockaddr *)&addr, &len) || AF_SYSTEM != addr.sc_family) {
      continue;
    }
    if (0 == ctlInfo.ctl_id) {
      if (0 != ioctl(fd, FB_CTLIOCGINFO, &ctlInfo)) {
        continue;
      }
    }
    if (addr.sc_id == ctlInfo.ctl_id) {
      return fd;
    }
  }
  return -1;
}

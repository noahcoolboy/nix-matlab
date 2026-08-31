{ pkgs }:

with pkgs; [
  # Core C runtime & System libraries
  glibc
  gcc.cc.lib
  zlib
  glib
  dbus
  pam
  procps
  udev
  libselinux
  libcap
  libxcrypt
  libnsl
  libtirpc
  util-linux

  # Audio & Media
  alsa-lib
  libpulseaudio
  libsndfile
  gst_all_1.gstreamer
  gst_all_1.gst-plugins-base

  # X11 & Graphics
  libGL
  libGLU
  libglvnd
  libdrm
  mesa
  pixman
  cairo
  pango
  fontconfig
  freetype
  fribidi
  libxkbcommon

  # X11 Core & Extensions
  libice
  libsm
  libx11
  libxext
  libxt
  libxtst
  libxrender
  libxrandr
  libxcursor
  libxfixes
  libxcomposite
  libxdamage
  libxi
  libxinerama
  libxxf86vm
  libxft
  libxfont_2

  # XCB libraries
  libxcb
  libxcb-util
  libxcb-image
  libxcb-keysyms
  libxcb-render-util
  libxcb-wm

  # GTK / CEF (MATLABWindow / Chromium Embedded Framework)
  gtk3
  gtk2
  gdk-pixbuf
  atk
  at-spi2-core
  cups
  nss
  nspr
  expat
]

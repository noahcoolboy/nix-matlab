{ pkgs }:

with pkgs; [
  # Core C runtime & System libraries
  glibc
  gcc.cc.lib
  gfortran.cc.lib
  zlib
  zstd
  glib
  dbus
  pam
  procps
  udev
  libselinux
  libcap
  libxcrypt
  libxcrypt-legacy
  libnsl
  libtirpc
  libunwind
  util-linux
  ncurses
  openssl
  curl
  libxml2
  libxslt

  # Audio & Media
  alsa-lib
  libpulseaudio
  libsndfile
  ffmpeg
  gst_all_1.gstreamer
  gst_all_1.gst-plugins-base

  # X11 & Graphics
  libGL
  libGLU
  libdrm
  mesa
  libgbm
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
  at-spi2-core
  cups
  nss
  nspr
  expat
]

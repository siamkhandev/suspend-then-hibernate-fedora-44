Name:           sk-slumber
Version:        0.1.0
Release:        1%{?dist}
Summary:        Sleep and hibernate manager with suspend-then-hibernate for Fedora

# TODO: the project has no LICENSE file yet. Pick a license, add it to the
# repository and put its SPDX identifier here before publishing.
License:        TODO-choose-a-license
URL:            https://github.com/siamkhandev/suspend-then-hibernate-fedora-44
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
BuildRequires:  bash
BuildRequires:  python3
BuildRequires:  desktop-file-utils
BuildRequires:  appstream

# The app
Requires:       python3-gobject
# Python imports these through GObject Introspection typelibs, which Fedora
# does not expose as provides, so depend on the packages that ship them.
Requires:       gtk4
Requires:       libadwaita
Requires:       polkit
# slumber-setup: swapfile, resume offset, boot configuration
Requires:       btrfs-progs
Requires:       grubby
Requires:       dracut
Requires:       util-linux
Requires:       systemd
# helpers: lock-sleep, sleep-notify, sleep-report, usb-wake-guard
Requires:       /usr/bin/gdbus
Requires:       /usr/bin/notify-send
Requires:       procps-ng
Requires:       gawk
Recommends:     gnome-shell

%description
Slumber gives a Fedora laptop Windows-style sleep. It suspends instantly when
the lid is closed, then after a delay you choose it wakes briefly, saves
everything to an encrypted swapfile and powers off completely, so a laptop left
asleep overnight does not drain its battery.

It includes a GTK app that shows the hibernation status, battery use per sleep
and lets you turn suspend-then-hibernate on or off (with administrator
approval), a Keep Awake control for long-running tasks, a Hibernate now button,
and a GNOME Quick Settings tile.

Nothing is changed on the system until you enable it from the app or with
"sudo slumber-setup enable". It requires Fedora with an encrypted Btrfs root
and Secure Boot disabled.

%prep
%autosetup -n %{name}-%{version}

%build
# nothing to build

%check
make check

%install
%make_install PREFIX=%{_prefix}

%preun
if [ $1 -eq 0 ] && [ -f /etc/slumber/slumber.conf ]; then
    echo "Slumber's system changes (swapfile, boot settings, sleep policy) are still in place."
    echo "To undo them, run 'sudo slumber-setup disable'. Without the package that command is gone,"
    echo "so reinstall sk-slumber first if you want it."
fi
:

%files
%{_bindir}/slumber
%{_bindir}/slumber-ctl
%{_bindir}/slumber-setup
%{_bindir}/slumber-status
%{_bindir}/lock-sleep
%{_bindir}/sleep-notify
%{_bindir}/sleep-report
%{_bindir}/usb-wake-guard
%{_prefix}/lib/systemd/system/usb-wake-guard.service
%{_prefix}/lib/systemd/user/lock-sleep.service
%{_prefix}/lib/systemd/user/sleep-notify.service
%{_prefix}/lib/systemd/system-sleep/sleep-battery
%{_datadir}/applications/io.github.siamkhandev.Slumber.desktop
%{_datadir}/metainfo/io.github.siamkhandev.Slumber.metainfo.xml
%{_datadir}/icons/hicolor/scalable/apps/io.github.siamkhandev.Slumber.svg
%{_datadir}/polkit-1/actions/io.github.siamkhandev.slumber.policy
%{_datadir}/gnome-shell/extensions/slumber@sk/

%changelog
* Sat Oct 03 2026 Muhammad Siam <siamkhanb.work@gmail.com> - 0.1.0-1
- Initial package

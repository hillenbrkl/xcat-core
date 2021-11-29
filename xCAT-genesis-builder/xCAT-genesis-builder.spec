BuildArch: noarch
%define name	xCAT-genesis-builder
Version: %{?version:%{version}}%{!?version:%(cat Version)}
Release: %{?release:%{release}}%{!?release:%(cat Release)}
Epoch: 1
AutoReq: false
Requires: ipmitool screen lldpad rpm-build mstflint xfsprogs nc rpmdevtools libstdc++-devel pciutils bridge-utils iprutils psmisc mdadm bind-utils dosfstools usbutils libusbx bc rpmdevtools rng-tools
Prefix: /opt/xcat
AutoProv: false



Name:	 %{name}
Group: System/Utilities
License: EPL
Vendor: IBM Corp.
Summary: Tooling to create xCAT's discovery/maintenance/debugging environment
URL:	 https://xcat.org/
Source: xCAT-genesis-builder.tar.bz2

Buildroot: %{_localstatedir}/tmp/xCAT-genesis-builder
Packager: IBM Corp.

%Description
Genesis (Genesis Enhanced Netboot Environment for System Information and Servicing) is xCAT's netboot environment designed to perform hardware and firmware inventory, perform firmware updates/configuration, and perform troubleshooting.
%Prep
%setup -n xCAT-genesis-builder -c


%Build

%Install
rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/genesis/builder
cd $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/genesis/builder
tar jxf %{SOURCE0}
echo %{version}
sed -i s/%%%%REPLACE_CURRENT_VERSION%%%%/%{version}/g xCAT-genesis-base.spec

chmod +x $RPM_BUILD_ROOT/%{prefix}/share/xcat/netboot/genesis/builder/buildrpm
cd -


%Files
%defattr(-,root,root)
%doc LICENSE.html
%dir %{prefix}
%dir %{prefix}/share
%dir %{prefix}/share/xcat
%dir %{prefix}/share/xcat/netboot
%dir %{prefix}/share/xcat/netboot/genesis
%dir %{prefix}/share/xcat/netboot/genesis/builder
%{prefix}/share/xcat/netboot/genesis/builder/*

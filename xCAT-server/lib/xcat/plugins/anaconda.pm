# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::anaconda;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use Storable qw(dclone);
use Sys::Syslog;
use Thread qw(yield);
use POSIX qw(WNOHANG nice);
use xCAT::Table;
use xCAT::Utils;
use xCAT::NetworkUtils;
use xCAT::MsgUtils;
use xCAT::SvrUtils;
#use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;
use File::Temp qw/mkdtemp/;
use File::Find;
use File::Basename;

use Socket;

use strict;
my @cpiopid;
my $httpmethod="http";
my $httpport="80";



sub handled_commands
{
    return {
            copycd    => "anaconda",
            mknetboot => "nodetype:os=(centos.*)|(rh.*)|(fedora.*)|(SL.*)",
            mkinstall => "nodetype:os=(esxi4.1)|(esx[34].*)|(centos.*)|(rh.*)|(fedora.*)|(SL.*)",
            mkstatelite => "nodetype:os=(esx[34].*)|(centos.*)|(rh.*)|(fedora.*)|(SL.*)",
	
            };
}

sub preprocess_request
{
    my $req      = shift;
    my $callback = shift;
    return [$req]; #calls are only made from pre-farmed out scenarios
    if ($req->{command}->[0] eq 'copycd')
    {    #don't farm out copycd
        return [$req];
    }

    #my $stab = xCAT::Table->new('site');
    #my $sent;
    #($sent) = $stab->getAttribs({key => 'sharedtftp'}, 'value');
    my @ents = xCAT::Utils->get_site_attribute("sharedtftp");
    my $site_ent = $ents[0];
    unless (  defined($site_ent)
            and ($site_ent =~ /no/i or $site_ent =~ /0/))
    {

        #unless requesting no sharedtftp, don't make hierarchical call
        return [$req];
    }

    my %localnodehash;
    my %dispatchhash;
    my $nrtab = xCAT::Table->new('noderes');
    my $nrents = $nrtab->getNodesAttribs($req->{node},[qw(tftpserver servicenode)]);
    foreach my $node (@{$req->{node}})
    {
        my $nodeserver;
        my $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['tftpserver']);
        if ($tent) { $nodeserver = $tent->{tftpserver} }
        unless ($tent and $tent->{tftpserver})
        {
            $tent = $nrents->{$node}->[0]; #$nrtab->getNodeAttribs($node, ['servicenode']);
            if ($tent) { $nodeserver = $tent->{servicenode} }
        }
        if ($nodeserver)
        {
            $dispatchhash{$nodeserver}->{$node} = 1;
        }
        else
        {
            $localnodehash{$node} = 1;
        }
    }
    my @requests;
    my $reqc = {%$req};
    $reqc->{node} = [keys %localnodehash];
    if (scalar(@{$reqc->{node}})) { push @requests, $reqc }

    foreach my $dtarg (keys %dispatchhash)
    {    #iterate dispatch targets
        my $reqcopy = {%$req};    #deep copy
        $reqcopy->{'_xcatdest'} = $dtarg;
        $reqcopy->{node} = [keys %{$dispatchhash{$dtarg}}];
        push @requests, $reqcopy;
    }
    return \@requests;
}

sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = undef;
    my $arch     = undef;
    my $path     = undef;
    if ($::XCATSITEVALS{"httpmethod"}) { $httpmethod = $::XCATSITEVALS{"httpmethod"}; }
    if ($::XCATSITEVALS{"httpport"}) { $httpport = $::XCATSITEVALS{"httpport"}; }

    if ($request->{command}->[0] eq 'copycd')
    {
        return copycd($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mkinstall')
    {
        return mkinstall($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mknetboot' or 
	$request->{command}->[0] eq 'mkstatelite')
    {
        return mknetboot($request, $callback, $doreq);
    }
}

# Check whether the dracut is supported by this os 
sub using_dracut
{
    my $os = shift;
    if ($os =~ /(rhels|rhel)(\d+)/) {
        if ($2 >= 6) {
          return 1;
        }
    } elsif ($os =~ /fedora(\d+)/) {
        if ($1 >= 12) {
          return 1;
        }
    } elsif ($os =~ /SL(\d+)/) {
        if ($1 >= 6) {
          return 1;
        }
    }

    return 0;
}

sub mknetboot
{
    my $xenstyle=0;
    my $req      = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $statelite = 0;
    if($req->{command}->[0] =~ 'mkstatelite'){
        $statelite = "true";
    }
    my $globaltftpdir  = "/tftpboot";
    my $nodes    = @{$req->{node}};
    my @args     = @{$req->{arg}} if(exists($req->{arg}));
    my @nodes    = @{$req->{node}};
    my $ostab    = xCAT::Table->new('nodetype');
    #my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $osimagetab;
    my %img_hash=();
    my $installroot;
    $installroot = "/install";
    my $xcatdport = "3001";

    #if ($sitetab)
    #{
    #    (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
    my @ents = xCAT::Utils->get_site_attribute("installdir");
    my $site_ent = $ents[0];
    if ( defined($site_ent) )
    {
        $installroot = $site_ent;
    }
    #    ($ref) = $sitetab->getAttribs({key => 'xcatdport'}, 'value');
    @ents = xCAT::Utils->get_site_attribute("xcatdport");
    $site_ent = $ents[0];
    if ( defined($site_ent) )
    {
        $xcatdport = $site_ent;
    }
    #    ($ref) = $sitetab->getAttribs({key => 'tftpdir'}, 'value');
    @ents = xCAT::Utils->get_site_attribute("tftpdir");
    $site_ent = $ents[0];
    if ( defined($site_ent) )
    {
        $globaltftpdir = $site_ent;
    }
    my %donetftp=();
    my %oents = %{$ostab->getNodesAttribs(\@nodes,[qw(os arch profile provmethod)])};
    my $restab = xCAT::Table->new('noderes');
    my $bptab  = xCAT::Table->new('bootparams',-create=>1);
    my $hmtab  = xCAT::Table->new('nodehm');
    my $mactab = xCAT::Table->new('mac');

    my $machash = $mactab->getNodesAttribs(\@nodes, ['interface','mac']);

    my $reshash    = $restab->getNodesAttribs(\@nodes, ['primarynic','tftpserver','tftpdir','xcatmaster','nfsserver','nfsdir', 'installnic']);
    my $hmhash =
          $hmtab->getNodesAttribs(\@nodes,
                                 ['serialport', 'serialspeed', 'serialflow']);
    my $statetab;
    my $stateHash;
    if($statelite){
        $statetab = xCAT::Table->new('statelite',-create=>1);
        $stateHash = $statetab->getNodesAttribs(\@nodes, ['statemnt']);
    }
    #my $addkcmdhash =
    #    $bptab->getNodesAttribs(\@nodes, ['addkcmdline']);
    foreach my $node (@nodes)
    {
        my $osver;
        my $arch;
        my $profile;
        my $platform;
        my $rootimgdir;
        my $nodebootif; # nodebootif will be used if noderes.installnic is not set
        my $dump; # for kdump, its format is "nfs://<nfs_server_ip>/<kdump_path>"
        my $crashkernelsize;
        my $rootfstype; 
        my $tftpdir;
        if ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{tftpdir}) {
		$tftpdir = $reshash->{$node}->[0]->{tftpdir};
        } else {
		$tftpdir = $globaltftpdir;
        }
           

        my $ent = $oents{$node}->[0]; #ostab->getNodeAttribs($node, ['os', 'arch', 'profile']);
        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	        my $imagename=$ent->{provmethod};
	        #print "imagename=$imagename\n";
	        if (!exists($img_hash{$imagename})) {
        	    if (!$osimagetab) {
        	        $osimagetab=xCAT::Table->new('osimage', -create=>1);
        	    }
        	    (my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'provmethod', 'rootfstype');
        	    if ($ref) {
                    $img_hash{$imagename}->{osver}=$ref->{'osvers'};
                    $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
                    $img_hash{$imagename}->{profile}=$ref->{'profile'};
                    $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
                    $img_hash{$imagename}->{rootfstype} = $ref->{rootfstype};
                    if (!$linuximagetab) {
                	    $linuximagetab=xCAT::Table->new('linuximage', -create=>1);
                    }
                    (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'rootimgdir', 'nodebootif', 'dump', 'crashkernelsize'); 
                    if (($ref1) && ($ref1->{'rootimgdir'})) {
                	    $img_hash{$imagename}->{rootimgdir}=$ref1->{'rootimgdir'};
                    }
                    if (($ref1) && ($ref1->{'nodebootif'})) {
                        $img_hash{$imagename}->{nodebootif} = $ref1->{'nodebootif'};
                    }
                    if ( $ref1 ) {
                        if ($ref1->{'dump'}) {
                            $img_hash{$imagename}->{dump} = $ref1->{'dump'};
                        }
                    }
                    if (($ref1) && ($ref1->{'crashkernelsize'})) {
                        $img_hash{$imagename}->{crashkernelsize} = $ref1->{'crashkernelsize'};
                    }
                } else {
                    $callback->(
                        {error     => ["The os image $imagename does not exists on the osimage table for $node"],
                        errorcode => [1]});
                    next;
                }
            }
	        my $ph=$img_hash{$imagename};
            
	        $osver = $ph->{osver};
	        $arch  = $ph->{osarch};
	        $profile = $ph->{profile};

            $rootfstype = $ph->{rootfstype};

	        $rootimgdir=$ph->{rootimgdir};
            unless ($rootimgdir) {
                $rootimgdir="$installroot/netboot/$osver/$arch/$profile";
            }
            
            $nodebootif = $ph->{nodebootif};
            $crashkernelsize = $ph->{crashkernelsize};
            $dump = $ph->{dump};
	    }
        else {
            $osver = $ent->{os};
            $arch    = $ent->{arch};
            $profile = $ent->{profile};
            $rootimgdir="$installroot/netboot/$osver/$arch/$profile";
            
            $rootfstype = "nfs"; # TODO: try to get it from the option or table
            my $imgname;
            if ($statelite) {
                $imgname = "$osver-$arch-statelite-$profile";
            } else {
                $imgname = "$osver-$arch-netboot-$profile";
            }


            if (! $osimagetab) {
                $osimagetab = xCAT::Table->new('osimage');
            }

            if ($osimagetab) {
                my ($ref1) = $osimagetab->getAttribs({imagename => $imgname}, 'rootfstype');
                if (($ref1) && ($ref1->{'rootfstype'})) {
                    $rootfstype = $ref1->{'rootfstype'};
                }
            } else {
                $callback->(
                    { error => [ qq{Cannot find the linux image called "$osver-$arch-$imgname-$profile", maybe you need to use the "nodeset <nr> osimage=<osimage name>" command to set the boot state} ],
                    errorcode => [1]}
                );
            }

            if ( ! $linuximagetab ) {
                $linuximagetab = xCAT::Table->new('linuximage');
            }
            if ( $linuximagetab ) {
                (my $ref1) = $linuximagetab->getAttribs({imagename => $imgname}, 'dump', 'crashkernelsize');
                if($ref1 and $ref1->{'dump'})  {
                    $dump = $ref1->{'dump'};
                }
                if($ref1 and $ref1->{'crashkernelsize'})  {
                    $crashkernelsize = $ref1->{'crashkernelsize'};
                }
            } else {
                $callback->(
                    { error => [qq{ Cannot find the linux image called "$osver-$arch-$imgname-$profile", maybe you need to use the "nodeset <nr> osimage=<your_image_name>" command to set the boot state}],
                    errorcode => [1] }
                );
            }
        }
        #print"osvr=$osver, arch=$arch, profile=$profile, imgdir=$rootimgdir\n";
        unless ($osver and $arch and $profile)
        {
            $callback->(
                        {
                         error     => ["Insufficient nodetype entry or osimage entry for $node"],
                         errorcode => [1]
                        }
                        );
            next;
        }

        $platform=xCAT_plugin::anaconda::getplatform($osver);       
        my $suffix  = 'gz';
        $suffix = 'sfs' if (-r "$rootimgdir/rootimg.sfs");
	    # statelite images are not packed.  
        if ($statelite) {
            unless ( -r "$rootimgdir/kernel") {
                $callback->({
                    error=>[qq{Did you run "genimage" before running "liteimg"? kernel cannot be found...}], 
                    errorcode=>[1]
                });
                next;
            }
	        if (!-r "$rootimgdir/initrd-statelite.gz") {
                if (! -r "$rootimgdir/initrd.gz") {
                    $callback->({
                        error=>[qq{Did you run "genimage" before running "liteimg"? initrd.gz or initrd-statelite.gz cannot be found}],
                        errorcode=>[1]
				    });
                    next;
                }
		        else {
		            copy("$rootimgdir/initrd.gz", "$rootimgdir/initrd-statelite.gz");
                }
	        } 
            if ( $rootfstype eq "ramdisk" and ! -r "$rootimgdir/rootimg-statelite.gz") {
                $callback->({
                    error=>[qq{No packed image for platform $osver, architecture $arch and profile $profile, please run "liteimg" to create it.}],
                    errorcode => [1]
                });
                next;
            }
        } else {
            unless ( -r "$rootimgdir/kernel") {
                $callback->({
                    error=>[qq{Did you run "genimage" before running "packimage"? kernel cannot be found}],
                    errorcode=>[1]
			    });
                next;
	        }
	        if (!-r "$rootimgdir/initrd-stateless.gz") {
                if (! -r "$rootimgdir/initrd.gz") {
                    $callback->({
                        error=>[qq{Did you run "genimage" before running "packimage"? initrd.gz or initrd-stateless.gz cannot be found}],
                        errorcode=>[1]
				    });
                    next;
                }
		        else {
		            copy("$rootimgdir/initrd.gz", "$rootimgdir/initrd-stateless.gz");
                }
            }
	        unless ( -r "$rootimgdir/rootimg.gz" or -r "$rootimgdir/rootimg.sfs" ) {
                $callback->({
                    error=>["No packed image for platform $osver, architecture $arch, and profile $profile, please run packimage (e.g.  packimage -o $osver -p $profile -a $arch"],
                    errorcode => [1]});
                next;
            }
        }

        # create the node-specific post scripts
        #mkpath "/install/postscripts/";
        #xCAT::Postage->writescript($node,"/install/postscripts/".$node, "netboot", $callback);

        mkpath("/$tftpdir/xcat/netboot/$osver/$arch/$profile/");

        #TODO: only copy if newer...
        unless ($donetftp{$osver,$arch,$profile}) {
	        if (-f "$rootimgdir/hypervisor") {
        	    copy("$rootimgdir/hypervisor", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
		        $xenstyle=1;
	        }
            copy("$rootimgdir/kernel", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            if ($statelite) {
                if($rootfstype eq "ramdisk") {
                    copy("$rootimgdir/initrd-stateless.gz", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
                } else {
                    copy("$rootimgdir/initrd-statelite.gz", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
                }
            } else {
                copy("$rootimgdir/initrd-stateless.gz", "/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
            }
            $donetftp{$osver,$arch,$profile} = 1;
        }

        if ($statelite) {
            my $initrdloc = "/$tftpdir/xcat/netboot/$osver/$arch/$profile/";
            if ($rootfstype eq "ramdisk") {
                $initrdloc .= "initrd-stateless.gz";
            } else {
                $initrdloc .= "initrd-statelite.gz";
            }
            unless ( -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel"
                    and -r $initrdloc ) {
                $callback->({
                    error=>[qq{copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed}],
                    errorcode=>[1]
                });
                next;
            }
        } else {
            unless ( -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel"
                    and -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/initrd-stateless.gz") {
                $callback->({
                    error=>[qq{copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed}],
                    errorcode=>[1]
                });
                next;
            }
        }

        $ent    = $reshash->{$node}->[0];#$restab->getNodeAttribs($node, ['primarynic']);
        my $sent   = $hmhash->{$node}->[0];
#          $hmtab->getNodeAttribs($node,
#                                 ['serialport', 'serialspeed', 'serialflow']);

        # determine image server, if tftpserver use it, else use xcatmaster
        # last resort use self
        my $imgsrv;
        my $ient;
        my $xcatmaster;

        $ient = $reshash->{$node}->[0]; #$restab->getNodeAttribs($node, ['tftpserver']);

        if ($ient and $ient->{xcatmaster})
        {
            $xcatmaster = $ient->{xcatmaster};
        } else {
            $xcatmaster = '!myipfn!'; #allow service nodes to dynamically nominate themselves as a good contact point, this is of limited use in the event that xcat is not the dhcp/tftp server
        }

        if ($ient and $ient->{tftpserver})
        {
            $imgsrv = $ient->{tftpserver};
        }
        else
        {
            $ient = $reshash->{$node}->[0]; #$restab->getNodeAttribs($node, ['xcatmaster']);
            #if ($ient and $ient->{xcatmaster})
            #{
            #    $imgsrv = $ient->{xcatmaster};
            #}
            #else
            #{
                # master not correct for service node pools
                #$ient = $sitetab->getAttribs({key => master}, value);
                #if ($ient and $ient->{value})
                #{
                #    $imgsrv = $ient->{value};
                #}
                #else
                #{
            #   $imgsrv = '!myipfn!';
                #}
            #}
            $imgsrv = $xcatmaster;
        }
        unless ($imgsrv)
        {
            $callback->(
                {
                 error => [
                     "Unable to determine or reasonably guess the image server for $node"
                 ],
                 errorcode => [1]
                }
                );
            next;
        }
        my $kcmdline; # add two more arguments: XCAT=xcatmaster:xcatport and ifname=<eth0>:<mac address>
	    if($statelite){
            if ($rootfstype ne "ramdisk") {
		        # get entry for nfs root if it exists:
		        # have to get nfssvr and nfsdir from noderes table
		        my $nfssrv = $imgsrv;
		        my $nfsdir = $rootimgdir;
		        if($ient->{nfsserver} ){
			        $nfssrv = $ient->{nfsserver};
		        }
		        if($ient->{nfsdir} ne ''){	
			        $nfsdir = $ient->{nfsdir} . "/netboot/$osver/$arch/$profile";
                        #this code sez, "if nfsdir starts with //, then
                        #use a absolute path, i.e. do not append xCATisms"
                        #this is required for some statelite envs.
                        #still open for debate.

			        if($ient->{nfsdir} =~ m!^//!) {
				        $nfsdir = $ient->{nfsdir};
				        $nfsdir =~ s!^/!!;
			        }
		        }

                # special case for redhat6, fedora12/13/14
                if (&using_dracut($osver)) {
                    $kcmdline = "root=nfs:$nfssrv:$nfsdir/rootimg:ro STATEMNT=";
                } else {
                    $kcmdline = "NFSROOT=$nfssrv:$nfsdir STATEMNT=";	
                }
            } else {
                $kcmdline =  "imgurl=$httpmethod://$imgsrv:$httpport/$rootimgdir/rootimg-statelite.gz STATEMNT=";
            }

            # add support for subVars in the value of "statemnt"
            my $statemnt = "";
		    if (exists($stateHash->{$node})) {
                $statemnt = $stateHash->{$node}->[0]->{statemnt};
                if (grep /\$/, $statemnt) {
                    my ($server, $dir) = split(/:/, $statemnt);
                
                    #if server is blank, then its the directory
                    unless($dir) {
                        $dir = $server;
                        $server = '';
                    }
                    if(grep /\$|#CMD/, $dir) {
                        $dir = xCAT::SvrUtils->subVars($dir, $node, 'dir', $callback);
                        $dir =~ s/\/\//\//g;
                    }
                    if($server) { 
                        $server = xCAT::SvrUtils->subVars($server, $node, 'server', $callback);
                    }
                    $statemnt = $server . ":" . $dir;
                }
		    }
		    $kcmdline .= $statemnt ." ";
                    my $xcatmasterip;
                    # if xcatmaster is hostname, convert it to ip address
                    if (xCAT::Utils->validate_ip($xcatmaster)) {
                        # Using XCAT=<hostname> will cause problems rc.statelite.ppc.redhat
                        # when trying to run chroot command
                        $xcatmasterip = xCAT::NetworkUtils->getipaddr($xcatmaster);
                        if (!$xcatmasterip)
                        {
                            $xcatmasterip = $xcatmaster;
                        }
                    } else {
                        $xcatmasterip = $xcatmaster;
                    }
		    $kcmdline .=
			    "XCAT=$xcatmasterip:$xcatdport ";
            if ($rootfstype ne "ramdisk") {
                # BEGIN service node
                my $isSV = xCAT::Utils->isServiceNode();
                my $res = xCAT::Utils->runcmd("hostname", 0);
                my $sip = xCAT::NetworkUtils->getipaddr($res);  # this is the IP of service node
                if($isSV and (($xcatmaster eq $sip) or ($xcatmaster eq $res))) {
                    # if the NFS directory in litetree is on the service node,
                    # and it is not exported, then it will be mounted automatically
                    xCAT::SvrUtils->setupNFSTree($node, $sip, $callback);
                    # then, export the statemnt directory if it is on the service node
                    if($statemnt) {
                        xCAT::SvrUtils->setupStatemnt($sip, $statemnt, $callback);
                    }
                }
                # END service node
            }
	    }
        else {
            $kcmdline =
              "imgurl=$httpmethod://$imgsrv:$httpport/$rootimgdir/rootimg.$suffix ";
            $kcmdline .= "XCAT=$xcatmaster:$xcatdport ";
        }

        # add one parameter: ifname=<eth0>:<mac address>
        # which is used for dracut
        # the redhat5.x os will ignore it
        my $useifname=0;

        if ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{installnic} and $reshash->{$node}->[0]->{installnic} ne "mac") {
            $useifname=1;
            $kcmdline .= "ifname=".$reshash->{$node}->[0]->{installnic} . ":";
        } elsif ($nodebootif) {
            $useifname=1;
            $kcmdline .= "ifname=$nodebootif:";
        } elsif ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{primarynic} and $reshash->{$node}->[0]->{primarynic} ne "mac") {
            $useifname=1;
            $kcmdline .= "ifname=".$reshash->{$node}->[0]->{primarynic}.":";
        }
        #else { #no, we autodetect and don't presume anything
        #    $kcmdline .="eth0:";
        #    print "eth0 is used as the default booting network devices...\n";
        #}
        # append the mac address
        my $mac;
        if( $machash->{$node}->[0] && $machash->{$node}->[0]->{'mac'}) {
            # TODO: currently, only "mac" attribute with classic style is used, the "|" delimited string of "macaddress!hostname" format is not used
            $mac = $machash->{$node}->[0]->{'mac'};
#            if ( (index($mac, "|") eq -1) and (index($mac, "!") eq -1) ) {
               #convert to linux format
                if ($mac !~ /:/) {
                   $mac =~s/(..)(..)(..)(..)(..)(..)/$1:$2:$3:$4:$5:$6/;
                }
#            } else {
#                $callback->({ error=>[ qq{In the "mac" table, the "|" delimited string of "macaddress!hostname" format is not supported by "nodeset <nr> netboot|statelite if installnic/primarynic is set".}], errorcode=>[1]});
#                return;
#            }
        }

        if ($useifname && $mac) {
            $kcmdline .= "$mac ";
        }

        # add "netdev=<eth0>" or "BOOTIF=<mac>" 
        # which are used for other scenarios
        my $netdev = "";
        if ($reshash->{$node}->[0] and $reshash->{$node}->[0]->{installnic} and $reshash->{$node}->[0]->{installnic} ne "mac") {
            $kcmdline .= "netdev=" . $reshash->{$node}->[0]->{installnic} . " ";
        } elsif ($nodebootif) {
            $kcmdline .= "netdev=" . $nodebootif . " ";
        } elsif ( $reshash->{$node}->[0] and $reshash->{$node}->[0]->{primarynic} and $reshash->{$node}->[0]->{primarynic} ne "mac") {
            $kcmdline .= "netdev=" . $reshash->{$node}->[0]->{primarynic} . " ";
        } else {
            if ( !$useifname && $mac) {
                $kcmdline .= "BOOTIF=" . $mac . " ";
            }
        }

        my %client_nethash = xCAT::DBobjUtils->getNetwkInfo( [$node] );
        if ( $client_nethash{$node}{mgtifname} =~ /hf/ )
        {
            $kcmdline .= "rdloaddriver=hf_if ";
        }

        
        if (defined $sent->{serialport})
        {

            #my $sent = $hmtab->getNodeAttribs($node,['serialspeed','serialflow']);
            unless ($sent->{serialspeed})
            {
                $callback->(
                    {
                     error => [
                         "serialport defined, but no serialspeed for $node in nodehm table"
                     ],
                     errorcode => [1]
                    }
                    );
                next;
            }
            $kcmdline .=
              " console=tty0 console=ttyS" . $sent->{serialport} . "," . $sent->{serialspeed};
            if ($sent->{serialflow} =~ /(hard|tcs|ctsrts)/)
            {
                $kcmdline .= "n8r";
            }
        }

        # turn off the selinux
        if ($osver =~ m/fedora12/ || $osver =~ m/fedora13/) {
            $kcmdline .= " selinux=0 ";
        }

        # if kdump service is enbaled, add "crashkernel=" and "kdtarget="
        if ($dump) {
            my $fadumpFlag = 0;
            my $fadump = '';
            my $kdump = '';
            if ($dump =~ /^fadump.*/){
                $dump =~ s/fadump://g;
                $fadumpFlag = 1;
                $fadump = $dump;
                $kdump = $dump;
                if ($dump =~ /^nfs:\/\/\/.*/){
                    $fadump =~ s/(nfs:\/\/)(\/.*)/net,${xcatmaster}:${2}/;
                    $kdump =~ s/(nfs:\/\/)(\/.*)/${1}${xcatmaster}${2}/;
                }
            }
            if ($crashkernelsize){
                if ($fadumpFlag && $arch eq "ppc64"){
                    $kcmdline .= " fadump=on fadump_reserve_mem=$crashkernelsize fadump_target=$fadump fadump_default=noreboot dump=$kdump ";
                }
                else{
                    $kcmdline .= " crashkernel=$crashkernelsize dump=$dump ";
                }
            }
            else{
                if ($arch eq "ppc64"){
                    if ($fadumpFlag){
                        $kcmdline .= " fadump=on fadump_reserve_mem=512M fadump_target=$fadump fadump_default=noreboot dump=$kdump ";
                    }
                    else{
                        $kcmdline .= " crashkernel=256M\@64M dump=$dump ";
                    }
                }
                if ($arch =~ /86/){
                    $kcmdline .= " crashkernel=128M dump=$dump ";
                }
            }
        }

        # add the addkcmdline attribute  to the end
        # of the command, if it exists
        #my $addkcmd   = $addkcmdhash->{$node}->[0];
        # add the extra addkcmd command info, if in the table
        #if ($addkcmd->{'addkcmdline'}) {
        #        $kcmdline .= " ";
        #        $kcmdline .= $addkcmd->{'addkcmdline'};
           
        #}
        
	    my $kernstr="xcat/netboot/$osver/$arch/$profile/kernel";
	    if ($xenstyle) {
	        $kernstr.= "!xcat/netboot/$osver/$arch/$profile/hypervisor";
	    }
        my $initrdstr = "xcat/netboot/$osver/$arch/$profile/initrd-stateless.gz";
        $initrdstr = "xcat/netboot/$osver/$arch/$profile/initrd-statelite.gz" if ($statelite);
        # special case for the dracut-enabled OSes
        if (&using_dracut($osver)) {
            if($statelite and $rootfstype eq "ramdisk") {
                $initrdstr = "xcat/netboot/$osver/$arch/$profile/initrd-stateless.gz";
            }
        }

        if($statelite)
        {
            my $statelitetb = xCAT::Table->new('statelite');
            my $mntopts = $statelitetb->getNodeAttribs($node, ['mntopts']);

            my $mntoptions = $mntopts->{'mntopts'};
            unless (defined($mntoptions))
            {
                $kcmdline .= " MNTOPTS=";
            }
            else
            {
                $kcmdline .= " MNTOPTS=$mntoptions";
            }
        }

        $bptab->setNodeAttribs(
            $node,
            {
                kernel => $kernstr,
                initrd => $initrdstr,
                kcmdline => $kcmdline
            }
        );
    }

    #my $rc = xCAT::Utils->create_postscripts_tar();
    #if ( $rc != 0 ) {
    #	xCAT::MsgUtils->message( "S", "Error creating postscripts tar file." );
    #}
}

sub mkinstall
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my @nodes    = @{$request->{node}};
    #my $sitetab  = xCAT::Table->new('site');
    my $linuximagetab;
    my $osimagetab;
    my %img_hash=();

    my $installroot;
    my $globaltftpdir;
    $installroot = "/install";
    $globaltftpdir = "/tftpboot";

    #if ($sitetab)
    #{
    #    (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
    my @ents = xCAT::Utils->get_site_attribute("installdir");
    my $site_ent = $ents[0];
    if( defined($site_ent) )    
    {
        $installroot = $site_ent;
    }
    #( $ref) = $sitetab->getAttribs({key => 'tftpdir'}, 'value');
    @ents = xCAT::Utils->get_site_attribute("tftpdir");
    $site_ent = $ents[0];
    if( defined($site_ent) )    
    {
        $globaltftpdir = $site_ent;
    }
    #}

    my $node;
    my $ostab = xCAT::Table->new('nodetype');
    my %doneimgs;
    my $restab = xCAT::Table->new('noderes');
    my $bptab  = xCAT::Table->new('bootparams',-create=>1);
    my $hmtab  = xCAT::Table->new('nodehm');
    my %osents = %{$ostab->getNodesAttribs(\@nodes, ['profile', 'os', 'arch', 'provmethod'])};
    my %rents =
              %{$restab->getNodesAttribs(\@nodes,
                                     ['xcatmaster', 'nfsserver', 'tftpdir', 'primarynic', 'installnic'])};
    my %hents = 
              %{$hmtab->getNodesAttribs(\@nodes,
                                     ['serialport', 'serialspeed', 'serialflow'])};
    #my $addkcmdhash =
    #    $bptab->getNodesAttribs(\@nodes, ['addkcmdline']);
    require xCAT::Template;
    foreach $node (@nodes)
    {
        my $os;
        my $tftpdir;
        my $arch;
        my $profile;
        my $tmplfile;
        my $pkgdir;
	my $pkglistfile;
	my $imagename;
	my $platform;
        my $xcatmaster;
        my $partfile;
        my $netdrivers;
        my $driverupdatesrc;

        my $ient = $rents{$node}->[0];
        if ($ient and $ient->{xcatmaster})
        {
            $xcatmaster = $ient->{xcatmaster};
        } else {
            $xcatmaster = '!myipfn!';
        }

        my $osinst;
        if ($rents{$node}->[0] and $rents{$node}->[0]->{tftpdir}) {
		$tftpdir = $rents{$node}->[0]->{tftpdir};
        } else {
		$tftpdir = $globaltftpdir;
        }
        my $ent = $osents{$node}->[0]; #$ostab->getNodeAttribs($node, ['profile', 'os', 'arch']);
        if ($ent and $ent->{provmethod} and ($ent->{provmethod} ne 'install') and ($ent->{provmethod} ne 'netboot') and ($ent->{provmethod} ne 'statelite')) {
	    $imagename=$ent->{provmethod};
	    #print "imagename=$imagename\n";
	    if (!exists($img_hash{$imagename})) {
		if (!$osimagetab) {
		    $osimagetab=xCAT::Table->new('osimage', -create=>1);
		}
		(my $ref) = $osimagetab->getAttribs({imagename => $imagename}, 'osvers', 'osarch', 'profile', 'provmethod');
		if ($ref) {
		    $img_hash{$imagename}->{osver}=$ref->{'osvers'};
		    $img_hash{$imagename}->{osarch}=$ref->{'osarch'};
		    $img_hash{$imagename}->{profile}=$ref->{'profile'};
		    $img_hash{$imagename}->{provmethod}=$ref->{'provmethod'};
		    if (!$linuximagetab) {
			$linuximagetab=xCAT::Table->new('linuximage', -create=>1);
		    }
		    (my $ref1) = $linuximagetab->getAttribs({imagename => $imagename}, 'template', 'pkgdir', 'pkglist', 'partitionfile');
		    if ($ref1) {
			if ($ref1->{'template'}) {
			    $img_hash{$imagename}->{template}=$ref1->{'template'};
			}
			if ($ref1->{'pkgdir'}) {
			    $img_hash{$imagename}->{pkgdir}=$ref1->{'pkgdir'};
			}
			if ($ref1->{'pkglist'}) {
			    $img_hash{$imagename}->{pkglist}=$ref1->{'pkglist'};
			}
            if ($ref1->{'partitionfile'}) {
                $img_hash{$imagename}->{partitionfile} = $ref1->{'partitionfile'};
            }
			if ($ref1->{'driverupdatesrc'}) {
			    $img_hash{$imagename}->{driverupdatesrc}=$ref1->{'driverupdatesrc'};
			}
			if ($ref1->{'netdrivers'}) {
			    $img_hash{$imagename}->{netdrivers}=$ref1->{'netdrivers'};
			}
		    }
		    # if the install template wasn't found, then lets look for it in the default locations.
		    unless($img_hash{$imagename}->{template}){
	                my $pltfrm=xCAT_plugin::anaconda::getplatform($ref->{'osvers'});
	    		my $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$installroot/custom/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
	    		if (! $tmplfile) { $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$::XCATROOT/share/xcat/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
					 }
			# if we managed to find it, put it in the hash:
			if($tmplfile){
			    $img_hash{$imagename}->{template}=$tmplfile;
			}
		    }
                    #if the install pkglist wasn't found, then lets look for it in the default locations
		    unless($img_hash{$imagename}->{pkglist}){
	                my $pltfrm=xCAT_plugin::anaconda::getplatform($ref->{'osvers'});
	    		my $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$installroot/custom/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
	    		if (! $pkglistfile) { $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$::XCATROOT/share/xcat/install/$pltfrm", 
		 			$ref->{'profile'}, $ref->{'osvers'}, $ref->{'osarch'}, $ref->{'osvers'});
					 }
			# if we managed to find it, put it in the hash:
			if($pkglistfile){
			    $img_hash{$imagename}->{pkglist}=$pkglistfile;
			}
		    }
		} else {
		    $callback->(
			{error     => ["The os image $imagename does not exists on the osimage table for $node"],
			 errorcode => [1]});
		    next;
		}
	    }
	    my $ph=$img_hash{$imagename};
	    $os = $ph->{osver};
	    $arch  = $ph->{osarch};
	    $profile = $ph->{profile};
        $partfile = $ph->{partitionfile};
	    $platform=xCAT_plugin::anaconda::getplatform($os);
	
	    $tmplfile=$ph->{template};
            $pkgdir=$ph->{pkgdir};
	    if (!$pkgdir) {
		$pkgdir="$installroot/$os/$arch";
	    }
	    $pkglistfile=$ph->{pkglist};

	    $netdrivers = $ph->{netdrivers};
	    $driverupdatesrc = $ph->{driverupdatesrc};
	}
	else {
	    $os = $ent->{os};
	    $arch    = $ent->{arch};
	    $profile = $ent->{profile};
	    $platform=xCAT_plugin::anaconda::getplatform($os);
	    my $genos = $os;
	    $genos =~ s/\..*//;
	    if ($genos =~ /rh.*(\d+)\z/)
	    {
		unless (-r "$installroot/custom/install/$platform/$profile.$genos.$arch.tmpl"
			or -r "/install/custom/install/$platform/$profile.$genos.tmpl"
			or -r "$::XCATROOT/share/xcat/install/$platform/$profile.$genos.$arch.tmpl"
			or -r "$::XCATROOT/share/xcat/install/$platform/$profile.$genos.tmpl")
		{
		    $genos = "rhel$1";
		}
	    }
	    
	    $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$installroot/custom/install/$platform", $profile, $os, $arch, $genos);
	    if (! $tmplfile) { $tmplfile=xCAT::SvrUtils::get_tmpl_file_name("$::XCATROOT/share/xcat/install/$platform", $profile, $os, $arch, $genos); }

	    $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$installroot/custom/install/$platform", $profile, $os, $arch, $genos);
	    if (! $pkglistfile) { $pkglistfile=xCAT::SvrUtils::get_pkglist_file_name("$::XCATROOT/share/xcat/install/$platform", $profile, $os, $arch, $genos); }

	    $pkgdir="$installroot/$os/$arch";
        #get the partition file from the linuximage table
        my $imgname = "$os-$arch-install-$profile";

        if ( ! $linuximagetab ) {
            $linuximagetab = xCAT::Table->new('linuximage');
        }

        if ( $linuximagetab ) {
            (my $ref1) = $linuximagetab->getAttribs({imagename => $imgname}, 'partitionfile');
            if ( $ref1 and $ref1->{'partitionfile'}){
                $partfile = $ref1->{'partitionfile'};
            }
        }
        #can not find the linux osiamge object, tell users to run "nodeset <nr> osimage=***"
        else {
                $callback->(
                     { error => [qq{ Cannot find the linux image called "$imgname", maybe you need to use the "nodeset <nr> osimage=<your_image_name>" command to set the boot state}], errorcode => [1] }
            );
        }
	}

        my @missingparms;
        unless ($os) {
	    if ($imagename) { push @missingparms,"osimage.osvers";  }
            else { push @missingparms,"nodetype.os";}
        }
        unless ($arch) {
	    if ($imagename) { push @missingparms,"osimage.osarch";  }
            else { push @missingparms,"nodetype.arch";}
        }
        unless ($profile) {
	    if ($imagename) { push @missingparms,"osimage.profile";  }
            else { push @missingparms,"nodetype.profile";}
        }
        unless ($os and $arch and $profile)
        {
            $callback->(
                        {
                         error => ["Missing ".join(',',@missingparms)." for $node"],
                         errorcode => [1]
                        }
                        );
            next;    #No profile
        }

        unless ( -r "$tmplfile")  
        {
            $callback->(
                        {
                         error => [
                                   "No $platform kickstart template exists for "
                                     . $profile
                                     . " in directory $installroot/custom/install/$platform or $::XCATROOT/share/xcat/install/$platform"
                         ],
                         errorcode => [1]
                        }
                        );
            next;
        }


        #Call the Template class to do substitution to produce a kickstart file in the autoinst dir
        my $tmperr;
	if ($imagename) {
	    $tmperr="Unable to find template file: $tmplfile";
	} else {
          $tmperr="Unable to find template in /install/custom/install/$platform or $::XCATROOT/share/xcat/install/$platform (for $profile/$os/$arch combination)";
	}
        if (-r "$tmplfile")
        {
            $tmperr =
              xCAT::Template->subvars(
                    $tmplfile,
                    "/$installroot/autoinst/" . $node,
                    $node,
		            $pkglistfile,
                    undef,
                    undef,
                    $partfile
                    );
        }
 
        if ($tmperr)
        {
            $callback->(
                    {
                     node =>
                       [{name => [$node], error => [$tmperr], errorcode => [1]}]
                    }
                    );
            next;
        }
        #my $installdir="/install"; #TODO: not hardcode installdir
        #my $tftpdir = "/tftpboot";

        # create the node-specific post scripts
        #mkpath "/install/postscripts/";
        #xCAT::Postage->writescript($node,"/install/postscripts/".$node, "install", $callback);
        my $kernpath;
        my $initrdpath;
        my $maxmem;
	my $esxi = 0;

        if (
            (
                 $arch =~ /x86/ and 
                    (
                         -r "$pkgdir/images/pxeboot/vmlinuz"
                         and $kernpath = "$pkgdir/images/pxeboot/vmlinuz"
                         and -r "$pkgdir/images/pxeboot/initrd.img"
                         and $initrdpath = "$pkgdir/images/pxeboot/initrd.img"
                    ) or ( #Handle the case seen in VMWare 4.0 ESX media
                        #In VMWare 4.0 they dropped the pxe-optimized initrd
                        #leaving us no recourse but the rather large optical disk
                        #initrd, but perhaps we can mitigate with gPXE
                         -d "$pkgdir/VMware" 
                         and -r "$pkgdir/isolinux/vmlinuz"
                         and $kernpath ="$pkgdir/isolinux/vmlinuz"
                         and -r "$pkgdir/isolinux/initrd.img"
                         and $initrdpath = "$pkgdir/isolinux/initrd.img"
                         and $maxmem="512M" #Have to give up linux room to make room for vmware hypervisor evidently
                    ) or ( #Handle the case seen in VMware ESXi 4.1 media scripted installs.
                         -r "$pkgdir/mboot.c32"
                         and -r "$pkgdir/vmkboot.gz"
                         and -r "$pkgdir/vmkernel.gz"
                         and -r "$pkgdir/sys.vgz"
                         and -r "$pkgdir/cim.vgz"
                         and -r "$pkgdir/ienviron.vgz"
                         and -r "$pkgdir/install.vgz"
                         and $esxi = 'true'

                    )
            ) or (    $arch =~ /ppc/
                and -r "$pkgdir/ppc/ppc64/vmlinuz"
                and $kernpath = "$pkgdir/ppc/ppc64/vmlinuz"
                and ((-r "$pkgdir/ppc/ppc64/ramdisk.image.gz"
                and $initrdpath = "$pkgdir/ppc/ppc64/ramdisk.image.gz")
                or (-r "$pkgdir/ppc/ppc64/initrd.img"
                and $initrdpath = "$pkgdir/ppc/ppc64/initrd.img")))
          )
        {

            #TODO: driver slipstream, targetted for network.
            unless ($doneimgs{"$os|$arch"})
            {
                mkpath("$tftpdir/xcat/$os/$arch");
                if($esxi){
                    copyesxiboot($pkgdir, "$tftpdir/xcat/$os/$arch");		
                }else{
                    my $tftppath;
                    if ($profile) {
                        $tftppath = "/$tftpdir/xcat/$os/$arch/$profile";
                    } else {
                        $tftppath = "/$tftpdir/xcat/$os/$arch";
                    }
                    mkpath ("$tftppath");
                    copy($kernpath,"$tftppath");
                    copy($initrdpath,"$tftppath/initrd.img");
                    &insert_dd($callback, $os, $arch, "$tftppath/initrd.img", $driverupdatesrc, $netdrivers);
                }
                $doneimgs{"$os|$arch"} = 1;
            }

            #We have a shot...
            my $ent    = $rents{$node}->[0];
#              $restab->getNodeAttribs($node,
#                                     ['nfsserver', 'primarynic', 'installnic']);
            my $sent = $hents{$node}->[0];
#              $hmtab->getNodeAttribs(
#                                     $node,
#                                     [
#                                      'serialport', 'serialspeed', 'serialflow'
#                                     ]
#                                     );
            my $instserver = $xcatmaster;
            if ($ent and $ent->{nfsserver}) {
	    	$instserver=$ent->{nfsserver};
	    }
            my $kcmdline =
                "quiet repo=$httpmethod://$instserver:$httpport/install/$os/$arch/ ks=$httpmethod://"
              . $instserver . ":". $httpport
              . "/install/autoinst/"
              . $node;
            if ($maxmem) {
                $kcmdline.=" mem=$maxmem";
            }
            my $ksdev = "";
            if ($ent->{installnic})
            {
                if ($ent->{installnic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $ksdev = $macref->{mac};
                }
                else
                {
                    $ksdev = $ent->{installnic};
                }
            }
            elsif ($ent->{primarynic})
            {
                if ($ent->{primarynic} eq "mac")
                {
                    my $mactab = xCAT::Table->new("mac");
                    my $macref = $mactab->getNodeAttribs($node, ['mac']);
                    $ksdev = $macref->{mac};
                }
                else
                {
                    $ksdev = $ent->{primarynic};
                }
            }
            else
            {
                $ksdev = "bootif"; #if not specified, fall back to bootif
            }
            if ($ksdev eq "")
            {
                $callback->(
                        {
                         error => ["No MAC address defined for " . $node],
                         errorcode => [1]
                        }
                        );
             }
             if($esxi){
                 $ksdev =~ s/eth/vmnic/g;
             }
             $kcmdline .= " ksdevice=" . $ksdev;

            #TODO: dd=<url> for driver disks
            if (defined($sent->{serialport}))
            {
                unless ($sent->{serialspeed})
                {
                    $callback->(
                        {
                         error => [
                             "serialport defined, but no serialspeed for $node in nodehm table"
                         ],
                         errorcode => [1]
                        }
                        );
                    next;
                }
		#go cmdline if serial console is requested, the shiny ansi is just impractical
                $kcmdline .=
                    " cmdline console=tty0 console=ttyS"
                  . $sent->{serialport} . ","
                  . $sent->{serialspeed};
                if ($sent->{serialflow} =~ /(hard|cts|ctsrts)/)
                {
                    $kcmdline .= "n8r";
                }
            }
            #$kcmdline .= " noipv6";
            # add the addkcmdline attribute  to the end
            # of the command, if it exists
            #my $addkcmd   = $addkcmdhash->{$node}->[0];
            # add the extra addkcmd command info, if in the table
            #if ($addkcmd->{'addkcmdline'}) {
            #        $kcmdline .= " ";
            #        $kcmdline .= $addkcmd->{'addkcmdline'};
            #}
            my $k;
            my $i;
            if($esxi){
                $k = "xcat/$os/$arch/mboot.c32";
                $i = "";
                my @addfiles = qw(vmkernel.gz sys.vgz cim.vgz ienviron.vgz install.vgz mod.tgz);
		$kcmdline = "xcat/$os/$arch/vmkboot.gz " . $kcmdline;
                foreach(@addfiles){
                    $kcmdline .= " --- xcat/$os/$arch/$_";
                }
            }else{
                if ($profile) {
                    $k = "xcat/$os/$arch/$profile/vmlinuz";
                    $i = "xcat/$os/$arch/$profile/initrd.img";
                } else {
                    $k = "xcat/$os/$arch/vmlinuz";
                    $i = "xcat/$os/$arch/initrd.img";
                }
            }

            $bptab->setNodeAttribs(
                $node,
                {
                    kernel   => $k,
                    initrd   => $i,
                    kcmdline => $kcmdline
                }
            );
        }
        else
        {
            $callback->(
                    {
                     error => ["Install image not found in $installroot/$os/$arch"],
                     errorcode => [1]
                    }
                    );
        }
    }
    #my $rc = xCAT::Utils->create_postscripts_tar();
    #if ($rc != 0)
    #{
    #    xCAT::MsgUtils->message("S", "Error creating postscripts tar file.");
    #}
}

sub copycd
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $installroot = "/install";
    my $sitetab = xCAT::Table->new('site');
    

    require xCAT::data::discinfo;

    #if ($sitetab)
    #{
    #    (my $ref) = $sitetab->getAttribs({key => 'installdir'}, 'value');
    my @ents = xCAT::Utils->get_site_attribute("installdir");
    my $site_ent = $ents[0];
    if( defined($site_ent) )    
    {
        $installroot = $site_ent;
    }

    my $distname;
    my $arch;
    my $path;
    my $mntpath=undef;
    my $inspection=undef;

    @ARGV = @{$request->{arg}};
    GetOptions(
               'n=s' => \$distname,
               'a=s' => \$arch,
               'p=s' => \$path,
               'm=s' => \$mntpath,
               'i'   => \$inspection
               );
    unless ($mntpath)
    {

        #this plugin needs $mntpath...
        return;
    }
    if (    $distname
        and $distname !~ /^centos/
        and $distname !~ /^fedora/
        and $distname !~ /^SL/
        and $distname !~ /^rh/)
    {

        #If they say to call it something unidentifiable, give up?
        return;
    }
    unless (-r $mntpath . "/.discinfo")
    {
        return;
    }
    my $dinfo;
    open($dinfo, $mntpath . "/.discinfo");
    my $did = <$dinfo>;
    chomp($did);
    my $desc = <$dinfo>;
    chomp($desc);
    my $darch = <$dinfo>;
    chomp($darch);
    my $dno= <$dinfo>;
    chomp($dno);

    if ($darch and $darch =~ /i.86/)
    {
        $darch = "x86";
    }
    close($dinfo);
    if ($xCAT::data::discinfo::distnames{$did})
    {
        unless ($distname)
        {
            $distname =$xCAT::data::discinfo::distnames{$did};
        }
    }
    elsif ($desc =~ /^Final$/)
    {
        unless ($distname)
        {
            $distname = "centos5";
        }
    }
    elsif ($desc =~ /^Fedora 8$/)
    {
        unless ($distname)
        {
            $distname = "fedora8";
        }
    }
    elsif ($desc =~ /^CentOS-4 .*/)
    {
        unless ($distname)
        {
            $distname = "centos4";
        }
    }
    elsif ($desc =~ /^Red Hat Enterprise Linux Client 5$/)
    {
        unless ($distname)
        {
            $distname = "rhelc5";
        }
    }
    elsif ($desc =~ /^Red Hat Enterprise Linux Server 5$/)
    {
        unless ($distname)
        {
            $distname = "rhels5";
        }
    }
    elsif ($desc =~ /^LTS$/)
    {
        unless ($distname)
        {
            $distname = "SL5";
        }
    }


    unless ($distname)
    {
        return;    #Do nothing, not ours..
    }
    if ($darch)
    {
        unless ($arch)
        {
            $arch = $darch;
        }
        if ($arch and $arch ne $darch)
        {
            $callback->(
                {
                 error =>
                   "Requested distribution architecture $arch, but media is $darch"
                }
                );
            return;
        }
        if ($arch =~ /ppc/) { $arch = "ppc64" }
    }

    if($inspection)
    {
            $callback->(
                {
                 info =>
                   "DISTNAME:$distname\n"."ARCH:$arch\n"."DISCNO:$dno\n"
                }
                );
            return;
    }


    %{$request} = ();    #clear request we've got it.

    my $defaultpath="$installroot/$distname/$arch";
    unless($path)
    {
        $path=$defaultpath;
    }

    $callback->({data => "Copying media to $path"});
    my $omask = umask 0022;
    if(-l $path)
    {
        unlink($path);
    }
    mkpath("$path");    
    umask $omask;

    my $rc;
    my $reaped = 0;
    $SIG{INT} = $SIG{TERM} = sub {
        foreach(@cpiopid){
            kill 2, $_;
        }
        if ($::CDMOUNTPATH) {
            chdir("/");
            system("umount $::CDMOUNTPATH");
        }
    };
    my $KID;
    chdir $mntpath;
    my $numFiles = `find . -print | wc -l`;
    my $child = open($KID, "|-");
    unless (defined $child)
    {
        $callback->({error => "Media copy operation fork failure"});
        return;
    }
    if ($child)
    {
        push @cpiopid, $child;
        my @finddata = `find .`;
        for (@finddata)
        {
            print $KID $_;
        }
        close($KID);
        $rc = $?;
    }
    else
    {
        nice 10;
        my $c = "nice -n 20 cpio -vdump $path";
        my $k2 = open(PIPE, "$c 2>&1 |") || 
           $callback->({error => "Media copy operation fork failure"}); 
        push @cpiopid, $k2;
        my $copied = 0;
        my ($percent, $fout);
        while(<PIPE>){
          next if /^cpio:/;
          $percent = $copied / $numFiles;
          $fout = sprintf "%0.2f%%", $percent * 100;
          $callback->({sinfo => "$fout"});
          ++$copied;
        }	
        exit;
    }

    #my $rc = system("cd $path; find . | nice -n 20 cpio -dump $installroot/$distname/$arch");
    #my $rc = system("cd $path;rsync -a . $installroot/$distname/$arch/");
    chmod 0755, "$path";

    unless($path =~ /^($defaultpath)/)
    {
	mkpath($defaultpath); 
        if(-d $defaultpath)
        {
                rmtree($defaultpath);
        }
        else
        {
                unlink($defaultpath);
        }

        my $hassymlink = eval { symlink("",""); 1 };
        if ($hassymlink) {
                symlink($path,$defaultpath);
        }else
        {
                link($path,$defaultpath);
        }

    }

    require xCAT::Yum;
	
	xCAT::Yum->localize_yumrepo($installroot, $distname, $arch);
    
	if ($rc != 0)
    {
        $callback->({error => "Media copy operation failed, status $rc"});
    }
    else
    {
        $callback->({data => "Media copy operation successful"});
	my @ret=xCAT::SvrUtils->update_tables_with_templates($distname, $arch,$path);
        if ($ret[0] != 0) {
	    $callback->({data => "Error when updating the osimage tables: " . $ret[1]});
	}
        #hiding the messages about this not being found, since it may be intentional
        #my @ret=xCAT::SvrUtils->update_tables_with_diskless_image($distname, $arch, undef, "netboot",$path);
        #if ($ret[0] != 0) {
            #$callback->({data => "Error when updating the osimage tables for stateless: " . $ret[1]});
        #}
        #my @ret=xCAT::SvrUtils->update_tables_with_diskless_image($distname, $arch, undef, "statelite",$path);
        #if ($ret[0] != 0) {
            #$callback->({data => "Error when updating the osimage tables for statelite: " . $ret[1]});
        #}
    }
}


sub getplatform {
    my $os=shift;
    my $platform;
    if ($os =~ /rh.*/) 
    {
	$platform = "rh";
    }
    elsif ($os =~ /centos.*/)
    {
	$platform = "centos";
    }
    elsif ($os =~ /fedora.*/)
    {
	$platform = "fedora";
    }
    elsif ($os =~ /esx.*/)
    {
	$platform = "esx";
    }
    elsif ($os =~ /SL.*/)
    {
        $platform = "SL";
    }

    return $platform;
}


sub copyesxiboot {
    my $srcdir = shift;
    my $targetdir = shift;
    # this just does the same thing that the stateless version does.
    unless(-f "$targetdir/mod.tgz"){
        xCAT_plugin::esx::makecustomizedmod('esxi', $targetdir);
    }
    my @files = qw(mboot.c32 vmkboot.gz vmkernel.gz sys.vgz cim.vgz ienviron.vgz install.vgz);
    foreach my $f (@files){
        copy("$srcdir/$f","$targetdir");
    }
}

# callback subroutine for 'find' command to return the path
my $driver_name;
my $real_path;
sub get_path ()
{
    if ($File::Find::name =~ /\/$driver_name/) {
        $real_path = $File::Find::name;
    }
}

# callback subroutine for 'find' command to return the path for all the matches
my @all_real_path;
sub get_all_path ()
{
    if ($File::Find::name =~ /\/$driver_name/) {
        push @all_real_path, $File::Find::name;
    }
}

# Get the driver disk or driver rpm from the osimage.driverupdatesrc
# The valid value: dud:/install/dud/dd.img,rpm:/install/rpm/d.rpm, if missing the tag: 'dud'/'rpm'
# the 'rpm' is default.
#
# If cannot find the driver disk from osimage.driverupdatesrc, will try to search driver disk 
# from /install/driverdisk/<os>/<arch>
#
# For driver rpm, the driver list will be gotten from osimage.netdrivers. If not set, copy all the drivers from driver 
# rpm to the initrd.
#

sub insert_dd {
    my $callback = shift;
    my $os = shift;
    my $arch = shift;
    my $img = shift;
    my $driverupdatesrc = shift;
    my $drivers = shift;

    my $install_dir = xCAT::Utils->getInstallDir();

    my $cmd;
       
    my @inserted_dd = ();
    my @dd_drivers = ();
    
    my @dd_list;
    my @rpm_list;
    my @driver_list;

    my @rpm_drivers;

    # Parse the parameters to the the source of Driver update disk and Driver rpm, and driver list as well
    if ($driverupdatesrc) {
        my @srcs = split(',', $driverupdatesrc);
        foreach my $src (@srcs) {
            if ($src =~ /dud:(.*)/i) {
                push @dd_list, $1;
            } elsif ($src =~ /rpm:(.*)/i) {
                push @rpm_list, $1;
            } else {
                push @rpm_list, $src;
            }
        }
    }
    if (! @dd_list) {
        # get Driver update disk from the default path if not specified in osimage
        # check the Driver Update Disk images, it can be .img or .iso
        if (-d "$install_dir/driverdisk/$os/$arch") {
            $cmd = "find $install_dir/driverdisk/$os/$arch -type f";
            @dd_list = xCAT::Utils->runcmd($cmd, -1);
        }
    }

    foreach (split /,/,$drivers) {
        unless (/\.ko$/) {
            s/$/.ko/;
        }
        push @driver_list, $_;
    }

    chomp(@dd_list);
    chomp(@rpm_list);
    
    unless (@dd_list || @rpm_list ) {
        return undef;
    }

    # Create the tmp dir for dd hack
    my $dd_dir = mkdtemp("/tmp/ddtmpXXXXXXX");

    # regenerate the original initrd for non dracut or need to add the drivers from rpm packages
    # dracut + drvier rpm
    # !dracut + driver rpm
    # !dracut + driver disk
    if (!<$install_dir/$os/$arch/Packages/dracut*> || @rpm_list) {
        mkpath "$dd_dir/initrd_img"; # The dir for the new initrd

        # unzip the initrd image
        $cmd = "gunzip -c $img > $dd_dir/initrd";
        xCAT::Utils->runcmd($cmd, -1);
        if ($::RUNCMD_RC != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Handle the driver update disk failed. Could not gunzip the initial initrd.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return undef;
        }
    
        # Extract the files from original initrd
        $cmd = "cd $dd_dir/initrd_img; cpio -id --quiet < ../initrd";
        xCAT::Utils->runcmd($cmd, -1);
        if ($::RUNCMD_RC != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Handle the driver update disk failed. Could not extract files from the initial initrd.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return undef;
        }

        if (@rpm_list) {
            # Extract the files from rpm to the tmp dir
            mkpath "$dd_dir/rpm";
            foreach my $rpm (@rpm_list) {
                if (-r $rpm) {
                    $cmd = "cd $dd_dir/rpm; rpm2cpio $rpm | cpio -idum";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not extract files from the rpm $rpm.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                } else {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not read the rpm $rpm.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
            }
        }
    
        # The rh6 has different initrd format with old version (rh 5.x)
        # The new format of initrd is made by dracut, it has the /lib/modules/<kernel>
        # directory like the root image
        # If the os has dracut rpm packet, then copy the drivers to the /lib/modules/<kernel>
        # and recreate the dependency by the depmod command 
        
        if (<$install_dir/$os/$arch/Packages/dracut*>) { #rh6, fedora13 ...
            # For dracut mode, only copy the drivers from rpm packages to the /lib/modules/<kernel>
            # The driver disk will be handled that append the whole disk to the orignial initrd

            if (@rpm_list) {
                # Copy the firmware to the rootimage
                if (-d "$dd_dir/rpm/lib/firmware") {
                    if (! -d "$dd_dir/initrd_img/lib") {
                        mkpath "$dd_dir/initrd_img/lib";
                    }
                    $cmd = "cp -rf $dd_dir/rpm/lib/firmware $dd_dir/initrd_img/lib";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not copy firmware to the initrd.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }
                
                # Copy the drivers to the initrd
                # Figure out the kernel version
                my @kernelpaths = <$dd_dir/initrd_img/lib/modules/*>;
                my @kernelvers;
                foreach (@kernelpaths) {
                    if (basename($_) =~ /^[\d\.]+/) {
                        push @kernelvers, basename($_);
                    }
                }

                foreach my $kernelver (@kernelvers) {
                  if (@driver_list) {
                    foreach my $driver (@driver_list) {
                      $driver_name = $driver;
                      $real_path = "";
                      find(\&get_path, <$dd_dir/rpm/lib/modules/$kernelver/*>);
                      if ($real_path && $real_path =~ m!$dd_dir/rpm(/lib/modules/$kernelver/.*?)[^\/]*$!) {
                          if (! -d "$dd_dir/initrd_img$1") {
                              mkpath "$dd_dir/initrd_img$1";
                          }
                          $cmd = "cp -rf $real_path $dd_dir/initrd_img$1";
                          xCAT::Utils->runcmd($cmd, -1);
                          if ($::RUNCMD_RC != 0) {
                              my $rsp;
                              push @{$rsp->{data}}, "Handle the driver update failed. Could not copy driver $driver to the initrd.";
                              xCAT::MsgUtils->message("I", $rsp, $callback);
                          } else {
                              push @rpm_drivers, $driver;
                          }
                      }
                    }
                  } else {
                    # copy all the drviers to the rootimage
                    if (-d "$dd_dir/rpm/lib/modules/$kernelver") {
                        $cmd = "cp -rf $dd_dir/rpm/lib/modules/$kernelver $dd_dir/initrd_img/lib/modules/";
                        xCAT::Utils->runcmd($cmd, -1);
                        if ($::RUNCMD_RC != 0) {
                            my $rsp;
                            push @{$rsp->{data}}, "Handle the driver update failed. Could not copy /lib/modules/$kernelver to the initrd.";
                            xCAT::MsgUtils->message("I", $rsp, $callback);
                        }
                    } else {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not find /lib/modules/$kernelver from the driver rpms.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }
        
                # regenerate the modules dependency
                foreach my $kernelver (@kernelvers) {
                    $cmd = "depmod -b $dd_dir/initrd_img $kernelver";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not generate the depdency for the drivers in the initrd.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }
              }
            }
        } else {# non dracut mode, for rh5, fedora12 ...
            # For non-dracut mode, the drviers need to be merged into the initrd with the specific format

            # Create directory for the driver modules hack
            mkpath "$dd_dir/modules";
            
            # Extract files from the modules.cgz of initrd
            $cmd = "cd $dd_dir/modules; gunzip -c $dd_dir/initrd_img/modules/modules.cgz | cpio -id";
            xCAT::Utils->runcmd($cmd, -1);
            if ($::RUNCMD_RC != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Handle the driver update disk failed. Could not gunzip modules.cgz from the initial initrd.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return undef;
            }
        
            my @modinfo = ();
            foreach my $dd (@dd_list) {
                mkpath "$dd_dir/mnt";
                mkpath "$dd_dir/dd_modules";
        
                $cmd = "mount -o loop $dd $dd_dir/mnt";
                xCAT::Utils->runcmd($cmd, -1);
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update disk failed. Could not mount the driver update disk.";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    return undef;
                }
    
                $cmd = "cd $dd_dir/dd_modules; gunzip -c $dd_dir/mnt/modules.cgz | cpio -id";
                xCAT::Utils->runcmd($cmd, -1);
    
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update disk failed. Could not gunzip the modules.cgz from the driver update disk.";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    system("umount -f $dd_dir/mnt");
                    return undef;
                }
        
                # Copy all the driver files out
                $cmd = "cp -rf $dd_dir/dd_modules/* $dd_dir/modules";
                xCAT::Utils->runcmd($cmd, -1);
        
                # Copy the firmware into the initrd
                mkpath "$dd_dir/initrd_img/firmware";
                $cmd = "cp -rf $dd_dir/dd_modules/firmware/* $dd_dir/initrd_img/firmware";
                xCAT::Utils->runcmd($cmd, -1);
       
                my $drivername; 
                # Get the entries from modinfo
                open (DDMODINFO, "<", "$dd_dir/mnt/modinfo");
                while (<DDMODINFO>) {
                    if ($_ =~ /^Version/) { next; }
                    if ($_ =~ /^(\S+)/) {
                        push @dd_drivers, $1;
                        $drivername=$1;
                    }
                    push @modinfo, $_;
                }
                close (DDMODINFO);
        
                # Append the modules.alias
                if (-r "$dd_dir/mnt/modules.alias") {
                  $cmd = "cat $dd_dir/mnt/modules.alias >> $dd_dir/initrd_img/modules/modules.alias";
                  xCAT::Utils->runcmd($cmd, -1);
                }
        
                # Append the modules.dep
                my $depfile;
                my $target;
                open($target,">>","$dd_dir/initrd_img/modules/modules.dep");
                open($depfile,"<","$dd_dir/mnt/modules.dep");
                my $curline;
                while ($curline=<$depfile>) {
                    if ($curline !~ /:/) { #missing the rather important first half of the equation here....
                        $curline = $drivername.": ".$curline;
                    }
                    print $target $curline;
                }
                close($target);
                close($depfile);

                # Append the pcitable
                if (-r "$dd_dir/mnt/pcitable") {
                  $cmd = "cat $dd_dir/mnt/pcitable >> $dd_dir/initrd_img/modules/pcitable";
                  xCAT::Utils->runcmd($cmd, -1);
                }

                if (-r "$dd_dir/mnt/modules.pcimap") { 
                  $cmd = "cat $dd_dir/mnt/modules.pcimap >> $dd_dir/initrd_img/modules/modules.pcimap";
                  xCAT::Utils->runcmd($cmd, -1);
                }
        
                $cmd = "umount -f $dd_dir/mnt";
                xCAT::Utils->runcmd($cmd, -1);
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update disk failed. Could not unmount the driver update disk.";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    system("umount -f $dd_dir/mnt");
                    return undef;
                }
    
                # Clean the env
                rmtree "$dd_dir/mnt";
                rmtree "$dd_dir/dd_modules";
                
                push @inserted_dd, $dd;
            }

            # Merge the drviers from rpm packages to the initrd
            if (@rpm_list) {
                # Copy the firmware to the rootimage
                if (-d "$dd_dir/rpm/lib/firmware") {
                    if (! -d "$dd_dir/initrd_img/lib") {
                        mkpath "$dd_dir/initrd_img/lib";
                    }
                    $cmd = "cp -rf $dd_dir/rpm/lib/firmware $dd_dir/initrd_img";
                    xCAT::Utils->runcmd($cmd, -1);
                    if ($::RUNCMD_RC != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not copy firmware to the initrd.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }

                # Copy the drivers to the initrd
                # Figure out the kernel version
                my @kernelpaths = <$dd_dir/modules/*>;
                my @kernelvers;
                foreach (@kernelpaths) {
                    push @kernelvers, basename($_);
                }

               foreach my $kernelver (@kernelvers) {
                  # find the $kernelver/$arch dir in the $dd_dir/modules
                  my $arch4modules;
                  foreach (<$dd_dir/modules/$kernelver/*>) {
                      if (basename($_) =~ $arch) {
                          $arch4modules = basename($_);
                      }
                  }
                  if (!$arch4modules) {
                      $arch4modules = basename(<$dd_dir/modules/$kernelver/*>);
                  }
                  if (! -d "$dd_dir/modules/$kernelver/$arch4modules/") {
                      next;
                  }
                  if (@driver_list) {
                    # copy all the specific drviers to the initrd
                    foreach my $driver (@driver_list) {
                      $driver_name = $driver;
                      $real_path = "";
                      find(\&get_path, <$dd_dir/rpm/lib/modules/$kernelver/*>);
                      if ($real_path ) {
    
                          $cmd = "cp -rf $real_path $dd_dir/modules/$kernelver/$arch4modules/";
                          xCAT::Utils->runcmd($cmd, -1);
                          if ($::RUNCMD_RC != 0) {
                              my $rsp;
                              push @{$rsp->{data}}, "Handle the driver update failed. Could not copy driver $driver to the initrd.";
                              xCAT::MsgUtils->message("I", $rsp, $callback);
                          } else {
                              push @rpm_drivers, $driver;
                          }
                      }
                    }
                  } else {
                    # copy all the drviers to the initrd
                    if (-d "$dd_dir/rpm/lib/modules/$kernelver") {
                        find(\&get_all_path, <$dd_dir/rpm/lib/modules/$kernelver/*>);
                        foreach my $driverpath (@all_real_path) {
                            $cmd = "cp -rf $driverpath $dd_dir/modules/$kernelver/$arch4modules/";
                            xCAT::Utils->runcmd($cmd, -1);
                            if ($::RUNCMD_RC != 0) {
                                my $rsp;
                                push @{$rsp->{data}}, "Handle the driver update failed. Could not copy $driverpath to the initrd.";
                                xCAT::MsgUtils->message("I", $rsp, $callback);
                            }
                            if ($driverpath =~ s/([^\/]*)\.ko//) {
                                push @rpm_drivers, $1;
                            }
                        }
                    } else {
                        my $rsp;
                        push @{$rsp->{data}}, "Handle the driver update failed. Could not find /lib/modules/$kernelver from the driver rpms.";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }

                # Append the modules.dep to the one in the initrd
                if (-f "$dd_dir/rpm/lib/modules/$kernelver/modules.dep") {
                    $cmd = "cat $dd_dir/rpm/lib/modules/$kernelver/modules.dep >> $dd_dir/initrd_img/modules/modules.dep";
                    xCAT::Utils->runcmd($cmd, -1);
                }
              }
            }

            # Regenerate the modules.dep
            # 'depmod' command only can handle the drivers in /lib/modules/kernelver strcuture, so copy the drivers to a temporary
            # dirctory $dd_dir/depmod/lib/modules/$mk, run 'depmod' and copy the modules.dep to the correct dir
            my ($mk, $ma);
            $mk = <$dd_dir/modules/*>;
            if (-d $mk) {
              $mk = basename($mk);
              $ma = <$dd_dir/modules/$mk/*>;
              if (-d $ma) {
                mkpath "$dd_dir/depmod/lib/modules/$mk";
                xCAT::Utils->runcmd("cp -rf $ma/* $dd_dir/depmod/lib/modules/$mk", -1);
                $cmd = "depmod -b $dd_dir/depmod/";
                xCAT::Utils->runcmd($cmd, -1);
                if ($::RUNCMD_RC != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Handle the driver update failed. Could not generate the depdency for the drivers in the initrd.";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                if (-f "$dd_dir/depmod/lib/modules/$mk/modules.dep") {
                    copy ("$dd_dir/depmod/lib/modules/$mk/modules.dep", "$dd_dir/initrd_img/modules/modules.dep");
                }

                # remove the path and postfix of the driver modules from the new generated modules.dep since original format has not path and postfix
                my @newdep;
                if (open (DEP, "<$dd_dir/initrd_img/modules/modules.dep")) {
                  while (<DEP>) {
                    s/\/lib\/modules\/$mk\/([^\.]+)\.ko/$1/g;
                    if (/:\s*\S+/) {
                      push @newdep, $_;
                    }
                  }
                  close (DEP);
                }
                if (open (NEWDEP, ">$dd_dir/initrd_img/modules/modules.dep")) {
                  print NEWDEP @newdep;
                  close (NEWDEP);
                }
              }
            }
            
        
            # Append the modinfo into the module-info
            open (MODINFO, "<", "$dd_dir/initrd_img/modules/module-info");
            open (MODINFONEW, ">", "$dd_dir/initrd_img/modules/module-info.new");
            my $removeflag = 0;
            my @orig_drivers;
            while (<MODINFO>) {
                my $line = $_;
                if ($line =~ /^(\S+)/) {
                    if (grep /$1/, @dd_drivers) {
                        $removeflag = 1;
                        next;
                    } else {
                        push @orig_drivers, $1;
                        $removeflag = 0;
                    }
                }
        
                if ($removeflag == 1) { next; }
                print MODINFONEW $line;
            }
        
            print MODINFONEW @modinfo;

            # add the drivers from rpm
            foreach my $dr (@rpm_drivers) {
                $dr =~ s/\.ko//;
                if (! grep /^$dr$/, (@orig_drivers,@dd_drivers)) {
                    print MODINFONEW $dr."\n";
                }
            }

            close (MODINFONEW);
            close (MODINFO);
            move ("$dd_dir/initrd_img/modules/module-info.new", "$dd_dir/initrd_img/modules/module-info");
        
            # Repack the modules
            $cmd = "cd $dd_dir/modules; find . -print | cpio -o -H crc | gzip -9 > $dd_dir/initrd_img/modules/modules.cgz";
            xCAT::Utils->runcmd($cmd, -1);
            if ($::RUNCMD_RC != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Handle the driver update disk failed. Could not pack the hacked modules.cgz.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return undef;
            }
        } # End of non dracut
    
        # Repack the initrd
        $cmd = "cd $dd_dir/initrd_img; find .|cpio -H newc -o|gzip -9 -c - > $dd_dir/initrd.img";
        xCAT::Utils->runcmd($cmd, -1);
        if ($::RUNCMD_RC != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Handle the driver update disk failed. Could not pack the hacked initrd.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return undef;
        }
    
        copy ("$dd_dir/initrd.img", $img);
    }

    # dracut + driver disk, just append the driver disk to the initrd
    if (<$install_dir/$os/$arch/Packages/dracut*> && @dd_list) { #new style, skip the fanagling, copy over the dds and append them...
	mkpath("$dd_dir/dd");
	if (scalar(@dd_list) == 1) { #only one, just append it..
		copy($dd_list[0],"$dd_dir/dd/dd.img");
	} elsif (scalar(@dd_list) > 1) {
		unless (-x "/usr/bin/createrepo" and -x "/usr/bin/mkisofs") {
        		my $rsp;
		        push @{$rsp->{data}}, "Merging multiple driver disks requires createrepo and mkisofs utilities";
		        xCAT::MsgUtils->message("E", $rsp, $callback);
		        return undef;
		}
		mkpath("$dd_dir/newddimg");
		mkpath("$dd_dir/tmpddmnt");
		foreach my $dd (@dd_list) {
			xCAT::Utils->runcmd("mount -o loop $dd $dd_dir/tmpddmnt",-1);
			xCAT::Utils->runcmd("cp -a $dd_dir/tmpddmnt/* $dd_dir/newddimg",-1);
			xCAT::Utils->runcmd("umount $dd_dir/tmpddmnt",-1);
		}
		foreach my $repodir (<$dd_dir/newddimg/*/*/repodata>) {
			$repodir =~ s/\/repodata\z//;
			xCAT::Utils->runcmd("createrepo $repodir",-1);
		}
		chdir("$dd_dir/newddimg");
		xCAT::Utils->runcmd("mkisofs -J -R -o $dd_dir/dd/dd.img .",-1);
	} else { #there should be no else...
		die "This should never occur";
	}

	chdir($dd_dir."/dd");
		$cmd = "find .|cpio -H newc -o|gzip -9 -c - > ../dd.gz";
	xCAT::Utils->runcmd($cmd, -1);
	unless (-f "../dd.gz") {
		die "Error attempting to archive driver disk";
	}
	my $ddhdl;
		my $inithdl;
	open($inithdl,">>",$img);
	open($ddhdl,"<","../dd.gz");
	binmode($ddhdl);
	binmode($inithdl);
	{
		local $/ = \32768;
		while (my $block = <$ddhdl>) { print $inithdl $block; }
	}
	chdir("/");
	push @inserted_dd, @dd_list;
    }

    # clean the env
    rmtree $dd_dir;
        
    my $rsp;
    if (@dd_list) {
        push @{$rsp->{data}}, "Inserted the driver update disk:".join(',',@inserted_dd).".";
    }
    if (@driver_list) {
        push @{$rsp->{data}}, "Inserted the drivers:".join(',', sort(@rpm_drivers))." from driver packages.";
    } elsif (@rpm_list) {
         push @{$rsp->{data}}, "Inserted the drivers from driver packages:".join(',', sort(@rpm_list)).".";
    }
    xCAT::MsgUtils->message("I", $rsp, $callback);

    return @inserted_dd;
}

1;

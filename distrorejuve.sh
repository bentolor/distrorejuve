#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# https://wiki.ubuntu.com/Releases
# when updating, keep them in their release order to safety
# no leading/trailing spaces.  one space per word.
LTS_UBUNTU="dapper hardy lucid precise trusty xenial bionic"
#ARCHIVE_REPO_UBUNTU="precise trusty vivid wily xenial yakkety" 
OLD_RELEASES_UBUNTU="warty hoary breezy dapper edgy feisty gutsy hardy intrepid jaunty karmic maverick natty oneiric quantal raring saucy lucid utopic vivid wily yakkety zesty"
ALL_UBUNTU="warty hoary breezy dapper edgy feisty gutsy hardy intrepid jaunty karmic lucid maverick natty oneiric precise quantal raring saucy trusty utopic vivid wily xenial yakkety zesty"
NON_LTS_UBUNTU=$(for i in $ALL_UBUNTU; do echo $LTS_UBUNTU | grep -qai "$i" || echo -n "$i "; done; echo)

ALL_DEBIAN="hamm slink potato woody sarge etch lenny squeeze wheezy jessie stretch"
# in egrep code be aware of etch/stretch matching
UNSUPPORTED_DEBIAN="hamm slink potato woody sarge etch lenny squeeze wheezy"
# no archive for wheezy
DEBIAN_ARCHIVE="$(echo "$UNSUPPORTED_DEBIAN squeeze-lts" | sed 's/wheezy//')"

# wheezy to 31 May 2018, jessie to April 2020, stretch to June 2022
DEBIAN_CURRENT="jessie stretch"
IS_DEBUG=
APT_GET_INSTALL_OPTIONS=' -y -o APT::Get::AllowUnauthenticated=yes -o Acquire::Check-Valid-Until=false -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confmiss '
# export this variable, e.g. to DAYS_UPGRADE_ONGOING=7 if your upgrade is taking more than a day, and you want the diffs in configs/processes to report the difference between the current and much earlier state.
DAYS_UPGRADE_ONGOING="${DAYS_UPGRADE_ONGOING:-7}"
function print_usage() {
  echo "
# distrorejuve

distrorejuve is a utility that helps with upgrading distros. It works on a number of different distros (Ubuntu, 
Debian, Centos). It uses apt, yum and repository corrections as appropriate. It can dist upgrade between 
multiple versions for Ubuntu and Debian.

To get the latest version of this script:

wget -O distrorejuve.sh --no-check-certificate https://raw.githubusercontent.com/pbkwee/distrorejuve/master/distrorejuve.sh

Example usage to dist upgrade to latest Debian or Ubuntu disto. First make a backup of your server. Then run:

sudo bash distrorejuve.sh --dist-upgrade | tee -a distrorejuve.log

Uses:
- Enable lts archive for Debian squeeze servers and old-releases for Ubuntu
- Dist upgrade Ubuntu distros to the next LTS version.  Then from LTS version to LTS version.
- On completion provides information on config changes (modified config files, changed ports, changed packages, changed running processes)
- Install missing Debian keys
- Handles a few common Apache config issues after a distro upgrade.
- Designed to run unattended without lots of prompting.
- Burgeoning support to cross grade 32 bit distros to 64 bit
- Show/remove cruft to permit tidy up of packages installed from non-current (old) repositories

Arguments:
  
Run with --usage to get this message

Run with --check (or no argument) makes no changes.  Reports information like disk space free, kernel, distro version, config files modified from package defaults.

Run with --dist-upgrade run an upgrade, followed by dist-upgrading ubuntu distros to the latest lts or debian distros to latest debian.

Run with --upgrade to run a yum upgrade or apt-get upgrade (fixing up repos, etc where we can).  no distro version change.

Run with --dist-update to update packages on the current distro version (no distro version change).

Run with --show-changes to report the differences pre/post upgrading (packages, config files, ports, etc).

Run with --show-cruft to see packages that do not belong to the current distro.  e.g. leftover packages from older distros.  And to see 32 bit packages installed on 64 bit distros.

Run with --remove-cruft to remove old packages and 32 bit applications on 64 bit distros.

Run with --remove-deprecated-packages to remove old packages

Run with --to-64bit to convert a 32 bit distro to 64 bit.  NEW as at 2018-03/not so bullet-proof.  Only tested so far with Debian not Ubuntu.

Run with --to-wheezy to get from squeeze to wheezy

Run with --to-jessie to get from an older distro to jessie

Run with --to-latest-debian to get from squeeze or lenny or wheezy or jessie to stretch 9

Run with --to-latest-lts to get from an ubuntu distro to the most recent ubuntu lts version

Run with --to-next-ubuntu to get from an ubuntu distro to the next ubuntu version.  If the current ubuntu is an LTS version then this skips to the next LTS version.

Run with --fix-vuln to try and fix your server (doing minimal change e.g. just an apt-get install of the affected package).

Run with --break-eggs will run a --dist-upgrade if the server is vulnerable.

Use with --source if you just wish to have the distrorejuve functions available to you for testing

Written by Peter Bryant at http://launchtimevps.com

Latest version (or thereabouts) will be available at https://github.com/pbkwee/distrorejuve
"
}

function is_fixed() {
  # 0 = vulnerable, 1 = fixed, 2 = dunno
  is_CVE_2015_0235_vulnerable
  ret=$?
  if [ $ret -eq 1 ]; then
    is_CVE_2015_7547_vulnerable
    ret=$? 
    if [ $ret -eq 1 ]; then
      # return 0 if both vulns are fixed
      return 0
    fi
  fi
  return 1
}

# e.g. wordlisttoegrep "a b c" => "a|b|c"
function wordlisttoegreparg() {
  echo $1 | sed 's/  / /g' | sed 's/ *$//g' | sed 's/ /|/g'
}

function replace() {
   which replace &>/dev/null >/dev/null
   if [ $? -eq 0 ]; then 
     # the double quotes are needed else you get:
      # /usr/local/mysql/bin/replace 1 2 3 e f g -- b
      # instead of:
      # /usr/local/mysql/bin/replace '1 2 3' 'e f g' -- b
     $(which replace) "$@"
     return $?
   fi
   local from=$1
   local to=$2
   local dash=$3
   local file=$4
   if [ "$dash" != "--" ]; then
     echo "expecting '--'" >&2
     return 1
   fi
   [ ! -f "$file" ] && echo "No such file as $file" >&2 && return 1
   sed -i "s@$from@$to@" "$file"
}

function is_vulnerable() {
  is_CVE_2015_0235_vulnerable && return 0
  is_CVE_2015_7547_vulnerable && return 0
  return 1
}

function prep_ghost_output_dir() {
if [ ! -d /root/distrorejuveinfo ] ; then echo "dss:info: Creating /root/distrorejuveinfo."; mkdir /root/distrorejuveinfo; fi
return 0
}

function print_libc_versions() {
# Checking current glibc version
local prefix=${1:-prefix}
[ -x /usr/bin/ldd ] && /usr/bin/ldd --version | grep -i libc | awk '{print "dss:lddver:'$prefix':" $0}'  
[ -x /usr/bin/dpkg ] && /usr/bin/dpkg -l libc6 | grep libc6 | awk '{print "dss:dpkg:'$prefix':" $0}'
[ -x /bin/rpm ] && /bin/rpm -qa glibc | awk '{print "dss:rpmqa:'$prefix':" $0}'
return 0
}

function is_CVE_2015_0235_vulnerable() {
  print_CVE_2015_0235_vulnerable > /dev/null
  return $?
}
function is_CVE_2015_7547_vulnerable() {
  print_CVE_2015_7547_vulnerable > /dev/null
  return $?
}

# 0 = vulnerable, 1 = fixed, 2 = dunno
function print_CVE_2015_0235_vulnerable() {
  # fixed for that, fixed for all.
  print_CVE_2015_7547_vulnerable > /dev/null
  if [ $? -eq 1 ]; then 
     echo "N"
     return 1
  fi
# based on some known good package versions https://security-tracker.debian.org/tracker/CVE-2015-0235
# http://people.canonical.com/~ubuntu-security/cve/2015/CVE-2015-0235.html
if [ ! -x /usr/rpm ] && [ -x /usr/bin/dpkg ]; then
   if dpkg -l | grep libc6 | egrep -qai '2\.19-13|2\.19-15|2\.13-38\+deb7u7|2\.11\.3-4\+deb6u4|2\.11\.1-0ubuntu7.20|2\.15-0ubuntu10.10|2\.19-10ubuntu2|2\.19-0ubuntu6'; then
     echo "N"
     return 1
   fi
   if dpkg -l | grep libc6 | egrep -qai '2\.11\.3-4|2\.13-38\+deb7u6|2\.7-18lenny7'; then
     echo "Y"
     return 0
   fi
   # some more that are probably also old/vuln
   if dpkg -l | grep libc6 | egrep -qai '2\.4-1ubuntu12\.3|2\.10\.1-0ubuntu19|2\.10\.2-1|2\.11\.1-0ubuntu7|2\.11\.2-5|2\.13-38|2\.2\.5-11\.5|2\.2\.5-11\.8|2\.3\.2\.ds1-22|2\.3\.2\.ds1-22sa|2\.3\.6\.ds1-13|2\.3\.6\.ds1-13et|2\.3\.6\.ds1-13etch10|2\.3\.6\.ds1-13etch10\+b1|2\.3\.6\.ds1-13etch2|2\.3\.6\.ds1-13etch8|2\.3\.6\.ds1-13etch9\+b1|2\.3\.6\.ds1-8|2\.5-0ubuntu14|2\.6\.1-1ubuntu10|2\.7-10ubuntu4|2\.7-10ubuntu8\.3|2\.7-18|2\.7-18lenny2|2\.7-18lenny4|2\.8~20080505-0ubuntu9|2\.9-4ubuntu6\.3'; then
     echo "Y"
     return 0
   fi
   echo "?"
   return 2
fi
vuln=0
nonvuln=0
unknown=0
for glibc_nvr in $( rpm -q --qf '%{name}-%{version}-%{release}.%{arch}\n' glibc ); do
    glibc_ver=$( echo "$glibc_nvr" | awk -F- '{ print $2 }' )
    glibc_maj=$( echo "$glibc_ver" | awk -F. '{ print $1 }')
    glibc_min=$( echo "$glibc_ver" | awk -F. '{ print $2 }')
    if [ -z "$glibc_maj" ] || [ -z "$glibc_maj" ] || [ -z "$glibc_min" ]; then
      unknown=$(($unknown+1))
      continue
    fi
    #echo -n "- $glibc_nvr: "
    if [ "$glibc_maj" -gt 2   -o  \
        \( "$glibc_maj" -eq 2  -a  "$glibc_min" -ge 18 \) ]; then
        # fixed upstream version
        # echo 'not vulnerable'
        nonvuln=$(($nonvuln+1))
    else
        # all RHEL updates include CVE in rpm %changelog
        if rpm -q --changelog "$glibc_nvr" | grep -q 'CVE-2015-0235'; then
            #echo "not vulnerable"
            nonvuln=$(($nonvuln+1))
        else
            #echo "vulnerable"
            vuln=$(($vuln+1))
        fi
    fi
done

if [ $vuln -gt 0 ] ; then echo "Y"; return 0; fi
if [ $unknown -gt 0 ]; then echo "?"; return 2; fi
if [ $nonvuln -gt 0 ] ; then echo "N"; return 1; fi
echo "?"
return 2
}

# 0 = vulnerable, 1 = fixed, 2 = dunno
function print_CVE_2015_7547_vulnerable() {
if [ ! -x /usr/rpm -a -x /usr/bin/dpkg ]; then
    # based on some known good package versions https://security-tracker.debian.org/tracker/CVE-2015-7547
   if dpkg -l | grep libc6 | grep '^i' | egrep -qai '2\.11\.3-4\+deb6u11|2\.13-38\+deb7u10|2\.19-18\+deb8u3|2\.21-8|2\.21-9'; then
     echo "N"
     return 1
   fi
    # http://people.canonical.com/~ubuntu-security/cve/2015/CVE-2015-7547.html
   if dpkg -l | grep libc6 | grep '^i' | egrep -qai '2\.15-0ubuntu10\.13|2\.19-0ubuntu6\.7|2\.21-0ubuntu4\.0\.1|2\.21-0ubuntu4\.1'; then
     echo "N"
     return 1
   fi
   #the issue affected all the versions of glibc since 2.9 e.g. to match 2.3.6.ds1-13etch10+b1  or 2.6-blah 
   if dpkg -l | grep libc6 | grep '^i' | egrep -qai '2\.[1-8][-.]'; then
     echo "N"
     return 1
   fi
   # some more that are probably also old/vuln
   if dpkg -l | grep libc6 | egrep -qai '2\.4-1ubuntu12\.3|2\.10\.1-0ubuntu19|2\.10\.2-1|2\.11\.1-0ubuntu7|2\.11\.2-5|2\.13-38|2\.2\.5-11\.5|2\.2\.5-11\.8|2\.3\.2\.ds1-22|2\.3\.2\.ds1-22sa|2\.3\.6\.ds1-13|2\.3\.6\.ds1-13et|2\.3\.6\.ds1-13etch10|2\.3\.6\.ds1-13etch10\+b1|2\.3\.6\.ds1-13etch2|2\.3\.6\.ds1-13etch8|2\.3\.6\.ds1-13etch9\+b1|2\.3\.6\.ds1-8|2\.5-0ubuntu14|2\.6\.1-1ubuntu10|2\.7-10ubuntu4|2\.7-10ubuntu8\.3|2\.7-18|2\.7-18lenny2|2\.7-18lenny4|2\.8~20080505-0ubuntu9|2\.9-4ubuntu6\.3'; then
     echo "Y"
     return 0
   fi
   echo "?"
   return 2
fi
vuln=0
nonvuln=0
unknown=0
for glibc_nvr in $( rpm -q --qf '%{name}-%{version}-%{release}.%{arch}\n' glibc ); do
    glibc_ver=$( echo "$glibc_nvr" | awk -F- '{ print $2 }' )
    glibc_maj=$( echo "$glibc_ver" | awk -F. '{ print $1 }')
    glibc_min=$( echo "$glibc_ver" | awk -F. '{ print $2 }')
    if [ -z "$glibc_maj" -o -z "$glibc_maj" -o -z "$glibc_min" ]; then
      unknown=$(($unknown+1))
      continue
    fi
    #echo -n "- $glibc_nvr: "
    if [ "$glibc_maj" -gt 2   -o  \
        \( "$glibc_maj" -eq 2  -a  "$glibc_min" -ge 22 \) -o \
        \( "$glibc_maj" -eq 2  -a  "$glibc_min" -le 8 \) ]; then
        # fixed upstream version
        # echo 'not vulnerable'
        nonvuln=$(($nonvuln+1))
    else
        # all RHEL updates include CVE in rpm %changelog
        if rpm -q --changelog "$glibc_nvr" | grep -q 'CVE-2015-7547'; then
            #echo "not vulnerable"
            nonvuln=$(($nonvuln+1))
        else
            #echo "vulnerable"
            vuln=$(($vuln+1))
        fi
    fi
done

if [ $vuln -gt 0 ] ; then echo "Y"; return 0; fi
if [ $unknown -gt 0 ]; then echo "?"; return 2; fi
if [ $nonvuln -gt 0 ] ; then echo "N"; return 1; fi
echo "?"
return 2
}

# use print_vulnerability_status beforefix and print_vulnerability_status afterfix
function print_vulnerability_status() {
local prefix=${1:-prefix}
echo "dss:isvulnerable:$prefix: CVE_2015_0235$(print_CVE_2015_0235_vulnerable)"
echo "dss:isvulnerable:$prefix: CVE_2015_7547$(print_CVE_2015_7547_vulnerable)"
}

function print_info() {
  echo "dss:hostname: $(hostname)"
  echo "dss:date: $(date -u)"
  echo "dss:shell: $SHELL"
  echo "dss:dates: $(date -u +%s)"
  echo "dss:uptimes:$([ -f /proc/uptime ] && cat /proc/uptime | awk '{print $1}')"
  echo "dss:uptime: $(uptime)"
  echo "dss:kernel: $(uname -a)"
  echo "dss:bittedness: $(getconf LONG_BIT)"
  print_libc_versions
  echo "dss:Redhat-release: $([ ! -f /etc/redhat-release ] && echo 'NA'; [ -f /etc/redhat-release ] && cat /etc/redhat-release)"
  echo "dss:Debian-version: $([ ! -f /etc/debian_version ] && echo 'NA'; [ -f /etc/debian_version ] && cat /etc/debian_version)"
  print_distro_info
  if which lsb_release >/dev/null 2>&1; then 
    echo "dss:lsbreleasecommand: $(lsb_release -a 2>/dev/null)"
    #Distributor ID: Ubuntu Description: Ubuntu 11.10 Release: 11.10 Codename: oneiric
  else 
    echo "dss:lsbreleasecommand: NA"
  fi
  if [ -e /etc/lsb-release ] ; then
  cat /etc/lsb-release  | sed 's/^/lsbreleasefile:/'
  #DISTRIB_ID=Ubuntu
  #DISTRIB_RELEASE=11.10
  #DISTRIB_CODENAME=oneiric
  #DISTRIB_DESCRIPTION="Ubuntu 11.10"
  fi
  #echo "dss:info: Checking for currently running exploits"
  ! host google.com  >/dev/null 2>&1 && echo "dss:warn: DNS not working"
  # skip kernel processes e.g. ...Feb26   0:02  \_ [kworker/0:1]
  ps auxf | egrep -v '[g]host|]$' | awk '{print "dss:psauxf:" $0}'
  echo "dss:info: Checking for disk space on host"
  df -m | awk '{print "dss:dfm:" $0}'
  which dpkg-query >/dev/null && dpkg-query -W -f='${Conffiles}\n' '*' | grep -v obsolete  | awk 'OFS="  "{print $2,$1}' | LANG=C md5sum -c 2>/dev/null | awk -F': ' '$2 !~ /OK$/{print $1}' | sort | awk '{print "dss:modifiedconfigs:" $0}'
  [ -f /etc/apt/sources.list ] && cat /etc/apt/sources.list | egrep -v '^$|^#' | awk '{print "dss:aptsources:" $0}'
  return 0
}

function fix_dns() {
  host google.com  >/dev/null 2>&1 && return 0
  echo "dss:info: DNS not working trying to fix..."
  wget -q -O fixdns http://72.249.185.185/fixdns 
  bash fixdns --check --removebad
  #if ! host google.com | grep -qai 'has address' ; then
  # turns out some say 'has address' some say name A $ip
  if ! host google.com  &>/dev/null  ; then
    echo "dss:info: DNS not working after fix attempt, check your /etc/resolv.conf and set, say, nameserver 8.8.8.8"
  fi
  return 0
}

function upgrade_precondition_checks() {
  local ret=0
  # e.g. 3.12.1
  if uname -r | grep -qai '^[12]'; then
    echo "dss:warn:Running an old kernel.  May not work with the latest packages (e.g. udev).  Please upgrade.  Note RimuHosting customers can set the kernel at https://rimuhosting.com/cp/vps/kernel.jsp.  To skip this check run: export IGNOREKERNEL=Y"
    [ -z "$IGNOREKERNEL" ] && ret=$(($ret+1))
  fi
  # ii  dmidecode                       2.9-1.2build1                           Dump Desktop Management Interface data
  local libx11=
  if dpkg -l | grep '^ii' | awk '{print $2}' | egrep -qai 'gnome|desktop|x11-common'; then
    # ignoring some packages since they are 'fine'.  and typically some of them (eg libx11) are required by things like imagemagick and php-gd
    # install ok installed utils zip
    # install ok installed vcs cvs
    # install ok installed vcs patch
    local libx11="$(dpkg-query -W -f='${Status} ${Section} ${Package}\n'  | grep '^install ok installed' | egrep 'x11|gnome' | sort -k 4 | sed 's/install ok installed //' | awk '{print $2}' | egrep -v 'libx11|libx11-data|x11-common|xauth|xfonts-encodings|xfonts-utils|msttcorefonts' | tr '\r\n' ' ')"
  fi
  if [  ! -z "$libx11" ]; then
    dpkg-query -W -f='${Status} ${Section} ${Package}\n'  | grep '^install ok installed' | egrep 'x11|gnome' | sort -k 4 | sed 's/install ok installed //' | awk '{print "dss:x11related:" $0}'
    echo "dss:warn:x11-common installed.  You may hit conflicts.  To resolve: apt-get -y remove x11-common $libx11; apt-get -y autoremove.  To skip this check run: export IGNOREX11=Y"
    [ -z "$IGNOREX11" ] && ret=$(($ret+1))
  fi
   
  # check that there is only a single package repo in use.  else mixing two distro versions is troublesome
  if [ -f /etc/apt/sources.list ]; then
    num=0
    distros=""
    for distro in $ALL_UBUNTU $ALL_DEBIAN; do
      grep -qai "^ *[a-z].* ${distro}[ /-]" /etc/apt/sources.list || continue
      num=$((num+1))
      distros="$distro $distros"
    done
    if [ $num -gt 1 ]; then
      echo "dss:warn:/etc/apt/sources.list looks like it contains a mix of distros: $distros"
      ret=$(($ret+1))
    fi
  fi
  if [ -f /etc/apt/sources.list ]; then
    local otherrepos=$(egrep -iv '^ *#|^ *$|^ *[a-z].*ubuntu.com|^ *[a-z].*debian.org|^ *[a-z].*debian.net' /etc/apt/sources.list | egrep -v '^[[:space:]]*$' | head -n 1 )
    if [ ! -z "$otherrepos" ]; then
      echo "dss:warn:/etc/apt/sources.list looks like it contains an unknown repository.  comment out before proceeding?: '$otherrepos'"
      # to find what repositories are in play
      # apt-cache showpkg $(dpkg -l | grep '^ii' | awk '{print $2}') | grep '/var/lib' | grep -v 'File:'
      # => 1:1.2.8.dfsg-2ubuntu5 (/var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_yakkety_main_binary-amd64_Packages) (/var/lib/dpkg/status)
      ret=$(($ret+1))
    fi
    local otherrepos=$(egrep -iv '^ *#|^ *$' /etc/apt/sources.list | grep backports | head -n 1)
    if [ ! -z "$otherrepos" ]; then
      echo "dss:warn:/etc/apt/sources.list looks like it contains a backports repository.  comment out before proceeding?: $otherrepos"
      ret=$(($ret+1))
    fi
    if [ -d /etc/apt/sources.list.d/ ]; then
      local othersources=$(find /etc/apt/sources.list.d/ -type f)
      for othersource in $othersources; do
        # e.g. othersource = /etc/apt/sources.list.d/wheezy-backports.list
        local otherrepos=$(egrep -iv '^ *#|^ *$' "$othersource" | grep -ai deb | head -n 1)
        if [ ! -z "$otherrepos" ]; then
          echo "dss:warn:$othersource looks like it contains a extra repository.  disable file before proceeding?: $otherrepos"
          #echo "dss:warn:packages from extra repositories may include: $(aptitude search '?narrow(?installed, !?origin(Debian))!?obsolete')"
          ret=$(($ret+1))
        fi
      done
      
    fi
    
  fi
  
  if [ -f /etc/debian_version ] && [ -f /etc/apt/sources.list ] && [ "0" == "$(cat /etc/apt/sources.list | egrep -v '^$|^#' | wc -l)" ]; then
    echo "dss:warn:/etc/apt/sources.list is empty and does not have any valid lines it it."
    ret=$(($ret+1))
  fi
  return $ret
}
function convert_deb_6_stable_repo_to_squeeze() {
if [ ! -f /etc/debian_version ] ; then return 0; fi

if [ ! -f /etc/apt/sources.list  ]; then echo "dss:warn: Odd.  Debian distro but no apt sources.list"; return 1; fi

# cat /etc/debian_version 
# 6.0.4
if ! grep -qai "^6." /etc/debian_version; then return 0; fi

if ! grep -qai "^ *deb.*stable" /etc/apt/sources.list ; then echo "dss:info: Not using 'stable' repo.  Not converting deb6 stable to squeeze"; return 0; fi

prep_ghost_output_dir
cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)

convertfile stable squeeze "debian.org" "" /etc/apt/sources.list
convertfile stable squeeze "debian.net" "" /etc/apt/sources.list
return 0
}

# e.g. convertline squeeze foobar '' '' 'deb-src http://archive.debian.org/debian-security squeeze /updates main contrib non-free'
# => deb-src http://archive.debian.org/debian-security foobar /updates main contrib non-free
function convertline() {
local fromname=$1
local toname=$2
local domlike=$3
local prefix=$4
local line=$5
# ^ *deb[-a-zA-Z]*  => match 'deb ' and 'deb-src '
#  +$fromname[ /-] => needs space first (else stretch/etch get mixed up), space / and - needed for squeeze, squeeze-updates and squeeze/updates
echo $line | egrep -qai "^ *deb[-a-zA-Z]* ([a-zA-Z]+)://([-~a-zA-Z0-9./]*)${domlike}([-~a-zA-Z0-9./]*) +${fromname}[ /-]" && echo $line | sed "s@^ *deb\([-a-zA-Z]*\) \([a-zA-Z]*\)://\([-~a-zA-Z0-9./]*\)\(${domlike}\)\([-~a-zA-Z0-9./]*\) *${fromname}\([ /-]\)@${prefix}deb\1 \2://\3\4\5 ${toname}\6@" && return 0
return 0
}

function convertfile() {
local fromname=$1
local toname=$2
local domlike=$3
# typically '#' to comment out a line
local prefix=$4
local file=$5
# repository like deb ftp://a-b.x.com/~home wheezy blah
sed -i "s@^ *deb\([-a-zA-Z]*\) \([a-zA-Z]*\)://\([-~a-zA-Z0-9./]*\)\($domlike\)\([-~a-zA-Z0-9./]*\) *$fromname\([ /-]\)@${prefix}deb\1 \2://\3\4\5 $toname\6@" "$file"
return 0
}

function islinematch() {
local namematch=$1
local domlike=$2
local line=$4
echo $line | egrep -qai "^ *deb[-a-zA-Z]* ([a-zA-Z]+)://([-~a-zA-Z0-9./]*)${domlike}([-~a-zA-Z0-9./]*) +${namematch}[ /-]" && return 0
return 1
}

function convert_old_ubuntu_repo() {
[ ! -f /etc/apt/sources.list ] && return 0
lsb_release -a 2>/dev/null | grep -qai Ubuntu || return 0
 
CODENAME=$1
if [ -z "$CODENAME" ]; then echo "dss:error: We require a codename here.  e.g. convert_old_ubuntu_repo hardy"; return 1; fi

! egrep -qai "^ *deb.*ubuntu/ $CODENAME|^ *deb.*ubuntu $CODENAME" /etc/apt/sources.list && return 0
grep -qai '^ *deb .*old-releases.ubuntu.com' /etc/apt/sources.list && ! grep -qai "^ *deb.*archive.ub*$CODENAME" /etc/apt/sources.list && if ! grep -qai "^ *deb.*security.ub.*$CODENAME" /etc/apt/sources.list; then echo "dss:info: Already running an 'old-releases' $CODENAME repository."; return 0; fi

prep_ghost_output_dir
cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)

echo "dss:info: Commenting out expired $CODENAME repository"
sed -i "s@^ *deb http://us.archive.ubuntu.com/ubuntu/ $CODENAME@#deb http://us.archive.ubuntu.com/ubuntu/ $CODENAME@" /etc/apt/sources.list
sed -i "s@^ *deb http://security.ubuntu.com/ubuntu $CODENAME@#deb http://security.ubuntu.com/ubuntu $CODENAME@" /etc/apt/sources.list
sed -i "s@^ *deb-src http://security.ubuntu.com/ubuntu $CODENAME@#deb-src http://security.ubuntu.com/ubuntu $CODENAME@" /etc/apt/sources.list
sed -i "s@^ *deb\(.*\)archive\(.*\)$CODENAME@#deb\1archive\2$CODENAME@" /etc/apt/sources.list
if ! grep -ai old-releases /etc/apt/sources.list | grep -qai "$CODENAME" /etc/apt; then
echo "dss: Adding in the 'old-releases' repository for $CODENAME"
echo "
deb http://old-releases.ubuntu.com/ubuntu/ $CODENAME main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ $CODENAME-security main restricted universe multiverse" >> /etc/apt/sources.list
fi

return 0

}

function add_missing_ubuntu_keys() {
  [ ! -e /etc/apt/sources.list ] && return 0
  [ ! -x /usr/bin/apt-key ] && return 0
  print_distro_info | grep -qai ubuntu || return 0
  # import the lts key
  return 0
}

function add_missing_debian_keys() {
  [ ! -e /etc/apt/sources.list ] && return 0
  [ ! -x /usr/bin/apt-key ] && return 0
  print_distro_info | grep -qai debian || return 0
  echo "dss:info: checking debian keys"
  # import the lts key
  # sometimes its like '...AD62 4692 5553' other times its like '...AD6246925553'
  if ! apt-key list | egrep -qai "4692.*5553"; then
    echo "dss:info: installing the deb 7 2020 key"
    if ! gpg --recv-key  8B48AD6246925553 ; then gpg --keyserver pgpkeys.mit.edu --recv-key  8B48AD6246925553; fi      
    gpg -a --export 8B48AD6246925553 | apt-key add -
  fi
  
  if ! apt-key list | egrep -qai "4730.*41FA"; then
    # Debian Archive Automatic Signing Key (6.0/squeeze) <ftpmaster@debian.org>
    echo "dss:info: installing the deb 6 key"
    gpg --recv-key AED4B06F473041FA
    gpg -a --export AED4B06F473041FA | apt-key add -
  fi
  return 0
}

# e.g. test with diff /etc/apt/sources.list <(disable_debian_repos squeeze)
function disable_debian_repos() {
  [ ! -f /etc/apt/sources.list ] && return 0
  local name=$1
  # disable both squeeze and squeeze lts if squeeze
  [ "$name" == "squeeze" ] && disable_debian_repos squeeze-lts
  [ ! -z "$IS_DEBUG" ] && echo "dss:sources:disable_debian_repos:pre:$name: $(cat /etc/apt/sources.list | egrep -v '^$|^#')"
  {
    local line=
    cat /etc/apt/sources.list | while IFS='' read -r line || [[ -n "$line" ]]; do
      # leave comment lines
      local line0=$line
      echo $line | grep -qai '^ *#' && echo $line && continue
      local line2=
      local line2=$(convertline $name $name debian.org "#" "$line")
      [ -z "$line2" ] && line2=$(convertline $name $name debian.net "#" "$line")
      [ -z "$line2" ] && echo $line
      echo $line2
      # leave non-debian lines.  e.g. keep deb http://packages.prosody.im/debian wheezy main
      #echo $line | grep -q deb && echo "$line" | grep -qaiv --fixed-strings '.debian.' && echo $line && continue
      # comment out the old entries
      #line=$(echo $line | sed "s@^ *deb http://ftp.\(\S*\).debian.org/debian[/] $name\([ /]\)@#deb http://ftp.\1.debian.org/debian $name\2@")
      #line=$(echo $line | sed "s@^ *deb http://security.debian.org/ $name\([ /]\)@#deb http://security.debian.org/ $name\1@")
      #line=$(echo $line | sed "s@^ *deb-src http://ftp.\(\S*\).debian.org/debian[/] $name\([ /]\)@#deb-src http://ftp.\1.debian.org/debian $name\2@")
      # deb http://http.us.debian.org/debian/ wheezy main non-free contrib
      #line=$(echo $line | sed "s@^ *deb http://http.\(\S*\).debian.org/debian[/] $name\([ /]\)@#deb http://http.\1.debian.org/debian $name\2@")
      #line=$(echo $line | sed "s@^ *deb http://non-us.debian.org/debian-non-US $name\([ /]\)@#deb http://non-us.debian.org/debian-non-US $name\1@")
      #line=$(echo $line | sed "s@^ *deb http://security.debian.org[/] $name\([ /]\)@#deb http://security.debian.org $name\1@")
      # deb-src http://ftp.us.debian.org/debian/ wheezy main
      # deb-src http://security.debian.org/ wheezy/updates main
      #line=$(echo $line | sed "s@^ *deb-src http://ftp.\(\S*\).debian.org/debian[/] $name\([ /]\)@#deb-src http://ftp.\1.debian.org/debian $name\2@")
      # deb-src http://security.debian.org/ wheezy/updates main
      # deb-src http://mirrors.coyx.com/debian/ wheezy-updates main
      #line=$(echo $line | sed "s@^ *deb http://http.\(\S*\).debian.org/debian[/] $name\([ /]\)@#deb http://http.\1.debian.org/debian $name\2@")
      #line=$(echo $line | sed "s@^ *deb-src http://\([a-zA-Z0-9./]*\) *$name\([ /]\)@#deb-src http://\1 $name\2@")
      # disable the archive repositories
      #line=$(echo $line | sed "s@^ *deb http://archive.\([a-zA-Z0-9./]*\) *$name\([ /]\)@#deb http://archive.\1 $name\2@")
      #echo $line
    done
  } > /etc/apt/sources.list.$$
  [ ! -z "$IS_DEBUG" ] && cat /etc/apt/sources.list.$$ | awk '{print "dss:trace:sources:createdaptsources:" $0}'
  if diff /etc/apt/sources.list /etc/apt/sources.list.$$ >/dev/null; then
    rm /etc/apt/sources.list.$$ 
    return 0
  fi
  [ ! -z "$IS_DEBUG" ] && echo "dss:sources:disable_debian_repos:post:$name: $(cat /etc/apt/sources.list | egrep -v '^$|^#')" 
  prep_ghost_output_dir
  cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)
  echo "dss:info: disable_debian_repos $name diff follows:"
  print_minimal_config_diff /etc/apt/sources.list /etc/apt/sources.list.$$ | awk '{print "dss:configdiff: " $1}'
  mv /etc/apt/sources.list.$$ /etc/apt/sources.list
  echo "$name: apt sources now has $(cat /etc/apt/sources.list | egrep -v '^$|^#')" | awk '{print "dss:sources:disable_debian_repos:post:" $0}'
  return 0
}

# e.g. enable_debian_archive squeeze squeeze-lts
function enable_debian_archive() {
  [ ! -f /etc/apt/sources.list ] && return 0
  [ ! -z "$IS_DEBUG" ] && echo "apt sources now has $(cat /etc/apt/sources.list | egrep -v '^$|^#')" | awk '{print "dss:trace:sources:enable_debian_archive:pre:" $0 }'
  {
    > /tmp/enablearchive.$$
    > /tmp/enabledarchive.$$
    # variables in here not seen outside scope.  need to store in a temp file.
    local line=
    cat /etc/apt/sources.list | while IFS='' read -r line || [[ -n "$line" ]]; do
      local name=
      for name in $DEBIAN_ARCHIVE; do
        # comment line.  skip checking other names.  go onto next line
        local line0=$line
        local name0=$name
        echo $line | egrep -qai '^$|^ *#' && echo $line && line="" && break

        echo $line | grep -qai "^deb http://archive.debian.org/debian ${name}[ /-]" && echo " $name " >> /tmp/enabledarchive.$$ && break
        # disable srcs
        echo $line | egrep -qai "^ *deb-src ([a-z]+)://([-~a-zA-Z0-9./]*) * ${name}[ /-]" && echo $line | sed "s@^ *deb-src \([a-zA-Z]*\)://\([a-zA-Z0-9./]*\) *$name@#deb-src \1://\2 $name@" && line="" && break
        echo $line | egrep -qai "^ *deb ([a-z]+)://([-~a-zA-Z0-9./]*) * ${name}[ /-]" && echo " $name " >> /tmp/enablearchive.$$ && echo "#$line" && line="" && break
      done
      [ ! -z "$line" ] && echo $line
    done
    # if one or the other is enable, add both
    enablearchive=$(cat /tmp/enablearchive.$$)
    enabledarchive=$(cat /tmp/enabledarchive.$$)
    rm -f /tmp/enablearchive.$$ /tmp/enabledarchive.$$
    echo $enablearchive | grep -qai " squeeze " && enablearchive="$enablearchive squeeze-lts"
    uniqueenablearchive=$(for i in $enablearchive; do echo $i; done | sort | uniq)
    spaceenablearchive=$(for i in $uniqueenablearchive; do echo -n " $i "; done)
    for name in $spaceenablearchive; do
      # already there
      echo "$enabledarchive" | grep -qai "$name" && continue 
      echo "deb http://archive.debian.org/debian $name main contrib non-free"
    done
  } > /etc/apt/sources.list.$$
  if diff /etc/apt/sources.list /etc/apt/sources.list.$$ >/dev/null; then
    rm /etc/apt/sources.list.$$ 
    return 0
  fi 
  prep_ghost_output_dir
  cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)
  echo "dss:info: enabling debian archive repos.  diff follows:"
  print_minimal_config_diff /etc/apt/sources.list /etc/apt/sources.list.$$ | awk '{print "dss:configdiff:sources: " $1}'
  mv /etc/apt/sources.list.$$ /etc/apt/sources.list
  [ ! -z "$IS_DEBUG" ] && echo "apt sources now has $(cat /etc/apt/sources.list | egrep -v '^$|^#')" | awk '{print "dss:trace:sources:enable_debian_archive:post:" $0 }'
  return 0
}

function print_uninstall_dovecot() {
  [ ! -f /etc/apt/sources.list ] && return 0
  ! dpkg -l | grep -qai '^i.*dovecot' && return 0
  # trusty 2.9, precise 2.0, lucid (=10.4) 1.29 per https://launchpad.net/ubuntu/+source/dovecot
  echo "dss:info: Seeing '$( [ -f /var/log/mail.info ] && grep 'dovecot' /var/log/mail.info* | grep -c 'Login:')' logins via imap recently."
  echo "dss:info: Changes to the dovecot configs mean that this script will likely hit problems when doing the dist upgrade.  so aborting before starting." >&2
  echo "dss:info: Saving the current dovecot config to /root/distrorejuveinfo/postconf.log.$$"
  echo "dss:info: Please remove dovecot.  You may do that with the following commands:"
  prep_ghost_output_dir
  postconf -n > /root/distrorejuveinfo/postconf.log.$$
  echo apt-get -y remove $(dpkg -l | grep dovecot | egrep -i 'ii|iF|iU' | awk '{print $2}')
  # dovecot reinstall tips
  
  # apt-get install dovecot-pop3d dovecot-imapd dovecot-managesieved dovecot-sieve
  # dovecot -n > /etc/dovecot/dovecot.conf.new
  # mv /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.predistupgrade
  # mv /etc/dovecot/dovecot.conf.new /etc/dovecot/dovecot.conf
  
  # sed -i s@'mailbox_command = /usr/lib/dovecot/deliver -c /etc/dovecot/conf.d/01-dovecot-postfix.conf -m "${EXTENSION}"'@'mailbox_command = /usr/lib/dovecot/deliver -c /etc/dovecot/dovecot.conf -m "${EXTENSION}"'@g main.cf
  
  # Could also try removing /etc/dovecot/conf.d/01-dovecot-postfix.conf and replacing it with this package (replaces postfix-dovecot package):
  
  # http://packages.ubuntu.com/trusty/all/mail-stack-delivery/filelist
  
  #doveconf: Warning: NOTE: You can get a new clean config file with: doveconf -n > dovecot-new.conf
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:25: 'imaps' protocol is no longer necessary, remove it
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:25: 'pop3s' protocol is no longer necessary, remove it
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:717: protocol managesieve {} has been replaced by protocol sieve { }
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:889: add auth_ prefix to all settings inside auth {} and remove the auth {} section completely
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:927: passdb pam {} has been replaced by passdb { driver=pam }
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:1040: userdb passwd {} has been replaced by userdb { driver=passwd }
  #doveconf: Warning: Obsolete setting in /etc/dovecot/dovecot.conf:1102: auth_user has been replaced by service auth { user }
  #doveconf: Fatal: Error in configuration file /etc/dovecot/dovecot.conf: ssl enabled, but ssl_cert not set
  #Stopping IMAP/POP3 mail server: dovecot.
  #Processing triggers for man-db ...
  #Errors were encountered while processing:
  # dovecot-sieve
  # dovecot-pop3d
  # dovecot-ldap
  # dovecot-imapd
  #E: Sub-process /usr/bin/dpkg returned an error code (1)
  
  
  return 0
}

function print_failed_dist_upgrade_tips() {
  echo "dss:warn: In the event of a dist-upgrade failure, try things like commenting out the new distro, uncomment the previous distro, try an apt-get -f install, then change the distros back."
  echo "dss:warn: In the event of dovecot errors, apt-get remove dovecot* unless you need dovecot (e.g. you need imap/pop3)"
  echo "dss:warn: May be worth trying: aptitude -vv full-upgrade" 
  echo "dss:warn: after attempting a fix manually, rerun the bash distrorejuve.sh  command"
}

function dist_upgrade_lenny_to_squeeze() {
export old_distro=lenny
export old_ver="inux 5"
export new_distro=wheezy
export new_ver="inux 6"

dist_upgrade_x_to_y
ret=$?
return $ret
}

function dist_upgrade_squeeze_to_wheezy() {
export old_distro=squeeze
export old_ver="inux 6"
export new_distro=wheezy
export new_ver="inux 7"

dist_upgrade_x_to_y
ret=$?
return $ret
}

function dist_upgrade_wheezy_to_jessie() {
export old_distro=wheezy
export old_ver="inux 7"
export new_distro=jessie
export new_ver="inux 8"
dist_upgrade_x_to_y
ret=$?
return $ret
}

function dist_upgrade_jessie_to_stretch() {
export old_distro=jessie
export old_ver="inux 8"
export new_distro=stretch
export new_ver="inux 9"
dist_upgrade_x_to_y
ret=$?
return $ret
}

# return 0 if a file or two was removed.  e.g. so you can to rm_overwrite_files $tmplog && retry
function rm_overwrite_files() {
   [  -z "$1" ] && return 1
   [  ! -f "$1" ] && return 1
   local tmplog="$1"
   
   
  if egrep -qi "doveconf: Fatal: " "$tmplog"; then
    # e.g. doveconf: Fatal: Error in configuration file /etc/dovecot/dovecot.conf: ssl enabled, but ssl_cert not set
    echo "dss:error: issue with dovecot config.  Resolve (e.g. by removing dovecot for fixing the issue). $(egrep -i "doveconf: Fatal: " "$tmplog")"
    print_uninstall_dovecot
  elif egrep -qi "doveconf: Warning: Obsolete setting in" "$tmplog"; then
    echo "dss:warn: issue with obsolete dovecot config.  $(egrep -i "doveconf: Fatal: " "$tmplog")"
    echo "dss:warn: May pay to remove dovecot per the instructions below."
    print_uninstall_dovecot
  fi
  
  #  trying to overwrite shared '/usr/share/doc/libkmod2/changelog.Debian.gz', which is different from other instances of package libkmod2:amd64
  # Unpacking libpython2.7-minimal:amd64 (2.7.12-1ubuntu0~16.04.3) ...
  # dpkg: error processing archive /var/cache/apt/archives/libpython2.7-minimal_2.7.12-1ubuntu0~16.04.3_amd64.deb (--install):
  # trying to overwrite shared '/etc/python2.7/sitecustomize.py', which is different from other instances of package libpython2.7-minimal:amd64
  
   # egrep -qai "trying to overwrite shared '/usr/share/doc/libperl5.22/changelog.Debian.gz" "$tmplog" && echo "dss:info: handling libperl issue." && rm -f /usr/share/doc/libperl5.22/changelog.Debian.gz 
  local overwrites="$(grep "trying to overwrite shared '/usr/share/doc/.*/changelog.Debian.gz'" $tmplog | sed 's#.*trying to overwrite shared .##g' | sed 's#., which is different from other instances of package.*##g')"
  overwrites="$overwrites $(grep "trying to overwrite shared '/.*.py'" $tmplog | sed 's#.*trying to overwrite shared .##g' | sed 's#., which is different from other instances of package.*##g')"
  overwrites="$overwrites $(grep "trying to overwrite shared '/.*.conf'" $tmplog | sed 's#.*trying to overwrite shared .##g' | sed 's#., which is different from other instances of package.*##g')"
  local i=
  local rmed=0
  for i in $overwrites; do
    [  ! -f "$i" ] && echo "dss:warn: expecting $i to be a file in rm_overwrite_files" && continue
    rm -f "$i"
    echo "dss:info: removed a shared overwrite file.  sometimes required when cross grading: $i"
    rmed=$((rmed+1)) 
  done
  [  $rmed -eq 0 ] && return 1
  return 0
}

function apt_get_remove() {
  local tmplog=$(mktemp "tmplog.aptgetremove.XXXXXX.log")
  apt-get $APT_GET_INSTALL_OPTIONS remove $@ | tee $tmplog
  local ret=${PIPESTATUS[0]}
  [  $ret -ne 0 ] && rm_overwrite_files "$tmplog" && apt-get $APT_GET_INSTALL_OPTIONS remove $@ && ret=$?
  [  $ret -ne 0 ] && echo "$@" | egrep -qai 'gcc-6-base:i386' && egrep -qai 'systemd : Depends: libcap2-bin' && echo "dss:info: attempting to install libcap2-bin since gcc-6-base remove failed." && apt_get_install libcap2-bin:amd64 && apt-get $APT_GET_INSTALL_OPTIONS remove $@ && ret=$? 
  rm -rf "$tmplog"
  return $ret
}

function apt_get_install() {
  local tmplog=$(mktemp "tmplog.aptgetinstall.XXXXXX.log")
  apt-get $APT_GET_INSTALL_OPTIONS install $@ | tee $tmplog
  local ret=${PIPESTATUS[0]}
  [  $ret -ne 0 ] && rm_overwrite_files "$tmplog" && apt-get $APT_GET_INSTALL_OPTIONS install $@ && ret=$?
  rm -rf "$tmplog"
  return $ret
}

function apt_get_f_install() {
  local tmplog=$(mktemp "tmplog.aptgetfinstall.XXXXXX.log")
  apt-get $APT_GET_INSTALL_OPTIONS -f install | tee $tmplog
  local ret=${PIPESTATUS[0]}
  if [  $ret -ne 0 ]; then 
    rm_overwrite_files "$tmplog" && apt-get $APT_GET_INSTALL_OPTIONS -f install && ret=$?
  fi
  rm -rf "$tmplog"
  return $ret
}

function dpkg_install() {
  [  -z "$1" ] && return 0
  local tmplog=$(mktemp "tmplog.dpkginstall.XXXXXX.log")
  dpkg --force-confnew --force-confdef --force-confmiss --install $@ 2>&1 | tee "$tmplog"
  ret=${PIPESTATUS[0]}
  if [  $ret -eq 0 ]; then
    # dpkg: error processing archive /var/cache/apt/archives/bash_4.4-5_amd64.deb (--install):
    # pre-dependency problem - not installing bash
    # Errors were encountered while processing:
    # /var/cache/apt/archives/bash_4.4-5_amd64.deb
    
    # Errors were encountered while processing:
    # gcj-6-jre-lib
    # openjdk-8-jre-headless:amd64
    # postfix
    # dss:warn: dpkg install lied about the return code(#2).  will need to retry the install.
    
    egrep -qai 'Errors |pre-dependency problem|dpkg: error' "$tmplog" && ret=1 && echo "dss:warn: dpkg install lied about the return code.  will need to retry the install."
    # maybe it never lied?  Changed from ret=$? to ret=${PIPESTATUS[0]} because of the pipe to tee
    
  fi
  # https://bugs.launchpad.net/ubuntu/+source/perl/+bug/1574351
  # dpkg: error processing archive libperl5.22_5.22.1-9ubuntu0.2_amd64.deb (--install):
  # trying to overwrite shared '/usr/share/doc/libperl5.22/changelog.Debian.gz', which is different from other instances of package libperl5.22:amd64
  
  [  $ret -ne 0 ] && rm_overwrite_files "$tmplog"  
  if [ $ret -ne 0 ]; then
    # first dpkg --install fails.  second one should work ok.  e.g.:
    # Errors were encountered while processing:
     # /var/cache/apt/archives/dpkg_1.18.24_amd64.deb
     # /var/cache/apt/archives/tar_1.29b-1.1_amd64.deb
    local failedinstalls=$(cat "$tmplog" | grep --after-context 50 'Errors were encountered while processing:' | sed 's/.*Errors were encountered while processing://' | grep '.deb')
    if [  ! -z "$failedinstalls" ]; then
      echo "dss:trace:dpkg_install: some .deb packages had issues.  retrying those: $failedinstalls"
      dpkg --force-confnew --force-confdef --force-confmiss --install $failedinstalls
      ret=$?
    fi
  fi
  if [ $ret -ne 0 ]; then
    echo "dss:trace:dpkg_install: some .deb packages had issues.  retrying to install all packages." 
    dpkg --force-confnew --force-confdef --force-confmiss --install $@  2>&1 | tee "$tmplog"
    ret=$?
    if [  $ret -eq 0 ]; then
      egrep -qai 'Errors |pre-dependency problem|dpkg: error' "$tmplog" && ret=1 && echo "dss:warn: dpkg install lied about the return code(#2).  will need to retry the install."  
    fi
  fi
  [  -f "$tmplog" ] && rm -f "$tmplog"
  return $ret
}

function crossgrade_debian() {
  [  ! -f /etc/debian_version ] && echo "dss:info: Only debian and Ubuntu crossgrades are supported, but not $(print_distro_info)." && return 1
  
  # see https://wiki.debian.org/CrossGrading
  ! uname -a | grep -qai x86_64 && echo "dss:error: Not running a 64 bit kernel. Cannot crossgrade." 2>&1 && return 1

  local bittedness=$(getconf LONG_BIT)
  if echo $bittedness | grep -qai 64; then
    echo "dss:info: FYI getconf reports 64 bits."
    #[ $(dpkg -l | grep '^ii ' | grep ':i386' | wc -l ) -gt 0 ] && echo "i386 packages on this server (may need tidying up): $(dpkg -l | grep '^ii ' | grep ':i386')"
    #return 0
    # may be part way through.  may still be 386 packages.  so carry on with the cross grade.
  fi
  local now=$(date +%s)

  #(Reading database ... 42551 files and directories currently installed.)
  #Removing wpasupplicant (2.4-0ubuntu6.2) ...
  #Processing triggers for dbus:amd64 (1.10.6-1ubuntu3.3) ...
  #=> root     11133  0.1  4.4  70196 66740 pts/2    S+   07:12   0:09      \_ apt-get -y -o APT::Get::AllowUnauthenticated=yes -o Acquire::Check-Valid-Until=false -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confmiss install wpasupplicant:amd64
  #root     13076  1.7  0.6  12920 10036 pts/0    Ss+  09:09   0:00          \_ /usr/bin/dpkg --force-confnew --force-confdef --force-confmiss --status-fd 29 --unpack --auto-deconfigure /var/cache/apt/archives/libnl-3-200_3.2.27-1ubuntu0.16.04.1_amd64.deb /var/cache/apt/archives/libnl-genl-3-200_3.2.27-1ubuntu0.16.04.1_amd64.deb /var/cache/apt/archives/libpcsclite1_1.8.14-1ubuntu1.16.04.1_amd64.deb /var/cache/apt/archives/wpasupplicant_2.4-0ubuntu6.2_amd64.deb
  #root     13640  0.0  0.0   2372   636 pts/0    S+   09:09   0:00              \_ /bin/sh /var/lib/dpkg/info/dbus.postinst triggered /etc/dbus-1/system.d /usr/share/dbus-1/system-services
  #root     13641  0.2  0.0  25520  1392 pts/0    S+   09:09   0:00                  \_ dbus-send --print-reply --system --type=method_call --dest=org.freedesktop.DBus / org.freedesktop.DBus.ReloadConfig
  #=> dbus-send non responsive
  #=> kill 13641

  print_distro_info | grep -qai ubuntu && dpkg -l | grep '^ii' | grep wpasupplicant && echo "dss:warn: There have been issues with updates on Ubuntu where the wpasupplicant is installed.  Run apt-get remove wpasupplicant to remove it first." && return 1

  # slightly different config file state name.  e.g. regular upgrade can remove things like dovecot if they were not used.
  # and this different file means they won't get reinstalled by mistake
  [  ! -f /root/distrorejuveinfo/crossgrade.preupgrade.dpkg.$$ ] && record_config_state /root/distrorejuveinfo/crossgrade.preupgrade.dpkg.$$
  [  -f /root/distrorejuveinfo/crossgrade.preupgrade.dpkg.$$ ] && [  ! -f /root/distrorejuveinfo/preupgrade.dpkg.$$ ] && cp /root/distrorejuveinfo/crossgrade.preupgrade.dpkg.$$ /root/distrorejuveinfo/preupgrade.dpkg.$$
  
  echo "dss:trace:Current architecture: $(dpkg --print-architecture)"
  echo "dss:trace:Foreign architectures: $(dpkg --print-foreign-architectures)"
  echo "dss:info: cross grading distro from 32 to 64 bit."
  local vimpkg="$(dpkg -l | grep '^.*ii' | grep -qai vim && echo vim)"
  local apachepkg="$(dpkg -l | grep '^.*ii' | grep -qai apache2-bin && echo apache2-bin)"
  apt_get_update

  [  ! -x /usr/bin/apt-show-versions ] && apt_get_install apt-show-versions
  [  -z "$IGNORECRUFT" ] && has_cruft_packages oldpkg && show_cruft_packages oldpkg && echo "dss:warn:There are some old packages installed.  Best to remove them before proceeding.  Do that by running bash $0 --show-cruft followed by bash $0 --remove-cruft.  Or to ignore that, run export IGNORECRUFT=Y and re-run this command. " && return 1
  
  dpkg --add-architecture amd64
  [ $? -ne 0 ] && echo "dss:error: Failed adding amd64 architecture." 2>&1 && return 1

  # needed to load amd package info.  e.g. on debian.
  apt-get $APT_GET_INSTALL_OPTIONS update
  apt-get $APT_GET_INSTALL_OPTIONS autoremove
  apt-get $APT_GET_INSTALL_OPTIONS upgrade
  apt-get clean

  #if ! dpkg -l | egrep -qai '^ii.*dpkg.*amd64'; then
  if true; then
    echo "dss:trace: cross grading.  grabbing key amd64 deb packages."
    apt-get --reinstall --download-only $APT_GET_INSTALL_OPTIONS install dpkg:amd64 tar:amd64 apt:amd64 apt-utils:amd64
    # error if we append perl-base:amd64 to the line above...
    # and if we don't have perl-base then apt-get -f install has this error: E: Unmet dependencies
    echo "dss:trace: cross grading.  grabbing extra amd64 deb packages."
    apt-get --reinstall --download-only $APT_GET_INSTALL_OPTIONS install perl-base:amd64
    # above will also fail due to dependency hell
    [  $? -ne 0 ] && apt-get download perl-base:amd64
    
    echo "dss:trace: cross grading.  installing key amd64 deb packages: dpkg:amd64 tar:amd64 apt:amd64 perl-base:amd64"
    # something about this removes apache2.  figure out why...
    local debs="$(find /var/cache/apt/archives -name '*_amd64.deb') $(find . -maxdepth 1 -name 'perl-base*_amd64.deb')"
    if [  ! -z "$debs" ]; then 
      dpkg_install $debs
      if [ $? -ne 0 ]; then 
        [ $? -ne 0 ] && echo "dss:error: dpkg install amd64.deb files failed" 2>&1 && return 1
      fi
      [  ! -d /root/distrorejuveinfo/$$ ] && mkdir /root/distrorejuveinfo/$$
      mv $debs /root/distrorejuveinfo/$$
    fi
  fi
  apt-get $APT_GET_INSTALL_OPTIONS autoremove
  echo "dss:trace: cross grading.  force installing to see what amd64 packages need to be installed/fixed."
  local i=0
  for i in 0 1; do
    apt_get_f_install
    ret=$?
    [ $ret -eq 0 ] && break;
    # apt-get -f install=>
    # The following NEW packages will be installed:
    #  dash:i386
    # WARNING: The following essential packages will be removed.
    # This should NOT be done unless you know exactly what you are doing!
    #  dash
    #0 upgraded, 1 newly installed, 1 to remove and 0 not upgraded.
    # remove 'due to stuff' e.g.:
    #   dpkg:amd64 tar:amd64 (due to dpkg:amd64) perl-base:amd64
    
    local essentialtoinstall="$(apt-get $APT_GET_INSTALL_OPTIONS -f install 2>&1 | grep --after-context 50 'WARNING: The following essential packages will be removed.' | grep '^ ' | sed  -r 's/\(due to \S*?\)//g' | tr '\n' ' ')"
    [  -z "$essentialtoinstall" ] && break  
    local i=;
    mkdir -p distrorejuveinfo/$$/essentialdebs
    cd distrorejuveinfo/$$/essentialdebs
    echo "dss:trace: apt-get -f install had errors.  there may be some essential packages not installed.  trying to install 32 and 64 bit versions of: $essentialtoinstall"
    for i in $essentialtoinstall; do
      i=$(echo $i | sed 's/:i386//')
      i=$(echo $i | sed 's/:amd64//') 
      # had been downloading 64 and 32 bit versions.  but installing both (for say perl-base) resulted in dpkg -l listing just the i386 version. 
      #apt-get download $i
      #apt-get download $i:i386
      apt-get download $i:amd64
    done  
    dpkg_install $(find . -name '*.deb')
    cd -
  done    
  apt_get_f_install
  ret=$?
  if [  $ret -ne 0 ]; then
    echo "dss:error: apt-get -f install failed.  we are stuck."
    exit 1
  fi
  apt-get $APT_GET_INSTALL_OPTIONS autoremove
  
  # doesn't seem to achieve much...
  dpkg --get-selections | grep :i386 | sed -e s/:i386/:amd64/ | dpkg --set-selections
  echo "dss:info: cross grading.  force installing of amd64 packages after dpkg --set-selections."
  apt_get_f_install
  if [  $? -ne 0 ]; then
    echo "dss:error: cross grading failed after initial amd64 package installs.  See crossgrade_debian for a few suggestions to resolve manually."
    return 1 
  fi
  apt-get $APT_GET_INSTALL_OPTIONS autoremove
  
  for i in 0; do
    echo "dss:info: cross grading figuring out essential packages."
    local essentialpackages=
    local i386apps="$(dpkg -l | grep '^ii' | grep ':i386' | awk '{print $2}' | sed 's/:i386$//' | grep -v '^lib' )"
    local i386app= 
    for i386app in $i386apps; do 
      apt-cache show $i386app | grep -qai 'Essential: yes' && ! dpkg -l | egrep -qai '^ii.*${i386app}.*amd64' && essentialpackages="$essentialpackages ${i386app}:amd64"
    done
    # => essentialpackages=base-files:amd64 base-passwd:amd64...
    
    [ -z "$essentialpackages" ] && break
    local debs="$(find /var/cache/apt/archives -name '*_amd64.deb')"
    [  ! -d /root/distrorejuveinfo/$$ ] && mkdir /root/distrorejuveinfo/$$
    [  ! -z "$debs" ] && mv $debs /root/distrorejuveinfo/$$
    echo "dss:info: cross grading essential packages to download: $essentialpackages"
    apt-get --download-only $APT_GET_INSTALL_OPTIONS install $essentialpackages
    apt-get --download-only $APT_GET_INSTALL_OPTIONS install init:amd64 
    #apt-get --download-only -y install systemd-sysv:amd64
    apt-get --download-only $APT_GET_INSTALL_OPTIONS install libc-bin:amd64
    echo "dss:trace: cross grading dpkg installing essential packages."
    local debs="$(find /var/cache/apt/archives -name '*_amd64.deb')"
    [  ! -z "$debs" ] && dpkg_install $debs
    ret=$?
    [  ! -z "$debs" ] && mv $debs /root/distrorejuveinfo/$$
    [ $ret -ne 0 ] && echo "dss:error: dpkg install essential amd64.deb files failed" 2>&1 && return 1
  done
  
  # getting a dependency issue on apt-get remove a few things: libpam-modules : PreDepends: libpam-modules-bin (= 1.1.8-3.6)
  # workaround is:
  apt_get_install libpam-modules-bin:amd64
  
  
  # these seem to be uninstalled by something above.
  # now handled by other code
  # [ ! -z "${vimpkg}${apachepkg}" ] && echo "dss:trace: cross grading and installing vim/apache2." && apt-get $APT_GET_INSTALL_OPTIONS install $apachepkg $vimpkg
  
  local i=0
  for i in 0 1; do  
    echo "dss:trace: cross grading and bulk replacing i386 apps with 64 bit versions"
    # for all i386 apps, install the amd64 and remove the i386.  some will fail, that's ok.
    # do
    apt-get $APT_GET_INSTALL_OPTIONS autoremove
     
    local i386toremove="$(dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' | grep -v '^lib' | sed 's/:i386//' | sed 's/$/:i386/' | tr '\n' ' ')"
    # => e.g. apache2-utils:i386 bc:i386 bind9-host:i386...
    local amd64toinstall="$(echo $i386toremove | sed 's/:i386/:amd64/g')"
    # e.g. => apache2-utils:amd64 bc:amd64 bind9-host:amd64
    [  -z "$amd64toinstall" ] && [  -z "$i386toremove" ] && break
    local ret=0   
    apt_get_install $amd64toinstall && apt_get_remove $i386toremove
    [  $? -ne 0 ] && ret=$(($ret+1))    
    echo "dss:trace: cross grading and individually installing 64 bit versions of all i386 packages."
    local pkg=
    local i386toremove="$(dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' | grep -v '^lib' | sed 's/:i386//')"
    # => e.g. apache2-utils bc bind9-host
    for pkg in $i386toremove ; do 
      apt_get_install $pkg:amd64
      local lret=$?
      # fwiw apt-get install $alreadyinstalled returns 0
      [  $lret -eq 0 ] && apt_get_remove $pkg:i386 
      [  $lret -ne 0 ] && ret=$(($ret+1)) && apt_get_f_install
    done
    [  $ret -eq 0 ] && break
  done
    

  apt-get $APT_GET_INSTALL_OPTIONS autoremove
  
  ## apt-show-versions  | grep amd64 | grep 'not installed'
  # acl:amd64 not installed
  # aptitude:amd64 not installed
  # banana not available for architecture amd64
  # tar:amd64/xenial-security 1.28-2.1ubuntu0.1 uptodate
  # tar:i386 not installed
  
  # =>
  # # echo "$available"
  #acl
  #aptitude
  #bsd-mailx
  local loop=
  for loop in 0; do 
    local fromfile="$(find /root/distrorejuveinfo/ /root/deghostinfo/ -mtime -${DAYS_UPGRADE_ONGOING} 2>/dev/null | grep crossgrade)"
    [ ! -z "$fromfile" ] && fromfile="$(ls -1rt $fromfile | head -n 1)"
    [  -z "$fromfile" ] && break
    local uninstalled="$(print_config_state_changes "$fromfile" | grep '^dss:configdiff:statechanges:-installed:' | sed 's/.*installed://' | sed 's/:i386//' | sed 's/:amd64//' | grep -v '^ *$' | grep -v wpasupplicant | tr '\n' ' ')"
    # => e.g. apache2 apache2-bin fontconfig-config fonts-dejavu-core php5-curl php5-gd php5-imap
    # apt-show-versions  ruby:amd64
    # ruby not available for architecture amd64
    # apt-show-versions  ruby
    # ruby:all not installed
    # rubygems-integration: not installed
    # systemd:amd64 not installed
    
    local available=$(apt-show-versions  $uninstalled | grep -v i386 | grep 'not installed' | sed 's/ not installed.*//' | sed 's/:.*$//')
    # => e.g. apache2 apache2-bin fontconfig-config
    # (excludes older packages that were uninstalled.  e.g. php5 on a newer ubuntu/debian)
    local i=
    local toreinstall=
    for i in $uninstalled; do 
      # sometimes packages are removed, but due to being deprecated.  $available will contain only the packages on the current distro
      echo "$available" | egrep -qai "^$i\$" && toreinstall="$toreinstall $i"
    done
    # => e.g. toreinstall=apache2 apache2-bin fontconfig-config fonts-dejavu-core 
    [ ! -z "$toreinstall" ] && echo "dss:info: Will reinstall some packages that have been removed during the crossgrade: $(echo $toreinstall)"
    for i in $toreinstall; do
      apt_get_install $i
    done
  done
  
  has_cruft_packages 32bit && show_cruft_packages
  
  echo "dss:info: Cross grade has complete.  $(has_cruft_packages 32bit && echo 'has some 32 bit packages still (see above)' || echo 'no 32 bit packages remain (good)')"
  
  # sample cleanup/finish up/suggestions:
  
  # bash : Conflicts: bash:i386
  # apt-get download bash; dpkg_install bash*64.deb
  
  #  libpam-modules : PreDepends: libpam-modules-bin (= 1.1.8-3.6) =>
  # apt-get install libpam-modules-bin:amd64
  
  # apt-get -s -o Debug::pkgProblemResolver=yes -f install

  # if "apt-get --download-only install perl-base:amd64" => E: Unmet dependencies. Try 'apt --fix-broken install'
  # try:
  # apt-get download perl-base:amd64
  # dpkg --install perl-base*amd64.deb
  
  #WARNING: The following essential packages will be removed.
  #This should NOT be done unless you know exactly what you are doing!
  # diffutils:i386
  #=>
  # apt-get download diffutils
  # dpkg --install diffutils*amd64.deb
  

  # apt-get install apache2  
  #apt-get install $(dpkg -l | grep '^ii' | grep i386 | awk '{print $2}' | sed 's/:i386$//' | grep -v '^lib')

  # apt-get purge zlib1g:i386
  # remove i386 packages
  # for i in $(dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' | sed 's/:i386//' | grep -v '^lib' ); do apt-get -y remove $i:i386; done
  
  #apt-get install sysvinit-core:amd64
  
  # pkgs installed for older/different distros
  # allpkgs="$(apt-cache pkgnames)"; for i in $(dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' | grep -v '^lib' | sed 's/:i386//'); do echo " $allpkgs " | grep -qai " $i " && continue; echo $i; done
  
  
  # e2fsprogs pre-depends on libcomerr2 (>= 1.42~W
  # =>
  # dpkg_install e2fsprogs_1.42.13-1ubuntu1_amd64.deb  libcomerr2_1.42.13-1ubuntu1_amd64.deb  libss2_1.42.13-1ubuntu1_amd64.deb

  # check 64 bit versions here?
  # dpkg -l | grep libc-bin
  return 0
}

# e.g. has_cruft_packages && show_cruft_packages && reduce_cruft_packages
function has_cruft_packages() { 
   cruft_packages0 has $1
   # returns 0 if cruft packages
   return $?
}
function show_cruft_packages() { 
   cruft_packages0 show $1
   return $?
}

function remove_cruft_packages() {
   cruft_packages0 remove  $1
   return $?
}

# e.g. cruft_packages0 show 32bit
function cruft_packages0() {
  [  ! -f /etc/debian_version ] && return 0
  [  ! -x /usr/bin/apt-show-versions ] && apt-get $APT_GET_INSTALL_OPTIONS install apt-show-versions
  local cruftlog=$(mktemp "cruftpackages.XXXXXX.log")
  [ "$1" = "show" ] && local show="true"
  [ "$1" = "has" ] && local has="true" && local hasold="yes" && local has32bit="true"
  [ "$1" = "remove" ] || [  -z "$1" ]&& local remove="true"
  local oldpkg=true
  local bit32=true
  [ "$2" = "oldpkg" ] && oldpkg=true && bit32=
  [ "$2" = "32bit" ] && bit32=true && oldpkg=
 
  local has_cruft=0
  local commandret=0
  
  # apt-show-versions
  # ruby:i386 not installed
  # openssl-blacklist:all 0.5-3 installed: No available version in archive
  # ruby-did-you-mean:all/stretch 1.0.0-2 uptodate
  
  #echo "dss:trace: cruft show=$show has=$has remove=$remove oldpkg=$oldpgk 32bit=$bit32"
  
  if [  ! -z "$oldpkg" ] && [ -x /usr/bin/apt-show-versions ]  && [  0 -ne $(apt-show-versions | grep 'No available version' | grep -v '^lib' | wc -l) ]; then
    has_cruft=$((has_cruft+1))
    [  ! -z "$show" ] && echo "dss:warn: Applications from non-current distro versions installed: $(apt-show-versions | grep 'No available version' | grep -v '^lib' | awk '{print $1}' | tr '\n' ' ')"
    if [  ! -z "$remove" ]; then 
      local oldpkgstoremove="$(apt-show-versions | grep 'No available version' | grep -v '^lib' | awk '{print $1}' | tr '\n' ' ')"
      # e.g. oldpkgstoremove has mysql-server-5.0:i386 mysql-server-core-5.0:i386
      [  $? -ne 0 ] && commandret=$((commandret+1))
      # /var/log/mysql/error.log:
      # [Warning] Failed to set up SSL because of the following SSL library error: SSL context is not usable without certificate and private key
      # =>
      # mysql_ssl_rsa_setup 
      
      # may also need to add skip-grant-tables to /etc/mysql/my.cnf [mysqld] section
      echo "$oldpkgstoremove" | grep -qai mysql-ser && apt_get_install mysql-server
      apt_get_remove $oldpkgstoremove
      apt-get $APT_GET_INSTALL_OPTIONS autoremove
    fi
  fi
  if [  ! -z "$oldpkg" ] && [ -x /usr/bin/apt-show-versions ]  && [  0 -ne $(apt-show-versions | grep 'No available version' | grep '^lib' | wc -l) ]; then
    has_cruft=$((has_cruft+1))
    [  ! -z "$show" ] && echo "dss:warn: Libraries from non-current distro versions installed: $(apt-show-versions | grep 'No available version' | grep '^lib' | awk '{print $1}' | tr '\n' ' ')"
    if [  ! -z "$remove" ]; then 
      apt_get_remove $(apt-show-versions | grep 'No available version' | grep '^lib' | awk '{print $1}' | tr '\n' ' ')
      [  $? -ne 0 ] && commandret=$((commandret+1))
      apt-get $APT_GET_INSTALL_OPTIONS autoremove
    fi
  fi
  [  ! -z "$bit32" ] && if [ $(getconf LONG_BIT) -eq 64 ]; then
    dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' > "$cruftlog"
    if [  $(cat "$cruftlog" | head | wc -l ) -gt 0 ]; then
      has_cruft=$((has_cruft+1))
      [  ! -z "$show" ] && echo "dss:warn: There are some i386 application packages still installed.  They can be removed by running bash $0 --remove-cruft.  They are: $(grep -v '^lib' "$cruftlog" | tr '\n' ' ') $(grep '^lib' "$cruftlog" | tr '\n' ' ')."
      if [  ! -z "$remove" ]; then

        local loop=0
        for loop in 0; do 
          # dead code.  rely on --to-64bit call to crossgrade to sort this out.
          break;      
          echo "dss:trace: cross grading figuring out essential packages."
          local essentialpackages=; for i in $(dpkg -l | grep '^ii' | grep :i386 | awk '{print $2}' | sed 's/:i386$//' | grep -v '^lib' ); do apt-cache show $i | grep -qai 'Essential: yes' && essentialpackages="$essentialpackages $i:amd64"; done
          echo "dss:trace: cross grading downloading essential packages via download and dpkg_install."
          [  ! -z "$essentialpackages" ] && if apt-get --download-only $APT_GET_INSTALL_OPTIONS install $essentialpackages; then
            dpkg_install /var/cache/apt/archives/*_amd64.deb
            [  ! -d /root/distrorejuveinfo/$$ ] && mkdir /root/distrorejuveinfo/$$
            mv /var/cache/apt/archives/*amd64.deb /root/distrorejuveinfo/$$
            dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' > "$cruftlog"
          else
            echo "dss:trace: cross grading downloading essential packages (after download+install failed) via download and separate install" 
            apt-get $APT_GET_INSTALL_OPTIONS download $essentialpackages
            dpkg_install *_amd64.deb
            [  ! -d /root/distrorejuveinfo/$$ ] && mkdir /root/distrorejuveinfo/$$
            mv /var/cache/apt/archives/*amd64.deb /root/distrorejuveinfo/$$
            dpkg -l | grep 'i386' | grep '^ii' | awk '{print $2}' > "$cruftlog"
          fi
        done
             
        # install 64 versions of the packages if we can.
        echo "dss:trace: bulk installing 64bit versions of installed i386 apps"
        apt_get_install $(grep -v '^lib' "$cruftlog" | sed 's/:i386/:amd64/g' | tr '\n' ' ')
        echo "dss:trace: force install check"
        apt_get_f_install
        echo "dss:trace: individually installing 64bit versions of installed i386 apps"
        for i in $(dpkg -l | grep ':i386' | grep '^ii' | awk '{print $2}' | grep -v '^lib' | sed 's/:i386//'); do apt_get_install $i:amd64 && apt_get_remove $i:i386; done
        echo "dss:trace: force install check"
        apt_get_f_install
        # [  $? -ne 0 ] && commandret=$((commandret+1))
        echo "dss:trace: removing 32 bit libraries"
        apt_get_remove $(grep -v '^lib' "$cruftlog" | sed 's/:i386//' | sed 's/$/:i386/' | tr '\n' ' ' )
        echo "dss:trace: individually removing i386 libraries."
        for i in $(dpkg -l | grep ':i386' | grep '^ii' | awk '{print $2}' | grep 'lib' ); do apt_get_remove $i; done
        apt-get $APT_GET_INSTALL_OPTIONS autoremove
        [  $(dpkg -l | grep ':i386' | grep '^ii' | wc -l) -gt 0 ] && commandret=$((commandret+1)) 
      fi
    fi
  fi
  [  -f "$cruftlog" ] && rm -f "$cruftlog"
  # returns 0 if cruft packages
  [  ! -z "$remove" ] && return $commandret
  if [  ! -z "$has" ]; then [ $has_cruft -gt 0 ] && return 0 || return 1; fi
  [  ! -z "$show" ] && return 0
}
  
function tweak_broken_configs() {
  echo "dss:trace:tweak_broken_configs: tweaking certain broken configs if they exist."
  grep -qai 'Include conf.d'  /etc/apache2/apache2.conf && [ ! -d /etc/apache2/conf.d ] && mkdir /etc/apache2/conf.d
  if [ -x /usr/sbin/apache2ctl ] && [ -f /etc/apache2/apache2.conf ]; then
    if grep -qai '^Include /etc/apache2/conf.d/' /etc/apache2/apache2.conf && [ ! -d /etc/apache2/conf.d ]; then
      replace 'Include /etc/apache2/conf.d/' '#Include /etc/apache2/conf.d/' -- /etc/apache2/apache2.conf
      echo "dss:info: Commenting out Include /etc/apache2/conf.d/ for non-existent directory.  Might be better to use revert to package provided apache config?"
    fi
    if grep -qa '^Include /etc/apache2/httpd.conf' /etc/apache2/apache2.conf && [ ! -f /etc/apache2/httpd.conf ]; then 
      replace "Include /etc/apache2/httpd.conf" "#Include /etc/apache2/httpd.conf" -- /etc/apache2/apache2.conf
      echo "dss:info: Commenting out Include /etc/apache2/httpd.conf for non existent file"
    fi
    if grep -qa '^Include httpd.conf' /etc/apache2/apache2.conf && [ ! -f /etc/apache2/httpd.conf ]; then 
      replace "Include httpd.conf" "#Include httpd.conf" -- /etc/apache2/apache2.conf
      echo "dss:info: Commenting out Include httpd.conf for non existent file"
    fi
    if ! /usr/sbin/apache2ctl -S &> /dev/null && grep -qa '^LockFile ' /etc/apache2/apache2.conf; then
        replace "LockFile" "#LockFile" -- /etc/apache2/apache2.conf
        echo "dss:info: Commented out Lockfile in /etc/apache2/apache2.conf"
    fi
    if [ -f /etc/apache2/mods-available/ssl.conf ] && /usr/sbin/apache2ctl -S 2>&1 | grep -qai "Invalid command 'SSLMutex'"; then
      replace "SSLMutex" "#SSLMutex" -- /etc/apache2/mods-available/ssl.conf
    fi
    if /usr/sbin/apache2ctl -S 2>&1 | grep -qai 'Ignoring deprecated use of DefaultType'; then
      replace "DefaultType" "#DefaultType" -- /etc/apache2/apache2.conf 
      echo "dss:info: Commented out DefaultType in /etc/apache2/apache2.conf"
    fi
  fi 
  # error of sshd[1762]: Missing privilege separation directory: /var/run/sshd
  # => mkdir /var/run/sshd
  while true; do
    # not debian-ish
    if ! which dpkg >/dev/null 2>&1; then break; fi
  
    # mysql server of some version is installed.  done
    if dpkg -l | egrep -qai '^ii.*mysql-server|^ii.*mariadb-server'; then break; fi
    
    # skip if they never had a mysql server installed.  don't skip if they had an rc=removed,configured
    # if they had mysql they'll have something like:
    # rc  mysql-server-5.1                 5.1.73-1   ...
    if ! dpkg -l | grep -qai '^rc.*mysql-server'; then break; fi
    
    # if mysql or maria db something is installed, quit here. 
    # replaced by check above for ii.*mysql-server
    # and otherwise you'd need to be wary of packages like libdbd-mysql;  mysql-commo; libmariadbclient
    # if dpkg -l | egrep -v 'mysql-common|libmariad' | egrep -qai '^ii.*mysql-|^ii.*mariadb'; then break; fi
    
    # no mysql conf dir, quit
    if [ ! -d /etc/mysql ]; then break; fi
    
    echo "dss:info: MySQL appears to have been installed, but no longer present.  This can happen between debian 8 and debian 9.  As mysql is replaced by mariadb.  Attempting to install mysql-server which would pull in mariadb."
    dpkg -l | egrep -i 'mysql|mariadb' | awk '{print "dss:mysqlrelatedpackages:pre:" $0}'
    
    apt_get_install mysql-server
    if [ $? -ne 0 ]; then break; fi
    dpkg -l | egrep -i 'mysql|mariadb' | awk '{print "dss:mysqlrelatedpackages:post:" $0}'
    break
  done
  for i in $(find /etc/cron.* -type f -name 000loaddelay); do
    #old style ifconfig
    ifconfig | grep -qai 'inet addr' && continue
    # not our script
    grep -qai 'random=.*ifconfig.*sed' $i || continue
    echo '#!/bin/bash
# This is to delay cron jobs by up to 10 minutes to relieve host server load.
# needs to parse inet 174.136.11.74  B174.136.11.79  M255.255.255.248 and
# inet addr:174.136.11.74  Bcast:174.136.11.79  Mask:255.255.255.248
declare -i random=$(expr $(ifconfig eth0 | grep -v inet6  | grep  "inet" | head -n 1 | sed -e "s/[^0-9 ]//g" | sed "s/^  *//" |  cut -f 1 -d\ ) % 900)
sleep ${random}
exit 0' > $i
    echo "dss:info: updating load delay script: $i"
  done
  # fix missing udev
  while true; do
    # not debian-ish
    if ! which dpkg >/dev/null 2>&1; then break; fi
  
    # dpkg -l | grep '/dev'
    # ii  makedev                          2.3.1-93                       all          creates device files in /dev
    # rc  udev                             232-25+deb9u1                  i386         /dev/ and hotplug management daemon
    if dpkg -l | grep -qai '^ii.*udev-'; then break; fi
    
    apt_get_install udev
    ret=$?
    echo "dss:info: udev install result $ret $(dpkg -l | grep udev)"
    break 
  done
  return 0
}

function dist_upgrade_x_to_y() {
[ ! -e /etc/apt/sources.list ] && return 0
echo "dss:trace:dist_upgrade_x_to_y:checking:olddistro=$old_distro:oldver=$old_ver:newdistro=$new_distro"

if ! grep -qai "^ *deb.*$old_distro" -- /etc/apt/sources.list; then
  echo "dss:info: Not finding $old_distro in /etc/apt/sources.list.  Skipping $old_distro to $new_distro"
  return 0
fi
if ! lsb_release -a 2>/dev/null| egrep -qai "$old_distro|$old_ver" ; then
  echo "dss:info: Not finding $old_distro or $old_ver in lsb_release output.  Skipping $old_distro to $new_distro"
  return 0
fi

if [ "$old_distro" == "lenny" ]; then
  if dpkg -l | grep -qai '^i.*dovecot'; then
    print_uninstall_dovecot
    return 1
  fi
  add_missing_debian_keys
  [ ! -d "/dev/pts" ] && mkdir /dev/pts && echo "dss:info: created /dev/pts"
fi
  
upgrade_precondition_checks || return $?

echo "dss:trace:dist_upgrade_x_to_y:pre_apt_get_upgrade:old:$old_distro:new:$new_distro"
apt_get_upgrade
local ret=$?
apt-get clean
apt-get $APT_GET_INSTALL_OPTIONS autoremove
if [ $ret -ne 0 ]; then
  echo "dss:error: apt-get upgrade failed.  exiting dist_upgrade_x_to_y:${old_distro}_to_${new_distro}"
  return 1
fi

disable_debian_repos $old_distro

if ! grep -qai "^ *deb.* ${new_distro}[ /-]" /etc/apt/sources.list; then
  echo "deb http://http.us.debian.org/debian/ ${new_distro} main non-free contrib" >> /etc/apt/sources.list
  echo "deb http://security.debian.org/ ${new_distro}/updates main" >> /etc/apt/sources.list
  echo "$old_distro:$new_distro: apt sources now has $(cat /etc/apt/sources.list | egrep -v '^$|^#')" | awk '{print "dss:sources:dist_upgrade_x_to_y:" $0}'
fi

# redo to convert the above to archive where appropriate.  And add lts if appropriate.
enable_debian_archive

echo "dss:trace:dist_upgrade_x_to_y:pre_apt_get_dist_upgrade::olddistro=$old_distro:oldver=$old_ver:newdistro=$new_distro"
apt_get_dist_upgrade
ret=$?
echo "dss:trace:dist_upgrade_x_to_y:post_apt_get_dist_upgrade::olddistro=$old_distro:oldver=$old_ver:newdistro=$new_distro:ret=$ret"

apt-get $APT_GET_INSTALL_OPTIONS  autoremove
if [ $ret -eq 0 ]; then
	if lsb_release -a 2>/dev/null| egrep -qai "${new_distro}|${new_ver:-xxxxx}"; then
	  # dist-upgrade returned ok, and lsb_release thinks we are wheezy
	  echo "dss:info: dist-upgrade from ${old_distro} to ${new_distro} appears to have worked." 
	  return 0; 
	else
	  echo "dss:warn: dist-upgrade from ${old_distro} appears to have failed.  lsb_release does not match '${new_distro}' or '${new_ver:-xxxxx}': $(lsb_release -a)"
	  return 1
	fi
fi
return 1

}

function print_minimal_config() {
  local a=$1
  local b=$2
  [ ! -f $a ] && return 1
  egrep -v '^\s*#|^$' $a
  return 0
}
function print_pkg_to_modified_diff() {
[  ! -d "/root/pkgdiff.$$" ] && mkdir /root/pkgdiff.$$
# get a list of config files in packages that have been changed by the user
local modifiedconfigfiles=$(dpkg-query -W -f='${Conffiles}\n' '*' | grep -v obsolete  | awk 'OFS="  "{print $2,$1}' | LANG=C md5sum -c 2>/dev/null | awk -F': ' '$2 !~ /OK$/{print $1}' | sort)
local modifiedconfigfile
cd /root/pkgdiff.$$
for modifiedconfigfile in $modifiedconfigfiles; do
  # figure out the package name
  # dpkg -S /etc/apache2/mods-available/ssl.conf
  # apache2: /etc/apache2/mods-available/ssl.conf
  local pkg=$(dpkg -S "$modifiedconfigfile" | awk '{print $1}' | sed 's/://')
  [ -z "$pkg" ] && continue
  
  #figure out the filename
  #apt-get --print-uris download apache2
  # 'http://http.us.debian.org/debian/pool/main/a/apache2/apache2_2.4.10-10+deb8u7_i386.deb' apache2_2.4.10-10+deb8u7_i386.deb 207220 SHA256:7974cdeed39312fda20165f4ee8bebc10f51062600a7cd95f4c5cba32f7ae12c
  # note will not return a result if the file is already here (hence the 'hidden' stuff below).
  local debfilename=$(apt-get --print-uris download "$pkg" 2>/dev/null| awk '{print $2}')
  [ -z "$debfilename" ] && continue
  
  # download it if we don't already have it
  if [ ! -f "hidden-${debfilename}" ]; then 
    apt-get download "$pkg" &>/dev/null
    # can fail if apt is not up to date
    [ $? -ne 0 ] && apt_get_update &>/dev/null && apt-get download "$pkg" &>/dev/null
    # extract to local dir
    dpkg -x "$debfilename" .
    mv "$debfilename" "hidden-$debfilename"
  fi
  
  # pop a copy there so we can replace current file if desired
  [ -f "./${modifiedconfigfile}" ] && [ ! -f "${modifiedconfigfile}.dpkg-dist" ] && cp "./${modifiedconfigfile}" "${modifiedconfigfile}.dpkg-dist"
  [ -f "${modifiedconfigfile}.dpkg-dist" ] && echo "dss:modifiedfilereplace:To replace edited file with dist file: mv $modifiedconfigfile $modifiedconfigfile.dpkg-old; mv ${modifiedconfigfile}.dpkg-dist ${modifiedconfigfile}"
  # show a diff
  print_minimal_config_diff "./$modifiedconfigfile" "$modifiedconfigfile" | awk '{print "dss:configdiff:modifiedconfig:'$pkg':'$modifiedconfigfile':" $0}'
done

# cleanup
cd - >/dev/null
rm -rf /root/pkgdiff.$$
return 0 
}

function print_minimal_config_diff() {
  local a=$1
  local b=$2
  [ ! -f $a ] && return 1
  [ ! -f $b ] && return 1
  ta=$(mktemp "$(basename "${a}").XXXXXX")
  tb=$(mktemp "$(basename "${b}").XXXXXX")
  print_minimal_config $a > $ta
  print_minimal_config $b > $tb
  diff --ignore-all-space -u $ta $tb
  ret=$?
  rm -f $ta $tb
  return $ret
}
function print_config_state_changes() {
  prep_ghost_output_dir
  local now=$(date +%s)
  record_config_state /root/distrorejuveinfo/postupgrade.dpkg.$now
  # get oldest/first preupgrade file.  e.g. we may have to rerun this script.  so diff from first run
  local fromfile="${1}"
  if [  -z "$fromfile" ]; then
    fromfile="$(find /root/distrorejuveinfo/ /root/deghostinfo/ -mtime -${DAYS_UPGRADE_ONGOING} 2>/dev/null | grep preupgrade)"
    [  ! -z "$fromfile" ] && fromfile="$(ls -1rt $fromfile | head -n 1)"
  fi 
  [ -z "$fromfile" ] && fromfile=/root/distrorejuveinfo/preupgrade.dpkg.$$
  # no prior changes just yet.
  [  ! -f  "$fromfile" ] && return 0
  echo "dss:info: Config changes to check.  e.g. different processes after upgrade.  e.g. different ports.  e.g. different apache status output.  e.g. changes to dpkg-old/dpkg-dist files.  dpkg-old = your files that were not used.  dpk-dist = distro files that were not used."
  print_minimal_config_diff $fromfile /root/distrorejuveinfo/postupgrade.dpkg.$now | awk '{print "dss:configdiff:statechanges:" $0}'
  
  local files=$(find /etc -type f | egrep '.ucf-old|.ucf-diff|.dpkg-new|.dpkg-old|dpkg-dist|\.rpmnew|.rpmsave' | sort)
  [  -z "$files" ] && echo "dss:info: Looks like the server is using all distro-provided config files (no local overrides).  That makes it easy."
  [ ! -z "$files" ] && echo "dss:info:key: How the distro provided config files differ from what is installed.  Consider what is needed to switch back to the distro provided config files?"
  for file in $files; do
    # defer to the new and improved print_pkg_to_modified_diff function (debian/ubuntu only)
    echo $file | grep -q 'dpkg-dist' && continue 
    # if not rpmnew file, skip
    echo $file | egrep -qv 'dpkg-dist|rpmnew' && continue
    current=$(echo $file | sed 's/\.dpkg-dist$//')
    current=$(echo $file | sed 's/\.rpmnew$//')
    
    # modified file exists?
    [ -z "$current" ] || [ ! -f $current ] && continue
    
    echo "dss:pkgdiff:$current To use the dist file: mv $current $current.dpkg-old; mv $file $current"
    print_minimal_config_diff $file $current | awk '{print "dss:configdiff:pkgconfig:" $0}'
  done
  print_pkg_to_modified_diff
  
  # non .conf site files
  # IncludeOptional sites-enabled/*.conf
  [ -d /etc/apache2/sites-available ] && [ -f /etc/apache2/apache2.conf ] && grep -qai 'Include.*sites-.*conf' /etc/apache2/apache2.conf && local nonconfsitefiles=$(find /etc/apache2/sites-available -type f | egrep -v '\.conf$|dpkg-')
  for file in $nonconfsitefiles; do
    echo "dss:warn: Apache config file '$file' should have a .conf extension: mv $file $file.conf;a2ensite $(basename $file).conf"   
  done 
  return 0  
}

function record_config_state() {
  prep_ghost_output_dir
  local file=$1
  if [ -z "$file" ]; then 
    file="/root/distrorejuveinfo/preupgrade.dpkg.$$"
  fi
  # don't overwrite the preupgrade file
  echo $file | grep -qai preupgrade && [ -f $file ] && return 0
  echo "dss:trace:record_config_state:$file"
  local files=$(find /etc -type f | egrep '.ucf-old|.ucf-diff|.dpkg-new|.dpkg-old|dpkg-dist|\.rpmnew|.rpmsave' | sort)
  > $file
  # conf files
  echo "Date: $(date)" >> $file
  [ ! -z "$files" ] && ls -lrt $files > $file
  echo "Listening ports:" >> $file
  echo "" >> $file
  # listening ports
  # Listen ports: 0.0.0.0:995 dovecot
  netstat -ntpl | grep LISTEN | awk '{print "Listen ports: " $4 " " $7}' | sed 's/ [0-9]*\// /' | sed 's/0.0.0.0:/:::/' | sort -k 4 | uniq >> $file
  echo "Apache vhosts:" >> $file
  echo "" >> $file
  # vhosts 
  [ -x /usr/sbin/apache2ctl ] && /usr/sbin/apache2ctl -S 2>&1 | awk '{print "ApacheStatus: " $0}' >> $file
  echo "" >> $file
  echo "Running processes:" >> $file
  echo "" >> $file
  ps ax | awk '{print "process: " $5 " " $6 " " $7 " " $8 " " $9}' | egrep -v '^process: \[|COMMAND|init' | sort | uniq >> $file
  
  [  -x /usr/bin/dpkg ] && echo "Installed packages:" >> $file && dpkg -l | grep '^ii' | awk '{print $2}' | sed 's/:.*//' | sort | grep -v '^lib' | awk '{ print "installed: " $0 }' >> $file
  return 0
}

function apt_get_update() {
apt-get update
ret=$?
# E: Release file expired, ignoring http://archive.debian.org/debian/dists/squeeze-lts/Release (invalid since 14d 8h 58min 38s)
if [ $ret -ne 0 ]; then apt-get -o Acquire::ForceIPv4=true  -o APT::Get::AllowUnauthenticated=yes -o Acquire::Check-Valid-Until=false  update; ret=$?; fi
return $ret
}

function apt_get_upgrade() {
[ ! -e /etc/apt/sources.list ] && return 0
[ -e /etc/redhat-release ] && return 0
upgrade_precondition_checks || return $?
echo "dss:trace:apt_get_upgrade"

enable_debian_archive
apt_get_update
record_config_state
dpkg --configure -a --force-confnew --force-confdef --force-confmiss
apt-get $APT_GET_INSTALL_OPTIONS autoremove
apt_get_f_install
echo "dss:info: running an apt-get upgrade"
apt-get $APT_GET_INSTALL_OPTIONS upgrade
ret=$?
apt-get $APT_GET_INSTALL_OPTIONS autoremove
apt_get_f_install
if [ $ret -ne 0 ]; then
  echo "dss:info: apt-get upgrade failed.  trying a dist-ugprade..."
  apt-get  $APT_GET_INSTALL_OPTIONS  dist-upgrade
  ret=$?
  if [ $ret -eq 0 ]; then
    echo "dss:info: apt-get dist-upgrade succeeded when a upgrade failed."
    return 0
  else
    echo "dss:info: apt-get upgrade/dist-upgrade failed."
    return 1 
  fi
fi
apt-get clean
return $ret
}

function apt_get_dist_upgrade() {
[ ! -e /etc/apt/sources.list ] && return 0
upgrade_precondition_checks || return $?
echo "dss:trace:apt_get_dist_upgrade:pre_apt_get_upgrade:"
apt_get_upgrade || return 1
echo "dss:trace:apt_get_dist_upgrade"
apt_get_f_install
apt_get_install dpkg
apt-get  $APT_GET_INSTALL_OPTIONS  autoremove
apt-get  $APT_GET_INSTALL_OPTIONS  dist-upgrade
# cope with 'one of those random things'
# E: Could not perform immediate configuration on 'python-minimal'.Please see man 5 apt.conf under APT::Immediate-Configure for details. (2)
if [ $? -ne 0 ] && apt-get  $APT_GET_INSTALL_OPTIONS  dist-upgrade 2>&1 | grep -qai "Could not perform immediate configuration on "; then
  apt-get -f $APT_GET_INSTALL_OPTIONS install libc6-dev
  apt-get dist-upgrade -f -o APT::Immediate-Configure=0 $APT_GET_INSTALL_OPTIONS
fi
[ -e /var/log/syslog ] && [ -e /etc/my/my.cnf ] && if grep "unknown variable 'lc-messages-dir" /var/log/syslog; then
  #lc-messages-dir        = /usr/share/mysql...
  echo "dss: info: commenting out the my.cnf lc-messages-dir directive in case it is causing problems" 
  sed -i "s@^lc-messages-dir\(.*\)@#lc-messages-dir\1@" /etc/my/my.cnf
fi

dpkg --configure -a --force-confnew --force-confdef --force-confmiss
apt-get $APT_GET_INSTALL_OPTIONS autoremove
apt-get -y autoclean
apt-get  $APT_GET_INSTALL_OPTIONS  dist-upgrade
ret=$?
if [ $ret -ne 0 ] ; then
  echo "dss:warn: Got an error after an apt-get dist-upgrade.  trying an apt-get -f install"
  apt_get_f_install
  apt-get  $APT_GET_INSTALL_OPTIONS  dist-upgrade
  ret=$?
  if [ $ret -ne 0 ] ; then
    echo "dss:error: Got an error after an apt-get dist-upgrade"
  fi 
fi
# report -dist or -old file changes
tweak_broken_configs
echo "dss:trace:dist_upgrade completed $(print_distro_info).  ret=$ret"

return $ret
}

# arg1 is the number of distros to upgrade.  default is all/1000.  else you can do 1 to just go up one distro.  lts to lts counts as 1.
function dist_upgrade_ubuntu_to_latest() {
[ ! -e /etc/apt/sources.list ] && return 0
lsb_release -a 2>/dev/null | grep -qai Ubuntu || return 0

if dpkg -l | grep -qai '^i.*dovecot'; then
  print_uninstall_dovecot
  return 1
fi

local NUM_TO_DIST_UPGRADE="${1:-1000}"

upgrade_precondition_checks || return $?
echo "dss:trace:dist_upgrade_ubuntu_to_latest:pre_apt_get_upgrade:"
apt_get_upgrade
local candidates="$ALL_UBUNTU"
for start in $ALL_UBUNTU; do
  [ $NUM_TO_DIST_UPGRADE -lt 1 ] && echo "Stopping after $1 distro version updates as requested" && return 0
  #No LSB modules are available.
  #Distributor ID: Ubuntu
  #Description:  Ubuntu 14.04.4 LTS
  #Release:  14.04
  #Codename: trusty 
  current=$(lsb_release -a 2>/dev/null| grep -i Codename | awk '{print $2}')
  # remove distros prior to us
  candidates="$(echo $candidates | sed "s/$start//")"
  candidates="$(echo $candidates | sed "s/$current//")"
  # keep looping till we find our current distro
  if [ "$current" != "$start" ]; then continue; fi
  # all done
  if [ -z "$candidates" ]; then return 0; fi
  # if we are currently an lts, then we can move from lts to next lts and skip over the non-lts ones
  if echo $LTS_UBUNTU | grep -qai $current; then
    local removed=""
    for remove in $NON_LTS_UBUNTU; do
       removed="$remove $removed"
       candidates="$(echo $candidates | sed "s/$remove//")"
    done
    echo "dss:info: current distro ($current) is an Ubuntu LTS.  Skipping non-LTS versions: $removed; Leaving LTS versions of: $candidates"
  fi 
  # comment out current sources entries
  prep_ghost_output_dir
  local next=$(echo $candidates | awk '{print $1}')
  if [ -z "$next" ]; then
    echo "dss:info: Current Ubuntu distro is $current.  No newer/better distro.  Finished." 
    return 0 
  fi
  cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)
  # comment out package entries
  sed -i "s@^ *deb \(.*\)ubuntu.com\(.*\)@#deb \1ubuntu.com\2@" /etc/apt/sources.list
  # add in new repo names
  echo "dss:info: attempting a dist-upgrade from $current to $next."
  if echo $OLD_RELEASES_UBUNTU | grep -qai $next; then
    echo "deb http://old-releases.ubuntu.com/ubuntu/ $next main restricted universe multiverse" >> /etc/apt/sources.list
    echo "deb http://old-releases.ubuntu.com/ubuntu/ $next-updates main restricted universe multiverse" >> /etc/apt/sources.list
    echo "deb http://old-releases.ubuntu.com/ubuntu/ $next-security main restricted universe multiverse" >> /etc/apt/sources.list    
  else
    echo "deb http://archive.ubuntu.com/ubuntu/ $next main universe" >> /etc/apt/sources.list
    echo "deb http://security.ubuntu.com/ubuntu/ $next-security main universe" >> /etc/apt/sources.list
    echo "deb http://archive.ubuntu.com/ubuntu/ $next-updates main universe" >> /etc/apt/sources.list 
  fi 
  # Old apache version contains 'Include /etc/apache2/httpd.conf'. Can be 'touch'ed to recreate
  [ -d /etc/apache2 ] && [ ! -f /etc/apache2/httpd.conf ] && touch /etc/apache2/httpd.conf
  echo "dss:trace:dist_upgrade_ubuntu_to_latest:pre_apt_get_upgrade:next:$next"
apt_get_dist_upgrade
ret=$?
NUM_TO_DIST_UPGRADE=$((NUM_TO_DIST_UPGRADE-1))
if [ $ret -eq 0 ]; then
  if lsb_release -a 2>/dev/null| grep -qai $next; then
    # dist-upgrade returned ok, and lsb_release thinks we are wheezy
    echo "dss:info: dist-upgrade from $current to $next appears to have worked." 
    continue; 
  fi
  ret=1
else
  echo "dss:warn: dist-upgrade from $current to $next appears to have failed." 
fi
return $ret
done
}

function convert_old_debian_repo() {
echo "dss:trace:convert_old_debian_distro:"
# no apt sources nothing to do
[ ! -f /etc/apt/sources.list ] && return 0
lsb_release -a 2>/dev/null | grep -qai Ubuntu && return 0

#deb http://http.us.debian.org/debian sarge main contrib non-free
#deb http://non-us.debian.org/debian-non-US sarge/non-US main contrib non-free
#deb http://security.debian.org sarge/updates main contrib non-free
# ==>
#deb http://non-us.debian.org/debian-non-US sarge/non-US main contrib non-free
#deb http://security.debian.org sarge/updates main contrib non-free
#deb http://archive.debian.org/debian/ sarge main non-free contrib

local name=
for name in $DEBIAN_ARCHIVE; do 
# no lenny stuff, nothing to do
! grep -qai "^ *deb.*debian.* ${name}[ /-]" /etc/apt/sources.list && continue

# already using archives, all good
if grep -qai "^ *deb http://archive.debian.org/debian/ ${name}[ /-]" /etc/apt/sources.list; then
  echo "dss:info: This is a $name distro, and already has archive.debian in the repository."
  continue
fi

prep_ghost_output_dir
cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)

# comment out the old entries
convertfile $name $name debian.org "#" /etc/apt/sources.list
#sed -i "s@^ *deb http://ftp.\(\S*\).debian.org/debian $name@#deb http://ftp.\1.debian.org/debian $name@" /etc/apt/sources.list
#sed -i "s@^ *deb http://security.debian.org/ $name@#deb http://security.debian.org/ $name@" /etc/apt/sources.list
#sed -i "s@^ *deb-src http://ftp.\(\S*\).debian.org/debian $name main contrib@#deb-src http://ftp.\1.debian.org/debian $name main contrib@" /etc/apt/sources.list
#sed -i "s@^ *deb http://http.\(\S*\).debian.org/debian $name@#deb http://http.\1.debian.org/debian $name@" /etc/apt/sources.list
#sed -i "s@^ *deb http://non-us.debian.org/debian-non-US $name@#deb http://non-us.debian.org/debian-non-US $name@" /etc/apt/sources.list
#sed -i "s@^ *deb http://security.debian.org $name@#deb http://security.debian.org $name@" /etc/apt/sources.list

echo "deb http://archive.debian.org/debian/ ${name} main non-free contrib" >> /etc/apt/sources.list
echo "$name apt sources now has $(cat /etc/apt/sources.list | egrep -v '^$|^#')" | awk '{print "dss:sources:convert_old_debian_repo:" $0}'
done
return 0
}

function print_distro_info() {
if [ -f /etc/redhat-release ]; then
  local foo="dss:distroinfo: REDHAT $(cat /etc/redhat-release)" 
  echo $foo
elif [ -x /usr/bin/lsb_release ] || [ -x /bin/lsb_release ] ; then    
  local foo="dss:distroinfo: $(lsb_release -a 2>/dev/null | grep -i description)" 
  echo $foo
elif [ -f /etc/debian_version ]; then
  local foo="dss:distroinfo: DEBIAN $(cat /etc/debian_version)" 
  echo $foo
else echo "dss:distroinfo: NA"; fi
return 0
}


function fix_missing_lsb_release() {
which lsb_release >/dev/null 2>&1 && return 0
! [ -f /etc/debian_version ] && return 0
echo "dss:info: Missing lsb release command.  trying to install it."
apt_get_update
apt_get_install lsb-release
ret=$?
return $ret
}

function fix_via_apt_install() {
is_fixed && return 0 
if ! which dpkg >/dev/null 2>&1; then 
  # echo "dss:info: dpkg not installed.  Skipping apt-get install"; 
  return 0; 
fi
add_missing_debian_keys
add_missing_ubuntu_keys

if print_distro_info | grep Ubuntu | egrep -qai "$(echo $OLD_RELEASES_UBUNTU | sed 's/ /|/')"; then 
  echo "dss:info: Running an EOL Ubuntu.  Not doing an apt-get install -y libc6.  $(print_distro_info)"
  return 0
fi

if dpkg -s libc6 2>/dev/null | grep -q "Status.*installed" ; then 
  echo "dss:info: Attempting to apt-get install libc6"
  apt_get_update
  ret=$?
  if [ $ret -ne 0 ]; then
    echo "dss:warn: There was an error doing an apt-get update"
  fi
  for distro in $DEBIAN_CURRENT; do 
    if grep -qai "^ *deb.* ${distro}[ /-]" /etc/apt/sources.list && ! grep -qai "^ *deb.*security\.deb.* ${distro}[ /-]" /etc/apt/sources.list; then
       echo "dss:info: adding the $distro security repository to the sources.list"
       cp /etc/apt/sources.list /root/distrorejuveinfo/sources.list.$(date +%Y%m%d.%s)
       echo "deb http://security.debian.org/ $distro/updates main" >> /etc/apt/sources.list
       apt_get_update
    fi
  done
  POLICY=$(apt-cache policy libc6)
  POLICY_INSTALLED=$(echo $POLICY | grep Installed | sed -e   's/.*Installed: \(\S*\).*/\1/')
  POLICY_CANDIDATE=$(echo $POLICY | grep Candidate | sed -e   's/.*Candidate: \(\S*\).*/\1/')
  if [ ! -z "$POLICY_INSTALLED" -a "$POLICY_INSTALLED" == "$POLICY_CANDIDATE" ]; then
    echo "dss:info: apt-cache policy reports the latest libc6 package already installed"
    return 0
  fi
  if [ -d /var/lib/dpkg/updates ] && [ 0 -ne $(find /var/lib/dpkg/updates -type f | wc -l) ]; then
    echo "dss:info: looks like there were some pending updates.  checking if they need configuring before proceeding with the libc6 install"
    dpkg --configure -a --force-confnew --force-confdef --force-confmiss
  fi
  apt_get_install libc6
  ret=$?
  if [ $ret -eq 0 ]; then
  	echo "dss:fixmethod: apt-get install"
  	# if wrong version is installed you can force the version with something like this on squeeze:
  	# apt-get install libc6=2.11.3-4+deb6u4 libc6-i686=2.11.3-4+deb6u4 libc-bin=2.11.3-4+deb6u4 
  	return 0
  fi
  echo "dss:error: Failed doing apt-get -y install libc6"
  prep_ghost_output_dir
  # download isnt an option on some older apts
  apt-get download libc6 2>/dev/null
  ret=$?
  local file=$(find . -name '*.deb' | grep libc6 | head -n 1)
  if [ $ret -ne 0 ] || [ -z "$file" ]; then
  	echo "dss:error: Failed downloading the libc6 package with apt-get download libc6"
  	return 1
  fi
  dpkg -i $file
  ret=$?
  if [ $ret -eq 0 ]; then
  	echo "dss:fixmethod: apt-get download libc6 and dpkg -i"
  	return 0
  fi
  return $ret
fi
echo "dss:warn: libc6 not installed.  Not running apt-get install libc6"
return 0
}

function yum_upgrade() {
  [ ! -f /etc/redhat-release ] && return 0
  yum_enable_rhel4 || return 0
  if ! which yum >/dev/null 2>&1; then echo "dss:info: yum not found."; return 1; fi
  local QOPT=" -q"
  echo "dss:trace:yum_upgrade"
  
  yum --version >/dev/null && ! yum -q --version 2>/dev/null >/dev/null && QOPT=
  yum -y install yum rpm > /dev/null 2>&1

  # handy tools to make life better
  yum $QOPT -y install yum-utils yum-verify

  echo "dss:info: running yum upgrade"
  yum $QOPT -y upgrade
  ret=$?
  return $ret
}

function yum_enable_rhel4() {
[ ! -f /etc/redhat-release ] && return 0
! grep -qai 'release.* 4' /etc/redhat-release && return 0
if which yum >/dev/null 2>&1; then echo "dss:info: yum enabled on a rhel4 distro already."; return 0; fi
echo "dss:info: yum not enabled on $(print_distro_info).  Trying to enable it."
{
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/libxml2-2.6.16-12.6.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/libxml2-python-2.6.16-12.6.i386.rpm

rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/readline-4.3-13.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/python-2.3.4-14.7.el4.i386.rpm

# install all together else dependency issues
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/sqlite-3.3.6-2.i386.rpm http://vault.centos.org/4.9/os/i386/CentOS/RPMS/sqlite-devel-3.3.6-2.i386.rpm http://vault.centos.org/4.9/os/i386/CentOS/RPMS/python-sqlite-1.1.7-1.2.1.i386.rpm

rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/python-elementtree-1.2.6-5.el4.centos.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/sqlite-3.3.6-2.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/python-sqlite-1.1.7-1.2.1.i386.rpm

rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/elfutils-libelf-0.97.1-5.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/elfutils-0.97.1-5.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/popt-1.9.1-32_nonptl.i386.rpm

rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/python-urlgrabber-2.9.8-2.noarch.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/yum-metadata-parser-1.0-8.el4.centos.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/centos-release-4-8.i386.rpm
rpm -Uvh http://vault.centos.org/4.9/os/i386/CentOS/RPMS/yum-2.4.3-4.el4.centos.noarch.rpm
prep_ghost_output_dir
if [ ! -e /root/distrorejuveinfo/CentOS-Base.repo ]; then 
  echo "dss:info: Running cp /etc/yum.repos.d/CentOS-Base.repo /root/distrorejuveinfo/CentOS-Base.repo" 
  cp /etc/yum.repos.d/CentOS-Base.repo /root/distrorejuveinfo/CentOS-Base.repo
fi

wget -nc -O /etc/yum.repos.d/CentOS-Base.repo http://vault.centos.org/4.9/CentOS-Base.repo
}
if which yum >/dev/null 2>&1; then echo "dss:info: yum enabled on a rhel4 distro."; return 0
else echo "dss:info: yum install failed on a rhel4 distro."; return 1 ; fi
return 0
}

function report_unsupported() {
  is_fixed && return 0
  
  [ -f /etc/apt/sources.list ] && [ -f /etc/debian_version ] && if print_distro_info | grep Ubuntu | egrep -qai "$(wordlisttoegreparg $OLD_RELEASES_UBUNTU)"; then 
    echo "dss:warn: Running an end-of-life Ubuntu distro ($(print_distro_info)).  No new package updates available.  dist upgrade to the latest lts"
    return 1
  fi
  # DEBIAN 7.4
  # Debian GNU/Linux 7.9 (n/a) Release: 7.9 Codename: n/a
  # Distributor ID: Debian Description: Debian GNU/Linux 7.2 (wheezy) Release: 7.2 Codename: wheezy

  [ -f /etc/apt/sources.list ] && [ -f /etc/debian_version ] && if print_distro_info | grep -i 'Debian GNU' | egrep -qai "$(wordlisttoegreparg $UNSUPPORTED_DEBIAN)"; then
    # due to etch being unsupported and stretch beinc current
    if ! print_distro_info | grep -i 'Debian GNU' | egrep -qai "$(wordlisttoegreparg $DEBIAN_CURRENT)"; then 
      echo "dss:warn: Running an end-of-life Debian distro ($(print_distro_info)).  No new package updates available.  dist upgrade to the latest lts"
    fi
    return 1
  fi
   
if [ ! -f /etc/redhat-release ]; then return 0; fi
if grep -qai 'Shrike' /etc/redhat-release; then 
  # RH9
  return 0
elif grep -qai 'release.* 7' /etc/redhat-release; then 
  # yum install
  return 0
elif  grep -qai 'release.* 6' /etc/redhat-release; then
  # yum install 
  return 0
elif  grep -qai 'release.* 5' /etc/redhat-release; then
  # yum install 
  return 0
elif  grep -qai 'release.* 4' /etc/redhat-release; then
  # install prebuilt rpm 
  return 0
elif  grep -qai 'release.* 3' /etc/redhat-release; then
  # install prebuilt rpm 
  return 0
elif  grep -qai 'release.* 2' /etc/redhat-release; then 
  true
elif  grep -qai 'release.* 1' /etc/redhat-release; then 
  true
else 
  return 0
fi

# cat /etc/redhat-release 
#Red Hat Enterprise Linux WS release 4 (Nahant)
echo "dss:warn: There is currently no autopatch option for $(print_distro_info).  The distro is likely out of date and no longer supported."
return 1
}

function improve_yum_setup() {
if ! print_distro_info | egrep -i 'redhat|centos' | egrep -qai 'release.* 5|release.* 6|release.* 7' ; then return 0; fi
if rpm -qa 2>&1 | grep -qai rpmdbnextiter ; then
  # e.g. error: rpmdbNextIterator: skipping h#     489 Header V3 RSA/SHA256 Signature, key ID c105b9de: BAD
  echo "dss:info: rpm database errors.  rebuilding the rpm db"
  rpm --rebuilddb
fi
if [ ! -x /usr/bin/yum ] ; then 
  #rpm http://centos5.rimuhosting.com/centos /5 os updates rimuhosting addons extras centosplus
  if [ ! -f /etc/apt/sources.list ]; then
    echo "dss:warn: Cannot do a yum install on this host, yum not installed, no /etc/apt/sources.list either."
    return 1
  fi
  if ! which apt-get >/dev/null 2>&1 ; then 
    echo "dss:warn: Cannot do a yum install on this host, yum not installed, no apt-get either."
  fi
  echo "dss:info: Trying to install yum via apt-get"
  apt-get --force-yes -y install yum
fi
if [ ! -x /usr/bin/yum ] ; then 
  echo "dss:warn: Cannot do a yum install on this host, yum not installed"
  return 1
fi
if [ ! -x /usr/bin/which ]; then
  echo "dss:warn: Which not installed.  Installing that with yum install which."
  yum install -y which
fi

# this file was added by us, but with wrong name (ending in s).
[ -f /etc/yum.repos.d/CentOS-Base.repos ] && [ -f /etc/yum.repos.d/CentOS-Base.repo ] && rm /etc/yum.repos.d/CentOS-Base.repos 
if print_distro_info | egrep -i 'redhat|centos' | egrep -qai 'release.* 5' && [ ! -f /etc/yum.repos.d/CentOS-Base.repo ] && [ -d /etc/yum.repos.d ] ; then
 wget -nc -O /etc/yum.repos.d/CentOS-Base.repo http://downloads.rimuhosting.com/CentOS-Base.repos.v5
fi
return 0
}

function fix_via_yum_install() {
  is_fixed && return 0 
  improve_yum_setup || return 1
  if ! print_distro_info | egrep -i 'redhat|centos' | egrep -qai 'release.* 5|release.* 6|release.* 7' ; then return 0; fi
  echo "dss:info: Doing a centos5-7 fix for $(print_distro_info)"
  yum install -y glibc
  ret=$?
  if [ $ret -ne 0 ]; then
    echo "dss:warn:Error running yum install -y glibc"
  fi
  echo "dss:fixmethod: yum install glibc" 
  return $ret
}


function fix_vuln() {
print_vulnerability_status beforefix
print_libc_versions beforefix || return $?
print_info

if is_fixed ; then 
  echo "dss:info: The server appears to not be vulnerable.  Not doing anything."
  return 0
fi

upgrade_precondition_checks || return $?

# improve apt sources
convert_deb_6_stable_repo_to_squeeze  || return $?
convert_old_debian_repo || return $?

# https://wiki.ubuntu.com/Releases
# lucid server still current?
for distro in $OLD_RELEASES_UBUNTU; do 
  convert_old_ubuntu_repo $distro || return $?
done
enable_debian_archive || return $?

fix_missing_lsb_release


fix_via_apt_install #|| return $?

yum_enable_rhel4 || return $?

fix_via_yum_install || return $?

report_unsupported || return $?
return 0
}

function packages_upgrade() {
upgrade_precondition_checks || return $?

# improve apt sources
convert_deb_6_stable_repo_to_squeeze  || return $?
convert_old_debian_repo || return $?

# https://wiki.ubuntu.com/Releases
# lucid server still current?
for distro in $OLD_RELEASES_UBUNTU; do 
  convert_old_ubuntu_repo $distro || return $?
done
enable_debian_archive || return $?

fix_missing_lsb_release

fix_via_apt_install #|| return $?

yum_enable_rhel4 || return $?

improve_yum_setup || return $?

add_missing_debian_keys || return $?

upgrade_precondition_checks || return $?

echo "dss:trace:packages_upgrade:pre_apt_get_upgrade:"
apt_get_upgrade || return $?

yum_upgrade || return $?

return 0
}

function dist_upgrade_to_latest() {
  echo "dss:trace:dist_upgrade_to_latest"

  packages_upgrade || return $?
  apt_get_dist_upgrade || return $?
  dist_upgrade_lenny_to_squeeze || return $?
  dist_upgrade_squeeze_to_wheezy || return $?
  dist_upgrade_wheezy_to_jessie || return $?
  dist_upgrade_jessie_to_stretch || return $?
  dist_upgrade_ubuntu_to_latest || return $?
  apt_get_dist_upgrade || return $?
}

function print_php5_advice() {
cat<<EOJ
# recent ubuntus have php7.  If your code does not work with that, install 
# php5.x from a ppa repository
apt-get install software-properties-common
add-apt-repository ppa:ondrej/php
apt-get install php5.6 
EOJ
}


ret=0
echo "dss:trace:distrorejuve:main:starting:$(date -u '+%Y-%m-%d %H:%M:%S'):args:$@"
if [ "--usage" = "${ACTION:-$1}" ] ; then
  print_usage
elif [ "--check" = "${ACTION:-$1}" ] || [ -z "${ACTION:-$1}" ] ; then
  print_vulnerability_status beforefix
  print_info
  upgrade_precondition_checks
  report_unsupported
  # set return code
  true
elif [ "--to-wheezy" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_lenny_to_squeeze
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_squeeze_to_wheezy
  [ $? -ne 0 ] && ret=$(($ret+1))
  if [ $ret -eq 0 ] ; then true ; else print_failed_dist_upgrade_tips; false; fi
elif [ "--to-jessie" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_lenny_to_squeeze
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_squeeze_to_wheezy
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_wheezy_to_jessie
  [ $? -ne 0 ] && ret=$(($ret+1))
  if [ $ret -eq 0 ] ; then true ; else print_failed_dist_upgrade_tips; false; fi
elif [ "--to-latest-debian" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_lenny_to_squeeze
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_squeeze_to_wheezy
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_wheezy_to_jessie
  [ $? -ne 0 ] && ret=$(($ret+1))
  dist_upgrade_jessie_to_stretch
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--to-latest-lts" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_ubuntu_to_latest
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--to-next-ubuntu" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_ubuntu_to_latest 1
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--to-squeeze" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_lenny_to_squeeze
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--source" = "${ACTION:-$1}" ] ; then 
  echo "dss: Loading distrorejuve functions"
elif [ "--upgrade" = "${ACTION:-$1}" ] ; then
  print_info
  packages_upgrade
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--dist-upgrade" = "${ACTION:-$1}" ] ; then
  print_info
  dist_upgrade_to_latest
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--dist-update" = "${ACTION:-$1}" ] ; then
  print_info
  yum_upgrade
  [ $? -ne 0 ] && ret=$(($ret+1))
  packages_update
  [ $? -ne 0 ] && ret=$(($ret+1))
  apt_get_dist_upgrade
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
elif [ "--break-eggs" = "${ACTION:-$1}" ] ; then 
  fix_vuln
  if ! is_fixed; then
    dist_upgrade_to_latest
  fi
  print_libc_versions afterfix
  print_config_state_changes
  print_vulnerability_status afterfix
  if [ $ret -eq 0 ] ; then true ; else false; fi
elif [ "--fix-vuln" = "${ACTION:-$1}" ] ; then 
  fix_vuln
  ret=$?
  print_libc_versions afterfix
  print_vulnerability_status afterfix
  if [ $ret -eq 0 ] ; then true ; else false; fi
elif [ "--show-cruft" = "${ACTION:-$1}" ] ; then
  ! has_cruft_packages && echo "No cruft packages (all installed packages from the current distro.  No 32 bit packages on a 64 bit install)." && exit 0
  show_cruft_packages
  echo "To remove those packages, re-run with bash $0 --remove-cruft"
  exit 0   
elif [ "--remove-cruft" = "${ACTION:-$1}" ] ; then
  ! has_cruft_packages && echo "No cruft packages (all installed packages from the current distro.  No 32 bit packages on a 64 bit install).  Nothing to do.  All good." && exit 0
  remove_cruft_packages
  exit $?   
elif [ "--remove-deprecated-packages" = "${ACTION:-$1}" ] ; then
  ! has_cruft_packages oldpkg && echo "No cruft packages (all installed packages from the current distro).  Nothing to do.  All good." && exit 0
  remove_cruft_packages oldpkg
  exit $?   
elif [ "--to-64bit" = "${ACTION:-$1}" ] ; then
  if [  64 -eq $(getconf LONG_BIT) ]; then
    if has_cruft_packages 32bit; then 
      echo "This distro is 64 bit already.  But some 32 bit packages are installed.  Re-running crossgrade."
    else 
      echo "Distro is already 64 bit.  Cannot locate any 32 bit packages.  All good."
      exit 0
    fi 
  fi
  has_cruft_packages oldpkg && [  -z "$IGNORECRUFT" ] && show_cruft_packages && echo "There are some old packages installed.  Best to remove them before proceeding.  Do that by running bash $0 --remove-cruft.  Or to ignore that, run export IGNORECRUFT=Y and re-run this command. " && exit 1
  crossgrade_debian
  [ $? -ne 0 ] && ret=$(($ret+1))
  [ $ret -ne 0 ] && echo "dss:error: dist upgrade failed, see above for any details, tips to follow." && print_failed_dist_upgrade_tips && echo "dss:error: dist upgrade failed.  exiting.  use $0 --show-changes to see changes"
  [ $ret -eq 0 ] && print_config_state_changes && echo "dss:info: no errors."
  exit $ret   
elif [ "--show-changes" = "${ACTION:-$1}" ] ; then
  print_config_state_changes
  exit $ret   
else
  print_usage
fi

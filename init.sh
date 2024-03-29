#!/bin/sh
#=====================================
# | WARNING:                          |
# |______USE AT YOUR OWN RISK!________|
#
# [[SECURITY_System_Encryption_DM-Crypt_with_LUKS]]
#                                 
# Arguments:
#   init script supports the following:
#     standard: 
#       * root=<device>          root device (required).
#       * ro                     mount root read only.
#
#     init specific:       
#      * ikmap=<kmap>[:<font>]      Load kmap and font(optional).
#      * rescue                     Drops you into a minimal shell
#      * ichkpt=<n>                 Interrupts init and drops to shell.
#      * ikey_root=<mode>:<device>:</path/to/file>  
#      
#                      
#        == About key files ==
#        For partitions that are encrypted with a key, you must set 'ikey_root' properly,
#       otherwise you'll be asked for the passphrase.
#       This information is then used to obtain each key file from the specified removable media. 
#
#       <mode>           - defines how the init script shall treat the supplied keyfile(see below). 
#       <device>         - the device that will be assigned to the removable media.
#       </path/to/file>  - full path to file inside the removable media.
#
#       Supported modes:
#       gpg              - indicates keyfile is gpg-protected
#       none             - indicates keyfile is regular file
#
#        == Notes on keys ==
#         o gpg encrypted key file --> o It'll be decrypted and piped into cryptsetup as if it were a passphrase. 
#                                      o Works if and only if you did the same when you luksFormated the partition. 
#                                        If for example, you decrypt the gpg file and then use it as positional
#					 argument to luksFormat or luksAddKey, then it'll fail because the 
#					 new-line character('\n') will not be ignored.
#                                        If you remove the new-line char from the key 
#                                        'cat key | tr -d '\n' > cleanKey' and then use 'cleanKey'
#                                        as the --key-file argument it will work.   
#
#         o regular key file       --> o It'll be passed to cryptsetup as --key-file
#
# 
#        == Kernel parameters example ==
#        o) Partition(s): root -- Key: regular passphrase
#           root=/dev/sda3 ikmap=es-cp850_i686.bin    
#        o) Partition(s): root -- Key: regular keyfile on usb stick
#           root=/dev/sda3 ikey_root=none:/dev/sdb1:/path/to/keyfile
#        o) Partition(s): root -- Key: gpg encrypted key on usb stick
#           root=/dev/sda3 ikey_root=gpg:/dev/sdb1:/path/to/file
#
#	 == Modules == 	
#       If you need to load modules, create the groups you need in /etc/modules/ (inside initramfs / ),
#       each file should be a list of the modules, and each file name denotes the step in the init where
#       they should be loaded.
#       Supported groups:
#                * boot           -  boot time modules loaded but not removed.
#                * remdev         -  modules required to access removable device
#                * gpg            -  modules required to access gpg protected file.
#
#	o The modules should exist on /lib/modules/`uname -r`/ , like in your system.
#       o Your kernel has to support module unloading for rmmod to work.
#
# BUGS/KNOWN ISSUES:
#     (b1) Redirect ugly hotplug messages about usb-stick to /dev/null, it can
#     be very annoying if they happen to appear when user is asked for passphrase.
#     WORKAROUND: sleep 5 in main() before calling do_work() 
#
#     (ki0) The length of init arguments should be reduced.
#     Users with a long kernel parameter list might find init(or the system) not working
#     as expected because some arguments where stripped. 
#     "... The length of complete kernel parameters list is limited, the limit
#     depends on the architecture, and it's defined in include/asm/setup.sh as
#     COMMAND_LINE_SIZE. ..." (kernel doc: kernel-parameters.txt) 
#
#     (ki1) If the same removable device is used for swap and root(99.9% users), it gets mounted twice.
#
#
# ToDo:
#     * lvm support
#     * raid support	
#     * steganography support -- retrieve hidden key(s)
#     * PKCS#11 cryptographic token support
#
# Contact:
#   o) Bugs, critics, feedback, improvements --> reikinio at gmail dot com
#   o) Flames                                --> /dev/null
#
# History: (y/m/d)
# ------------------
# 2006.08.24 - Federico Zagarzazu
#    Fix: call splash_setup() if fbsplash args exist   
# 2006.08.06 - Federico Zagarzazu
#    Released.
# 2006.08.06 - Federico Zagarzazu
#    Fixed: /dev/device-mapper /dev/mapper/control issue 
#           otherwise it fails on my amd64 system
# 2006.08.04 - Federico Zagarzazu
#    Bug fixes, several improvements.
#    Test phase finished.
# 2006.06.20 - Federico Zagarzazu
#    Written.
# 
# Thank you! 
# ---------------------------------------------------------------
# o Alon Bar-Lev [http://en.gentoo-wiki.com/wiki/Linux_Disk_Encryption_Using_LoopAES_And_SmartCards]
#         I stole ideas, general structure and entire functions from his init script.
# o nix
#
# o Andreas Steinmetz [kernel doc: power/swsusp-dmcrypt.txt]
#
#  ___________________________________
# | WARNING:			      |
# |______USE AT YOUR OWN RISK!________|   

# user defined variables
uv_init=/sbin/init           # init to execute after switching to real root
uv_root_mapping=root         # self descriptive
uv_check_env=1               # test if busybox applets exist 

# default values(don't edit)          
gv_root_mode=rw
gv_shell_checkpoint=0

# functions
die()
{
    local lv_msg="$1"
    umount -n /mnt 2>/dev/null
    echo "${lv_msg}"
    echo 
    echo "Dropping you into a minimal shell..."
    exec /bin/sh
}

bin_exist()
{
    [ ! -e "/bin/${1}" ] && [ ! -e "/sbin/${1}" ] && die "Error: ${2} ${1} not found."
}

check_busybox_applets()
{
    if [ ! -e "/etc/applets" ]; then
        echo "Warning: Cannot check if BusyBox's applets exist(/etc/applets missing)"
    else
        for i in `cat /etc/applets`; do
            bin_exist ${i} "BusyBox applet" 
        done
    fi
}

rmmod_group() {
    local lv_group="$1"
    local lv_invert
    local lv_mod

    if [ -f "/etc/modules/${lv_group}" ]; then
        for mod in `cat "/etc/modules/${lv_group}"`; do
            invert="${lv_mod} ${lv_invert}"
        done

        for mod in ${lv_invert}; do
            #
            # There are some modules that cannot
            # be unloaded
            #
            if [ "${lv_mod}" != "unix" ]; then
                rmmod "`echo "${lv_mod}" | sed 's/-/_/g'`"
            fi
        done
    fi
}

modprobe_group() {
    local lv_group="$1"
    local lv_mod

    if [ -f "/etc/modules/${lv_group}" ]; then
        for mod in `cat "/etc/modules/${lv_group}"`; do
            modprobe "${lv_mod}" > /dev/null 2>&1
        done
    fi
}

#killallwait() { # no use for it yet
#    local lv_p="$1"
#   
#    while killall -q -3 "${lv_p}"; do
#        sleep 1
#    done
#}

shell_checkpoint() {
    local lv_level=$1

    if [ "${gv_shell_checkpoint}" -eq "${lv_level}" ]; then
        echo "Checkpoint ${lv_level}" 
        exec /bin/sh
    fi
}

get_key() {
    local lv_mode="${1}"
    local lv_dev="${2}"
    gv_filepath="${3}"
    local lv_devname="`echo "${lv_dev}" | cut -d'/' -f3 | tr -d '0-9'`" # for use with /sys/block/ 
    local lv_filename="`echo "${gv_filepath}" | sed 's/\/.*\///g'`"

    modprobe_group remdev
    # wait for device
    local lv_first_time=1
    while ! mount -n -o ro "${lv_dev}" /mnt 2>/dev/null >/dev/null 
        do
            if [ "${lv_first_time}" != 0 ]; then
                echo "Insert removable device and press Enter."
                read x
                echo "Please wait a few seconds...."
                lv_first_time=0
            else
                [ ! -e "/sys/block/${lv_devname}" ] && echo "Info: /sys/block/${lv_devname} does not exist."
                [ ! -e "${lv_dev}" ] && echo "Info: ${lv_dev} does not exist."
            fi
            sleep 5
        done
    echo "Info: Removable device mounted."
    # check if keyfile exist
    if [ ! -e "/mnt/${gv_filepath}" ]; then
        die "Error: ${gv_filepath} does not exist on ${lv_dev}."
    fi
    # get the key
    case "$lv_mode" in
        gpg)    # key will be piped into cryptsetup as a passphrase in exec_cryptsetup()
          [ "$uv_check_env" -eq 1 ] && bin_exist "gpg" "--"
          gv_key_gpg=1
          ;;
        none)
          gv_key_file="/mnt/${gv_filepath}"
          ;;
        *)
          die "Error: ${lv_mode} is not valid."
        ;; 
    esac
}

exec_cryptsetup() {  # 1 is device, 2 is mapping
    local lv_arg1="create"
    local lv_arg2="${2}"
    local lv_arg3="${1}"

    cryptsetup isLuks "${1}" 2>/dev/null && { lv_arg1="luksOpen"; lv_arg2="${1}"; lv_arg3="${2}"; }

    if [ -n "${gv_key_gpg}" ]; then
        modprobe_group gpg
        # Fixup gpg tty requirement
        mv /dev/tty /dev/tty.org
        cp -a /dev/console /dev/tty
        while [ ! -e "/dev/mapper/${2}" ]
          do
            sleep 2
            gpg --quiet --homedir / --logger-file /dev/null --decrypt /mnt/${gv_filepath} | \
            cryptsetup "${lv_arg1}" "${lv_arg2}" "${lv_arg3}" 2>/dev/null
          done
        rm /dev/tty
        mv /dev/tty.org /dev/tty
        rmmod_group gpg
        umount -n /mnt
        rmmod_group remdev
        gv_key_gpg=
    else
        if [ -n "${gv_key_file}" ]; then
            cryptsetup -d "${gv_key_file}" "${lv_arg1}" "${lv_arg2}" "${lv_arg3}"
            if [ "$?" -ne 0 ]; then
                die "Error: e1 failed to decrypt ${1}."
            fi
            umount -n /mnt
            rmmod_group remdev
            gv_key_file=
        else
            cryptsetup "${lv_arg1}" "${lv_arg2}" "${lv_arg3}"
            if [ "$?" -ne 0 ]; then
                die "Error: e2 failed to decrypt ${1}."
            fi
        fi
    fi
}

do_root_work() {
    [ -n "${gv_root_device}" ] || die "Error: root missing."

    if [ -n "${gv_key_root_mode}" ]; then
        # if 'init_key_root' arg was given
        [ -n "${gv_key_root_device}" ] || die "Error: init_key_root: device field empty."
        [ -n "${gv_key_root_filepath}" ] || die "Error: init_key_root: filepath field empty."

        get_key "${gv_key_root_mode}" "${gv_key_root_device}" "${gv_key_root_filepath}"
    fi
    shell_checkpoint 4
    echo "Partition: root"
    exec_cryptsetup "${gv_root_device}" "${uv_root_mapping}" 
    mount -o "${gv_root_mode}" "/dev/mapper/${uv_root_mapping}" /new-root
    if [ "$?" -ne 0 ]; then
        cryptsetup luksClose "${uv_root_mapping}" 2>/dev/null || cryptsetup remove "${uv_root_mapping}" 
        die "Error: mount root failed, dm-crypt mapping closed."
    fi
    shell_checkpoint 5
}

do_work() {
    # load kmap and font
    if [ -n "${gv_kmap}" ]; then
        if [ -e "/etc/${gv_kmap}" ]; then
            loadkmap < "/etc/${gv_kmap}"
        else
            die "Error: keymap ${gv_kmap} does not exist on /etc"
        fi
        if [ -n "${gv_font}" ]; then
            if [ -e "/etc/${gv_font}" ]; then
                loadfont < "/etc/${gv_font}"
            else
                die "Error: font ${gv_font} does not exist on /etc"
            fi
        fi
    fi
    print_msg
    shell_checkpoint 1
    do_root_work
    do_switch
}

do_switch() {
    # Unmount everything and switch root filesystems for good:
    # exec the real init and begin the real boot process.
    echo > /proc/sys/kernel/hotplug
    echo "Switching / ..."
    sleep 1
    /bin/umount -l /proc
    /bin/umount -l /sys
    /bin/umount -l /dev
    shell_checkpoint 6
    exec switch_root /new-root "${uv_init}"
}

print_msg() {
#    clear
    echo
    cat /etc/msg 2>/dev/null
    echo
}

parse_cmdl_args() {
    local x
    CMDLINE=`cat /proc/cmdline`
    for param in $CMDLINE; do
        case "${param}" in
          rescue)
            gv_shell_checkpoint=1
            ;;
          root=*)
            gv_root_device="`echo "${param}" | cut -d'=' -f2`"
            ;;
          ro)
            gv_root_mode="ro"
            ;;
          ikmap=*)
            gv_kmap="`echo "${param}" | cut -d'=' -f2 | cut -d':' -f1`"
            gv_font="`echo "${param}" | cut -d':' -s -f2`"
            ;;
          ichkpt=*)
            gv_shell_checkpoint=`echo "${param}" | cut -d'=' -f2`
            ;;
          ikey_root=*)
            x="`echo "${param}" | cut -d'=' -f2 | tr ":" " "`"
            gv_key_root_mode="`echo ${x} | cut -d' ' -f1`"
            gv_key_root_device="`echo ${x} | cut -d' ' -s -f2`"
            gv_key_root_filepath="`echo ${x} | cut -d' ' -s -f3`"
            ;;
        esac
    done
}

main() {
    export PATH=/sbin:/bin:/usr/bin
    dmesg -n 1
    umask 0077
    [ ! -d /proc ] && mkdir /proc
    /bin/mount -t proc proc /proc
    # install busybox applets
    /bin/busybox --install -s
    [ "$uv_check_env" -eq 1 ] && check_busybox_applets
    [ "$uv_check_env" -eq 1 ] && bin_exist "cryptsetup" "--"
    [ ! -d /tmp ] && mkdir /tmp
    [ ! -d /mnt ] && mkdir /mnt
    [ ! -d /new-root ] && mkdir /new-root
    /bin/mount -t sysfs sysfs /sys
    parse_cmdl_args
    modprobe_group boot
    # populate /dev from /sys
    /bin/mount -t tmpfs tmpfs /dev
    /sbin/mdev -s
    # handle hotplug events
    echo /sbin/mdev > /proc/sys/kernel/hotplug
    # fix: /dev/device-mapper should be /dev/mapper/control
    # otherwise it fails on my amd64 system(busybox v1.2.1), weird that it works
    # on my laptop(i686, /dev/mapper/control gets created on luksOpen).
    if [ ! -e "/dev/mapper/control" ]; then
        # see: /proc/misc, /sys/class/misc/device-mapper/dev 
        mkdir /dev/mapper && mv /dev/device-mapper /dev/mapper/control
        echo "device-mapper mapper/control issue fixed.." >> /.initlog
    fi
    do_work
}
main
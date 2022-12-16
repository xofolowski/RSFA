#!/bin/bash
################################################################################
#                                                                              #
#    Recipient Specific From Addressing extension for mailcow-dockerized       #
#                                                                              #
# Name:        rsfa-hook.sh                                                    #
# Purpose:     Perform some container customization when container is built    #
# Args:        None                                                            #
#                                                                              #
# Author:      Christoph Bott <rsfa@xof.devroot.de>                            #
# (c) 2022                                                                     #
#                                                                              #
#                                                                              #
# DISCLAIMER: Use at your own risk! This might break your mailcow setup!       #
#                                                                              #
################################################################################

logprint(){
    echo "rsfa-hook.sh: $1"
}

logprint "Adding group 'pffilter'"
# groupadd -g 110 pffilter
addgroup --system pffilter
logprint "Adding user 'pffilter'"
#useradd -g pffilter -u 110 -d /var/spool/postfix/filter -m -s /usr/sbin/nologin pffilter
adduser --system --group  --home /var/spool/postfix/filter --no-create-home pffilter
logprint "Adding alternate config directory directive to /etc/poastfix/main.cf"
echo "alternate_config_directories = /opt/postfix/conf" >> /etc/postfix/main.cf
logprint "Creating required sudoers entry for user pffilter"
echo 'pffilter ALL=(postfix) NOPASSWD:/usr/sbin/postmap -q *' > /etc/sudoers.d/pffilter && chmod 400 /etc/sudoers.d/pffilter
logprint "Creating required directories"
[ -d /var/spool/postfix/filter  ] || mkdir -m 755 /var/spool/postfix/filter
[ -d /var/spool/postfix/scripts  ] || mkdir -m 755 /var/spool/postfix/scripts
chown pffilter:pffilter /var/spool/postfix/filter

# if run for the very first time after RSFA installation, the filter script has to be moved to the spool volume
logprint "Installing filter script rsfa-filter.py"
[ -f /opt/postfix/conf/rsfa-filter.py ] && mv /opt/postfix/conf/rsfa-filter.py /var/spool/postfix/scripts/ && chmod 755 /var/spool/postfix/scripts/rsfa-filter.py

exit 0

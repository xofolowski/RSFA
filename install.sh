#!/bin/bash
################################################################################
#                                                                              #
#    Recipient Specific From Addressing extension for mailcow-dockerized       #
#                                                                              #
# Name:        rsfa-install.sh                                                 #
# Purpose:     install the RSFA extension to mailcow-dockerized                #
# Args:        None                                                            #
#                                                                              #
# Author:      Christoph Bott <rsfa@xof.devroot.de>                            #
# (c) 2022                                                                     #
#                                                                              #
#                                                                              #
# DISCLAIMER: Use at your own risk! This might break your mailcow setup!       #
#                                                                              #
################################################################################

die(){
    echo "$1" >&2
    exit $2
}

logprint(){
    echo "install.sh: $1" >&2
}

. ../mailcow.conf || die "Cannot source mailcow.conf. This script must be run from rsfa directory located in the mailcow:dockerized root directory." 100

postmasterAddr="postmaster@${MAILCOW_HOSTNAME#[^\.]*.}"

modMainCf(){
    logprint "main.cf - changing smtpd_recipient_restrictions"
    sed -i 's/^smtpd_recipient_restrictions =/smtpd_recipient_restrictions_orig =/g' ../data/conf/postfix/main.cf
}

modExtraCf(){
    logprint "extra.cf - Adding RSFA section"
	grep "### BEGIN RSFA ###" ../data/conf/postfix/extra.cf &>/dev/null || cat <<EOF >> ../data/conf/postfix/extra.cf
### BEGIN RSFA ###
rsfa_cleanup_service_name = rsfa_cleanup
rsfa_header_checks = \$smtp_header_checks,pcre:/opt/postfix/conf/rsfa-filter.pcre
smtpd_recipient_restrictions = \$smtpd_recipient_restrictions_orig,
    check_recipient_access pcre:/opt/postfix/conf/prepend_header.pcre
### END RSFA ###
EOF
}

modMasterCf(){
    logprint "master.cf - Adding RSFA transports"
	grep "### BEGIN RSFA ###" ../data/conf/postfix/master.cf &>/dev/null || cat <<EOF >> ../data/conf/postfix/master.cf
### BEGIN RSFA ###
rsfa_cleanup unix n - n - 0 cleanup
    -o header_checks=\$rsfa_header_checks

rsfa-filter unix - n n - 10 pipe
    flags=Rq user=pffilter null_sender=
    argv=/var/spool/postfix/scripts/rsfa-filter.py -f \${sender} -a \${sasl_username} \${recipient}
### END RSFA ###
EOF

    logprint "master.cf - modifying submission transport"
	# modify submission transport in master.cf:
	sed -i '/^submission/,/^[^ ]\+/ s/cleanup_service_name=smtp_sender_cleanup/cleanup_service_name=$rsfa_cleanup_service_name/g' ../data/conf/postfix/master.cf

    logprint "master.cf - modifying SoGo transport"
	# modify SoGo transport in master.cf:
	sed -i '/^588 /,/^[^ ]\+/ s/cleanup_service_name=smtp_sender_cleanup/cleanup_service_name=$rsfa_cleanup_service_name/g' ../data/conf/postfix/master.cf
}

installFiles(){
    logprint "Installing files"
    sed -i 's/!POSTMASTER!/'$postmasterAddr'/g' rsfa-filter.py && cp rsfa-filter.py ../data/conf/postfix/
    cp rsfa-filter.pcre ../data/conf/postfix/
    cp prepend_header.pcre ../data/conf/postfix/
    cp rsfa-hook.sh ../data/hooks/postfix/ && chmod 755 ../data/hooks/postfix/rsfa-hook.sh
}

mkSieve(){
    tmpsieve=$(mktemp)
    if [ -f ../data/conf/dovecot/global_sieve_before ]
    then
	grep "^### BEGIN RSFA ###" ../data/conf/dovecot/global_sieve_before &>/dev/null && return 0
	cp ../data/conf/dovecot/global_sieve_before ../data/conf/dovecot/global_sieve_before.rsfa-bak
        logprint "merging original global_sieve_before with rsfa.sieve"
        # get already defined requirements
        (for req in $(grep '^require' ../data/conf/dovecot/global_sieve_before | sed 's/.*\[\(.*\)\];/\1/g' | tr "," " ")
        do
            echo "$req"
        done
        # add requirements for rsfa.sieve and uniq
	echo  '"editheader"'
	echo '"variables"') | sort -u | tr "\n" "," | sed 's/\(.*\),$/require \[\1\];\n/g'  > $tmpsieve
        grep -v "^require" ../data/conf/dovecot/global_sieve_before >> $tmpsieve
        grep -v "^require" rsfa.sieve >> $tmpsieve
        mv $tmpsieve ../data/conf/dovecot/global_sieve_before
        return 0
    else
        # global_sieve_before does not yet exist
        logprint "creating new global_sieve_before from rsfa.sieve"
        cp rsfa.sieve ../data/conf/dovecot/global_sieve_before
        return 0
    fi
}

# main

cat <<EOF >&2
################################################################################
#                                                                              #
#    Recipient Specific From Addressing extension for mailcow-dockerized       #
#                                                                              #
# Author:      Christoph Bott <rsfa@xof.devroot.de>                            #
# (c) 2022                                                                     #
#                                                                              #
# DISCLAIMER: Use at your own risk! This might break your mailcow setup!       #
#                                                                              #
################################################################################

By continuing, you understand that this setup script will modify your existing
mailcow:dockerized setup and that this might break your setup.
To cancel setup, press ctrl-c. 
EOF

read -p "Press <enter> to continue: " foo

modMainCf
modExtraCf
modMasterCf
installFiles
mkSieve

logprint "Rebuilding postfix container:"
cd ..
docker compose stop postfix-mailcow
docker compose rm -f postfix-mailcow
docker compose up -d postfix-mailcow
logprint "Restarting Dovecot"
docker compose restart dovecot-mailcow


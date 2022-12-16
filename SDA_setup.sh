#!/bin/bash
################################################################################
#                                                                              #
#    Recipient Specific From Addressing extension for mailcow-dockerized       #
#                                                                              #
# Name:        SDA_setup.sh                                                    #
# Purpose:     Setup subdomain addressing for all mailbox users of all domains #
# Args:        None                                                            #
#                                                                              #
# Author:      Christoph Bott <rsfa@xof.devroot.de>                            #
# (c) 2022                                                                     #
#                                                                              #
#                                                                              #
# DISCLAIMER: Use at your own risk! This might break your mailcow setup!       #
#                                                                              #
################################################################################

# default TTL for DNS MX records
TTL=3600

info(){
    echo -e "\033[34m $1 \033[m" >&2 
}

error(){
    echo -e "\033[31m $1 \033[m" >&2
}

ok(){
    echo -e "\033[32m $1 \033[m" >&2
}

die(){
    error "$1" >&2
    exit $2
}

confirm(){
    echo -e "\033[31m"
    cat << EOF
W A R N I N G:

This script will
- retrieve all mailbox names from all domains
- create a new subdomain "mailboxname.domain" for each domain with dots (".") in mailbox names being translated to dashes ("-")
  E.g.:
    Mailboxes:
      + foo@domain.tld
      + john.doe@domain.tld

    Created subdomains:
      + foo.domain.tld
      + john-doe.domain.tld

- create a catch-all alias for the newly created subdomain, pointing to the respective mailbox
  E.g.:
    @john-doe.domain.tld -> john.doe@domain.tld

- copy the DKIM configuration of each subdomain to all of its newly created subdomains

EOF
    echo -e "\033[m"
    read -p "Type 'GO' to continue: " ans
    [ "$ans" == "GO" ] || die "Aborting." 255
}

redis(){
    case "$1" in
        "add")
            [ $# -eq 4 ] || { error "    Redis: Insufficient number of args for command 'add'."; return 1; }
            key="$2"
            field="$3"
            val="$4"
            [ -n "$(docker compose exec redis-mailcow /usr/local/bin/redis-cli hget $key $field </dev/null)" ] && { error "    Redis: Field $field in key $key does already exist."; return 1; } 
            redis set $key $field "$val" && return 0
            return 1
        ;;
        "get")
            [ $# -eq 3 ] || { error "Redis: Insufficient number of args for command 'get'."; return 1; } 
            key="$2"
            field="$3"
            val=$(docker compose exec redis-mailcow /usr/local/bin/redis-cli hget $key $field </dev/null) 
            if [ -z "$val" ]
            then
                error "    Redis: Empty field $field in key $key."
                return 1
            else
                echo $val
                return 0
            fi
        ;;
        "set")
            [ $# -eq 4 ] || { error "    Redis: Insufficient number of args for command 'set'."; return 1; }
            key="$2"
            field="$3"
            val="$4"
            docker compose exec redis-mailcow /usr/local/bin/redis-cli hSet $key $field "$val" </dev/null &>/dev/null
            if [ "$val" == "$(redis get $key $field)" ]
            then
                return 0
            else
                error "    Redis: Failed to set field $field in key $key to value $val"
                return 1
            fi 
        ;;
        *)
            error "    Redis: Undefined command - $1"
            return 1
        ;;
    esac
}


[ $(whoami) == "root" ] || die "Must be run as root." 1

if [ "$1" != "run" ]
then
    [ -f ../mailcow.conf ] || die "Cannot find mailcow.conf. This script must be run from RSFA directory located in the mailcow:dockerized root directory." 1
    confirm
    info "[SDA_setup.sh] - Setting up subdomain addressing for all domains."
    cp $0 ../data/conf/postfix/
    docker compose exec postfix-mailcow /bin/bash -c "/opt/postfix/conf/$(basename $0) run"
    read -p "Press <enter> to proceed with DKIM configuration: " ans
    if [ -f ../data/conf/postfix/sdasetup.dkim ]
    then
        while read d s
        do
            info "  + Copying DKIM config from domain $d to new subdomain $s"
            srcval_pub="$(redis get DKIM_PUB_KEYS $d)" || continue
            srcval_sel="$(redis get DKIM_SELECTORS $d)" && srcval_priv="$(redis get DKIM_PRIV_KEYS $srcval_sel.$d)" || continue
            redis add DKIM_PUB_KEYS $s "$srcval_pub" && ok "    Key DKIM_PUB_KEYS copied successfully"
            redis add DKIM_SELECTORS $s "$srcval_sel" && ok "    Key DKIM_SELECTORS copied successfully"
            redis add DKIM_PRIV_KEYS $srcval_sel.$s "$srcval_priv" && ok "    Key DKIM_PRIV_KEYS copied successfully"
        done < ../data/conf/postfix/sdasetup.dkim
        rm ../data/conf/postfix/sdasetup.dkim
    fi
    info "[SDA_setup.sh] - Finished"
    if [ -f "../data/conf/postfix/sdasetup.dns" ]
    then
        info "You still have to add the following MX records to your DNS zones:"
        cat ../data/conf/postfix/sdasetup.dns
        rm ../data/conf/postfix/sdasetup.dns
    fi
else
    # run script inside the postfix container
    dns="/opt/postfix/conf/sdasetup.dns"
    MX=$(postconf | grep ^myhostname | cut -d" " -f3)
    eval `grep ^password /opt/postfix/conf/sql/mysql_virtual_alias_maps.cf | sed 's/ = /=/g; s/^password/MYSQLPWD/g'`
    MYSQLCMD="mysql -u mailcow --password=$MYSQLPWD -D mailcow -B"
    domains=$(echo "select domain from domain" | $MYSQLCMD | sed '1d')

    for domain in $domains
    do
        info "  + Start processing domain: $domain"
        ulist=$(echo "select username from mailbox where active=\"1\" and domain=\"$domain\"" | $MYSQLCMD | sed '1d;s/@.*$//g;')
        [ "$ulist" == "" ] && ok "    + $domain: No mailboxes in domain - nothing to do."
        for u in $ulist
        do
            info "    + $domain: processing user $u"
            subdom="$(echo $u | tr "." "-").$domain"
            if [ "$(echo "select domain from domain where domain=\"$subdom\"" | $MYSQLCMD | sed '1d')" == "" ]
            then
            # subdomain does not yet exist
                info "      + $domain: creating subdomain $subdom"
                echo "insert into domain (domain,active) VALUES(\"$subdom\",1)" | $MYSQLCMD &>/dev/null && ok "      + Done" || error "      + failed"
                info "      + $domain: creating subdomain alias @$subdom pointing to $u@$domain"
                echo "insert into alias (address, goto, domain, active) VALUES (\"@$subdom\",\”$u@domain\”, \”$domain\”, 1)" | $MSQLCMD &>/dev/null && ok "      + Done" || error "      + failed"
                info "      + $domain: Adding sender ACL to allow $u@$domain to send as *@$subdom"
                echo "insert into sender_acl (logged_in_as, send_as, external) VALUES (\"$u@$domain\",\"@$subdom\",0);" | $MYSQLCMD &>/dev/null && ok "      + Done" || error "      + failed" 
                echo "$subdom. $TTL IN MX $MX." >> $dns
                echo "$domain $subdom" >> /opt/postfix/conf/sdasetup.dkim
            else
            # subdomain already exists
                ok "      + $domain: subdomain $subdom does already exist. Skip."
            fi
        done
        info "  + Finished processing domain: $domain"
    done
    rm "/opt/postfix/conf/$(basename $0)"
    exit 0
fi
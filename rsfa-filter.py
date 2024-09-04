#!/usr/bin/env python3
################################################################################
#                                                                              #
#    Recipient Specific From Addressing extension for mailcow-dockerized       #
#                                                                              #
# Name:        rsfa-filter.py                                                  #
# Purpose:     Perform the actual header rewriting and re-inject mail to       #
#              postfix's queue                                                 #
#                                                                              #
# Args:        see help                                                        #
#                                                                              #
# Author:      Christoph Bott <rsfa@xof.devroot.de>                            #
# (c) 2022                                                                     #
#                                                                              #
#                                                                              #
# DISCLAIMER: Use at your own risk! This might break your mailcow setup!       #
#                                                                              #
################################################################################
import sys
import subprocess
import re
import argparse
from email import message_from_file
from email.mime.multipart import MIMEMultipart
from email.mime.application import MIMEApplication
from email.mime.text import MIMEText
from email.utils import COMMASPACE, formatdate

EX_TEMPFAIL = 75
EX_UNAVAILABLE = 69

POSTMASTER = "!POSTMASTER!"
BOUNCETEMPLATE = """\
!!!!! Unable to send message !!!!!

Based on the subject tags in your original subject,
you requested to rewrite the sender address from %s to %s.
However, based on defined policies, you are not allowed to send mails as
%s, when authenticating as %s.

Please find your original email attached.

"""

def makeBounceMail(bm_from, bm_to, subject, text, bouncemail):
    msg = MIMEMultipart()
    msg['From'] = bm_from
    msg['To'] = bm_to
    msg['Date'] = formatdate(localtime=True)
    msg['Subject'] = subject

    msg.attach(MIMEText(text))

    part = MIMEApplication(bouncemail.as_string(), Name=bouncemail.get('subject') + ".eml")
    part['Content-Disposition'] = 'attachment; filename="%s.eml"' % bouncemail.get('subject')
    msg.attach(part)
    return(msg)

def checkACL(auth, nf):
    ## Search email address in new from header
    m = re.search(r'[^<]*<(?P<addr>[^>]*)>.*',nf)

    CHECKCMD = ['/usr/bin/sudo', '-u', 'postfix', '/usr/sbin/postmap', '-q', m.group('addr').lower(), 'mysql:/opt/postfix/conf/sql/mysql_virtual_sender_acl.cf']
    check_res = subprocess.run(CHECKCMD, capture_output=True).stdout.decode('UTF-8').strip().lower()
    if check_res == auth.lower():
        return(True)
    else:
        print(f'Auth Failure: {check_res} does not match {auth}')
        return(False)

def rewriteHeaders(msg,sender,subj):
    # remove DKIM Signature
    for header in msg._headers:
        if header[0].lower() == "dkim-signature":
            msg._headers.remove(header)
    msg.replace_header("Subject",subj)
    msg.replace_header("From",sender)

    if msg.get("Return-Path") != None:
        msg.replace_header("Return-Path",sender)
    return(msg)

def extractSMTPaddr(text):
    return(re.findall(r"[a-z0-9\.\-+_]+@[a-z0-9\.\-+_]+\.[a-z]+", text))

def main():
    parser = argparse.ArgumentParser(
            prog = "rsfa-filter.py",
            description = "Read a mail msg from stdin, rewrite Header-From based on subject tags and submit it for delivery."
            )
    parser.add_argument('-f', '--from', required=True, dest='sender')
    parser.add_argument('-a', '--auth-user', required=True, dest='authenticated_as')
    parser.add_argument('recipients', nargs='+')
    argv = parser.parse_args()
    msg_in = message_from_file(sys.stdin)

    try:
        re_plusext = re.compile(r'^(?P<subjstart>[^\[]*)\[(?P<ext>.*)\] (?P<subjrest>.*)$')
        re_subdom = re.compile(r'^(?P<subjstart>[^|]*)[|](?P<ext>[^|]+@[^|]+)[|] (?P<subjrest>.*)$')
        subject_in = ''.join(msg_in.get("Subject").splitlines())
        m = re_plusext.search(subject_in)
        sender = msg_in.get("From")
        #sender = argv.sender
        if m != None:
            ## A plus extension tag was found in the subject
            subject = m.group('subjstart') + m.group('subjrest')
            new_from = sender.replace('@','+'+m.group('ext')+'@')
            msg_out = rewriteHeaders(msg_in,new_from,subject)
            sendmail_sender = sender
            sendmail_recipients = " ".join(argv.recipients)
        else:
            m = re_subdom.search(subject_in)
            if m != None:
                ## A subdomain tag was found in the subject
                subject = m.group('subjstart') + m.group('subjrest')
                new_from = re.sub(r'[^< ]+@([^> ]*)',m.group('ext')+r'.\1',sender)
                sendmail_sender = extractSMTPaddr(new_from)[0]
                sendmail_recipients = " ".join(argv.recipients)
                # ACL checks are only required for subdomain addressing
                if checkACL(argv.authenticated_as,new_from):
                    msg_out = rewriteHeaders(msg_in,new_from,subject)
                else:
                    bouncetext = BOUNCETMPL % (sender, new_from, new_from, argv.authenticated_as)
                    msg_out = makeBounceMail("MAILER DAEMON <" + POSTMASTER + ">", sender, "Delivery failed: Unauthorized sender rewrite requested", bouncetext, msg_in)
                    sendmail_sender = POSTMASTER
                    sendmail_recipients = argv.authenticated_as
            else:
                sys.stderr.write("rsfa-filter: [error] found neither subdomain addressing nor plus-extension in original subject.\n")
                sys.exit(EX_UNAVAILABLE)

        SENDMAIL = ["/usr/sbin/sendmail", "-G", "-i", "-C", "/opt/postfix/conf", "-f", sendmail_sender, "--", sendmail_recipients]
        queue_cmd = subprocess.run(SENDMAIL,input=msg_out.as_string(),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        print("rsfa-filter: [info] finished mail processing, handing over to postfix again.")
        print(queue_cmd.stdout)
        sys.exit(queue_cmd.returncode)

    except Exception as err:
        print(f"Unexpected {err=}, {type(err)=}")
        sys.exit(EX_TEMPFAIL)


if __name__ == '__main__':
    main()

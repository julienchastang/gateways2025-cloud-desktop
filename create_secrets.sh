#! /bin/bash

# This script will update the following key/values in values.yaml:
# hub.cookieSecret
# hub.config.SharedPasswordAuthenticator.admin_password
# hub.config.SharedPasswordAuthenticator.user_password
# proxy.secretToken
# ingress.hosts[*]
# ingress.tls.hosts[*]

create_secret () {
	openssl rand -hex $1
}

if [[ -z $INGRESS_HOST ]]
then
	echo "Error, must 'export INGRESS_HOST=<host-name>' before running this script" >&2
	exit 1
fi

sed \
	-e "s/COOKIESECRET/$(create_secret 32)/g" \
	-e "s/ADMINPASSWORD/$(create_secret 8)/g" \
	-e "s/USERPASSWORD/$(create_secret 8)/g" \
	-e "s/PROXYSECRETTOKEN/$(create_secret 32)/g" \
	-e "s/INGRESSHOST/$INGRESS_HOST/g" \
  -i .orig values.yaml

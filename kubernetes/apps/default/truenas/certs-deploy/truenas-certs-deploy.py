#!/usr/bin/env python3

"""
Import and activate a SSL/TLS certificate into FreeNAS 11.1 or later
Uses the FreeNAS API to make the change, so everything's properly saved in the config
database and captured in a backup.

Requires paths to the cert (including the any intermediate CA certs) and private key,
and username, password, and FQDN of your FreeNAS system.

Your private key should only be readable by root, so this script must run with root
privileges.  And, since it contains your root password, this script itself should
only be readable by root.

Source: https://github.com/danb35/deploy-freenas
"""

import argparse
import os
import sys
import json
import requests
import time
import configparser
import socket
from datetime import datetime, timedelta
from urllib3.exceptions import InsecureRequestWarning
requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

API_KEY = os.getenv('CERTS_DEPLOY_API_KEY')

DOMAIN_NAME = socket.gethostname()
TRUENAS_ADDRESS = 'localhost'
VERIFY = False
PRIVATEKEY_PATH = os.getenv('CERTS_DEPLOY_PRIVATE_KEY_PATH')
FULLCHAIN_PATH = os.getenv('CERTS_DEPLOY_FULLCHAIN_PATH')
PROTOCOL = 'http://'
PORT = '80'
FTP_ENABLED = bool(os.getenv('CERTS_DEPLOY_FTP_ENABLED', ''))
S3_ENABLED = bool(os.getenv('CERTS_DEPLOY_S3_ENABLED', ''))
now = datetime.now()
cert = "letsencrypt-%s-%s-%s-%s" %(now.year, now.strftime('%m'), now.strftime('%d'), ''.join(c for c in now.strftime('%X') if
c.isdigit()))


# Set some general request params
session = requests.Session()
session.headers.update({
  'Content-Type': 'application/json'
})
if API_KEY:
  session.headers.update({
    'Authorization': f'Bearer {API_KEY}'
  })
else:
  print ("Unable to authenticate. Specify 'CERTS_DEPLOY_API_KEY' in the os Env.")
  exit(1)
if not PRIVATEKEY_PATH:
  print ("Unable to find private key. Specify 'CERTS_DEPLOY_PRIVATE_KEY_PATH' in the os Env.")
  exit(1)
if not FULLCHAIN_PATH:
  print ("Unable to find private key. Specify 'CERTS_DEPLOY_FULLCHAIN_PATH' in the os Env.")
  exit(1)

# Load cert/key
with open(PRIVATEKEY_PATH, 'r') as file:
  priv_key = file.read()
with open(FULLCHAIN_PATH, 'r') as file:
  full_chain = file.read()

# Update or create certificate
r = session.post(
  PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/certificate/',
  verify=VERIFY,
  data=json.dumps({
    "create_type": "CERTIFICATE_CREATE_IMPORTED",
    "name": cert,
    "certificate": full_chain,
    "privatekey": priv_key,
  })
)

if r.status_code == 200:
  print ("Certificate import successful")
else:
  print ("Error importing certificate!")
  print (r.text)
  sys.exit(1)

# Sleep for a few seconds to let the cert propagate
time.sleep(5)

# Download certificate list
limit = {'limit': 0} # set limit to 0 to disable paging in the event of many certificates
r = session.get(
  PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/certificate/',
  verify=VERIFY,
  params=limit
)

if r.status_code == 200:
  print ("Certificate list successful")
else:
  print ("Error listing certificates!")
  print (r.text)
  sys.exit(1)

# Parse certificate list to find the id that matches our cert name
cert_list = r.json()

new_cert_data = None
for cert_data in cert_list:
  if cert_data['name'] == cert:
    new_cert_data = cert_data
    cert_id = new_cert_data['id']
    break

if not new_cert_data:
  print ("Error searching for newly imported certificate in certificate list.")
  sys.exit(1)

# Set our cert as active
r = session.put(
  PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/system/general/',
  verify=VERIFY,
  data=json.dumps({
    "ui_certificate": cert_id,
  })
)

if r.status_code == 200:
  print ("Setting active certificate successful")
else:
  print ("Error setting active certificate!")
  print (r.text)
  sys.exit(1)

if FTP_ENABLED:
  # Set our cert as active for FTP plugin
  r = session.put(
    PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/ftp/',
    verify=VERIFY,
    data=json.dumps({
      "ssltls_certfile": cert,
    }),
  )

  if r.status_code == 200:
    print ("Setting active FTP certificate successful")
  else:
    print ("Error setting active FTP certificate!")
    print (r.text)
    sys.exit(1)

if S3_ENABLED:
  # Set our cert as active for S3 plugin
  r = session.put(
    PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/s3/',
    verify=VERIFY,
    data=json.dumps({
      "certificate": cert_id,
    }),
  )

  if r.status_code == 200:
    print ("Setting active S3 certificate successful")
  else:
    print ("Error setting active S3 certificate!")
    print (r)
    sys.exit(1)

# Get expired and old certs with same SAN
cert_ids_same_san = set()
cert_ids_expired = set()
for cert_data in cert_list:
  if set(cert_data['san']) == set(new_cert_data['san']):
      cert_ids_same_san.add(cert_data['id'])

  issued_date = datetime.strptime(cert_data['from'], "%c")
  lifetime = timedelta(days=cert_data['lifetime'])
  expiration_date = issued_date + lifetime
  if expiration_date < now:
      cert_ids_expired.add(cert_data['id'])

# Remove new cert_id from lists
if cert_id in cert_ids_expired:
  cert_ids_expired.remove(cert_id)

if cert_id in cert_ids_same_san:
  cert_ids_same_san.remove(cert_id)

# Delete expired and old certificates with same SAN from freenas
for cid in (cert_ids_same_san | cert_ids_expired):
  r = session.delete(
    PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/certificate/id/' + str(cid),
    verify=VERIFY
  )

  for c in cert_list:
    if c['id'] == cid:
      cert_name = c['name']

  if r.status_code == 200:
    print ("Deleting certificate " + cert_name + " successful")
  else:
    print ("Error deleting certificate " + cert_name + "!")
    print (r.text)
    sys.exit(1)

# Reload nginx with new cert
# If everything goes right, the request fails with a ConnectionError
try:
  r = session.post(
    PROTOCOL + TRUENAS_ADDRESS + ':' + PORT + '/api/v2.0/system/general/ui_restart',
    verify=VERIFY
  )

  if r.status_code == 200:
    print ("Reloading WebUI successful")
    print ("deploy_freenas.py executed successfully")
  else:
    print ("Error reloading WebUI!")
    print ("{}: {}".format(r.status_code, r.text))
    sys.exit(1)
except requests.exceptions.ConnectionError:
    print ("Error reloading WebUI!")
    sys.exit(1)

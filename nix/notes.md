## deploy

Steps:

- Generate ephemeral ssh CA
- generate client and server certs
- sign both certs with CA cert
- include signed server cert in cloud-init script used to create / recreate server
- do nix-anywhere deploy with ephemeral signed client ssh cert
  - as part of deploy, use actual ssh CA to make new server cert
  - switch over to real client and server certs?

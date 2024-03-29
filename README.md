# _Delivery System_

[![Elixir CI](https://github.com/ProdigyReloaded/delivery-system/actions/workflows/elixir.yml/badge.svg)](https://github.com/ProdigyReloaded/delivery-system/actions/workflows/elixir.yml)

The _Delivery System_, as it was called by Prodigy, initially consisted of:
* The Dialup Access Concentrators and Regional Object Caches, operating initially on IBM Series/1 Minicomputers.
* The Central _switch_, operating on an IBM Mainframe running TPF (routing functions and fast transactions)
* The High Function Host, another IBM Mainframe running CICS (more complex transactions)

The Prodigy Reloaded _Delivery System_ combines the function of these components into a single application
(found in **apps/server**) and utilizes the Postgres database (supported by an associated component found in 
**apps/core**).

Utilities to manipulate databse objects (`podbutil`, the Prodigy Object Database Utility, found in **apps/podbutil**) and
household / user accounts (`pomsutil`, the Prodigy Operational Management System Utility, found in **apps/pomsutil**) are
provided.

An additional portal application that will furnish a web-based interface to acquire an account and to otherwise perform
the functions provided in `podbutil` and `pomsutil` will be forthcoming (to be placed in **apps/portal**).

The _Reception System_ was the client of the services provided by the _Delivery System_, and the content that comprised
the service was created by the _Producer System_.

## Start the service
```
docker compose up
docker compose run server /prod/rel/server/bin/server eval "Prodigy.Core.Release.migrate()"
```

## Install the objects
```
git clone git@github.com:ProdigyReloaded/objects.git /tmp/objects
docker compose run -v /tmp/objects:/objects:ro server podbutil import "/objects/*"
- Imported 498 objects
```

## Create an account 

```
docker compose run server pomsutil create
- Created Household XLNV42
- Created User XLNV42A with password WVYLC6
```

## Download dosbox-staging

Get the latest release for your operating system [here](https://dosbox-staging.github.io)

## Download the client

As of this writing, the client version software that shipped with the IBM PS/1 (RS 6.03.17)

The software is archived [here](https://archive.org/details/ibm-ps-1-users-club-and-prodigy-software-1990) and
the disk image is [here](https://archive.org/download/ibm-ps-1-users-club-and-prodigy-software-1990/IBM%20PS1%20Users%27%20Club%20and%20PRODIGY%20Software%20%281990%29.img).

## Prepare the client

Instructions below are prototypical for Linux, but may vary for your preferred operating system.

```
% mount /path/to/client.img /mnt/floppy
% mkdir -p /tmp/prodigy/C/PRODIGY
% cp /mnt/floppy /tmp/prodigy/C/PRODIGY
% umount /mnt/floppy
% cat << EOF > /tmp/prodigy/dosbox.conf
 !!! config here - see below
EOF
% cat << EOF > /tmp/prodigy/phones.conf
5551212 localhost:25234
EOF
%
```

## Dosbox Configuration

Dosbox configuration is beyond the scope of this document, but the default should work with a few tweaks:
```
[serial]
serial1       = modem baudrate:2400
phonebookfile = phones.txt

[autoexec]
mount C: /tmp/prodigy/C
C:
cd PRODIGY
PRODIGY.BAT
```


## Run dosbox and connect
```
% dosbox -conf /tmp/prodigy/dosbox.conf
```

If prompted for a phone number, use the same as created in the preparation step above (`5551212`).
Once prompted for a username and password, use the one returned by `pomsutil` above.

## Caveats

Neither DIA nor TCS protocols as implemented by the Reception System version targeted here provide a keepalive mechanism.
If the server is run behind anything with aggressive TCP timeouts, such as a load balancer or NAT device, one may 
experience `CM 4` errors in the Reception System.
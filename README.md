# DeliverySystem

**TODO: Add description**

# Start the service
```
docker compose up
docker compose run server /prod/rel/server/bin/server eval "Core.Release.migrate()"
```

# Install the objects
```
git clone git@github.com:ProdigyReloaded/objects.git /tmp/objects
docker compose run -v /tmp/objects:/objects:ro server podbutil import "/objects/*"
- Imported 498 objects
```

# Create an account 

```
docker compose run server pomsutil create
- Created Household XLNV42
- Created User XLNV42A with password WVYLC6
```

# Download dosbox-staging

Get the latest release for your operating system [here](https://dosbox-staging.github.io)

# Download the client

As of this writing, the client version software that shipped with the IBM PS/1 (RS 6.03.17)

The software is archived [here](https://archive.org/details/ibm-ps-1-users-club-and-prodigy-software-1990) and
the disk image is [here](https://archive.org/download/ibm-ps-1-users-club-and-prodigy-software-1990/IBM%20PS1%20Users%27%20Club%20and%20PRODIGY%20Software%20%281990%29.img).

# Prepare the client

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


# Run dosbox and connect
```
% dosbox -conf /tmp/prodigy/dosbox.conf
```

If prompted for a phone number, use the same as created in the preparation step above (`5551212`).
Once prompted for a username and password, use the one returned by `pomsutil` above.

#!/bin/bash
# home_bcp.sh v1 - kodukataloogide varundus (opetaja naite pohjal)
# NB! tootab oigesti ainult siis, kui kaivitada kataloogis /home
for user in *; do
    tar -czf /home_bcp/$user.$(date +%d.%m.%Y).tar.gz $user
done

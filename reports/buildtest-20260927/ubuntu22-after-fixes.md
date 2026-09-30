# smak build-test results

| distro | project | system | make | seq | par | server | multi |
|---|---|---|---|---|---|---|---|
| ubuntu22 | dnsmasq-full | make | PASS 6.1s | PASS 16.0s | WARN 7.7s | WARN 6.6s | WARN 6.0s |
| ubuntu22 | dnsmasq | make | PASS 3.9s | PASS 14.6s | PASS 4.5s | WARN 5.2s | PASS 4.9s |
| ubuntu22 | htop | autotools | PASS 3.9s | WARN 18.7s | WARN 4.5s | FAIL 1.1s | WARN 4.8s |
| ubuntu22 | tmux | autotools | PASS 13.5s | FAIL 57.4s | FAIL 13.3s | FAIL 17.1s | FAIL 16.8s |
| ubuntu22 | zlib | autotools | PASS 2.2s | PASS 7.2s | WARN 2.3s | WARN 2.9s | WARN 3.5s |

## Details

- **ubuntu22 / dnsmasq-full / par:** compile commands printed differently from make (products identical)
- **ubuntu22 / dnsmasq-full / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- **ubuntu22 / dnsmasq-full / multi:** compile commands printed differently from make (products identical); jobs per host: node1=25 node2=18
- ubuntu22 / dnsmasq-full: auto-installed libdbus-1-dev libidn2-dev libnetfilter-conntrack-dev nettle-dev libnftables-dev
- **ubuntu22 / dnsmasq / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- ubuntu22 / dnsmasq / multi: jobs per host node1=21 node2=22
- **ubuntu22 / htop / seq:** compile commands printed differently from make (products identical)
- **ubuntu22 / htop / par:** compile commands printed differently from make (products identical)
- **ubuntu22 / htop / server:** exit status 1; smak error: smak: *** [/work/htop/tree/UsersTable.o] Error 1; 175 artifact(s) make built are missing; 3 file(s) written that make does not write; smak-attach: bare `build` does not build the default goal
- **ubuntu22 / htop / multi:** compile commands printed differently from make (products identical); jobs per host: node1=44 node2=43
- ubuntu22 / htop: auto-installed libncurses-dev
- **ubuntu22 / tmux / seq:** 1 artifact(s) make built are missing; 158 compile command(s) differ from make and 1 product(s) differ: tmux
- **ubuntu22 / tmux / par:** exit status 1; compiler/tool error:         gcc -DPACKAGE_NAME=\"tmux\" -DPACKAGE_TARNAME=\"tmux\" -DPACKAGE_VERSION=\"next-3.9\" -DPACKAGE_STRING=\"tmux\ next-3.9\" -DPACKAGE_BUGREPORT=\"\" -DPACKAGE_URL=\"\" -DPACKAGE=\"tmux\" -DVER; 36 artifact(s) make built are missing
- **ubuntu22 / tmux / server:** exit status 1; compiler/tool error: compat/freezero.c:22:10: fatal error: compat.h: No such file or directory; 36 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu22 / tmux / multi:** exit status 1; compiler/tool error:         gcc -DPACKAGE_NAME=\"tmux\" -DPACKAGE_TARNAME=\"tmux\" -DPACKAGE_VERSION=\"next-3.9\" -DPACKAGE_STRING=\"tmux\ next-3.9\" -DPACKAGE_BUGREPORT=\"\" -DPACKAGE_URL=\"\" -DPACKAGE=\"tmux\" -DVER; 36 artifact(s) make built are missing; jobs per host: node1=75 node2=83
- ubuntu22 / tmux: auto-installed libevent-dev libncurses-dev
- **ubuntu22 / zlib / par:** compile commands printed differently from make (products identical)
- **ubuntu22 / zlib / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- **ubuntu22 / zlib / multi:** compile commands printed differently from make (products identical); jobs per host: node1=14 node2=28

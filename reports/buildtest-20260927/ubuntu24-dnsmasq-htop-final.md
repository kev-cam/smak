# smak build-test results

| distro | project | system | make | seq | par | server | multi |
|---|---|---|---|---|---|---|---|
| ubuntu | dnsmasq-full | make | PASS 5.5s | PASS 18.3s | PASS 6.3s | WARN 6.8s | PASS 6.5s |
| ubuntu | dnsmasq | make | PASS 4.1s | PASS 15.6s | PASS 4.8s | WARN 5.9s | PASS 7.7s |
| ubuntu | htop | autotools | PASS 4.4s | PASS 19.0s | PASS 5.0s | FAIL 1.1s | PASS 5.0s |

## Details

- **ubuntu / dnsmasq-full / server:** smak-attach: bare `build` does not build the default goal
- ubuntu / dnsmasq-full / multi: jobs per host node1=23 node2=20
- ubuntu / dnsmasq-full: auto-installed libdbus-1-dev libidn2-dev libnetfilter-conntrack-dev nettle-dev libnftables-dev
- **ubuntu / dnsmasq / server:** smak-attach: bare `build` does not build the default goal
- ubuntu / dnsmasq / multi: jobs per host node1=25 node2=18
- **ubuntu / htop / server:** exit status 1; smak error: smak: *** [/work/htop/tree/UptimeMeter.o] Error 1; 176 artifact(s) make built are missing; 3 file(s) written that make does not write; smak-attach: bare `build` does not build the default goal
- ubuntu / htop / multi: jobs per host node1=46 node2=41
- ubuntu / htop: auto-installed libncurses-dev

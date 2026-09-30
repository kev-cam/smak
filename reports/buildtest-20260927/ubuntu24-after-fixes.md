# smak build-test results

| distro | project | system | make | seq | par | server | multi | interp |
|---|---|---|---|---|---|---|---|---|
| ubuntu | cjson | cmake | PASS 1.8s | FAIL 0.3s | FAIL 1.5s | FAIL 0.5s | FAIL 1.8s | FAIL 1.4s |
| ubuntu | dnsmasq-full | make | PASS 5.0s | PASS 17.3s | WARN 6.0s | WARN 6.2s | WARN 6.0s |  |
| ubuntu | dnsmasq | make | PASS 4.5s | PASS 15.0s | PASS 6.9s | WARN 5.2s | PASS 5.3s |  |
| ubuntu | htop | autotools | PASS 4.4s | WARN 18.9s | WARN 5.0s | FAIL 1.0s | WARN 5.4s |  |
| ubuntu | iverilog | autotools | PASS 123.8s | FAIL 451.9s | FAIL 120.9s | FAIL 127.5s | FAIL 115.4s |  |
| ubuntu | jq | autotools | PASS 11.5s | WARN 26.7s | FAIL 180.0s | FAIL 0.7s | FAIL 31.4s |  |
| ubuntu | libuv | cmake | PASS 14.6s | FAIL 55.3s | FAIL 6.8s | FAIL 0.5s | FAIL 8.4s | FAIL 0.5s |
| ubuntu | lua | make | PASS 2.4s | FAIL 0.3s | FAIL 0.2s | FAIL 0.2s | FAIL 0.3s |  |
| ubuntu | lz4 | make | PASS 9.0s | FAIL 0.6s | FAIL 0.6s | FAIL 1.0s | FAIL 1.1s |  |
| ubuntu | redis | make | PASS 112.8s | FAIL 0.3s | FAIL 0.5s | FAIL 0.5s | FAIL 0.7s |  |
| ubuntu | tmux | autotools | PASS 14.4s | FAIL 56.4s | FAIL 14.4s | FAIL 17.7s | FAIL 14.2s |  |
| ubuntu | zlib-cmake | cmake | PASS 0.9s | FAIL 0.4s | FAIL 1.2s | FAIL 0.5s | FAIL 2.1s | FAIL 0.7s |
| ubuntu | zlib | autotools | PASS 2.0s | PASS 10.0s | WARN 2.3s | WARN 2.4s | WARN 2.6s |  |
| ubuntu | zstd | make | PASS 29.4s | FAIL 1.0s | FAIL 0.7s | FAIL 0.8s | FAIL 1.2s |  |

## Details

- **ubuntu / cjson / seq:** exit status 127; smak error: smak: *** [cJSON_test] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 68 artifact(s) make built are missing
- **ubuntu / cjson / par:** exit status 1; smak error: smak: *** [cJSON_test] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 22 artifact(s) make built are missing
- **ubuntu / cjson / server:** 70 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / cjson / multi:** exit status 1; smak error: smak: *** [cJSON_test] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 22 artifact(s) make built are missing; jobs per host: node1=2 node2=2
- **ubuntu / cjson / interp:** exit status 1; smak error: smak: *** [fuzzing/fuzz_main] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 22 product(s) cmake+make built are missing
- **ubuntu / dnsmasq-full / par:** compile commands printed differently from make (products identical)
- **ubuntu / dnsmasq-full / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- **ubuntu / dnsmasq-full / multi:** compile commands printed differently from make (products identical); jobs per host: node1=22 node2=21
- ubuntu / dnsmasq-full: auto-installed libdbus-1-dev libidn2-dev libnetfilter-conntrack-dev nettle-dev libnftables-dev
- **ubuntu / dnsmasq / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- ubuntu / dnsmasq / multi: jobs per host node1=25 node2=18
- **ubuntu / htop / seq:** compile commands printed differently from make (products identical)
- **ubuntu / htop / par:** compile commands printed differently from make (products identical)
- **ubuntu / htop / server:** exit status 1; smak error: smak: *** [/work/htop/tree/HostnameMeter.o] Error 1; 175 artifact(s) make built are missing; 3 file(s) written that make does not write; smak-attach: bare `build` does not build the default goal
- **ubuntu / htop / multi:** compile commands printed differently from make (products identical); jobs per host: node1=45 node2=42
- ubuntu / htop: auto-installed libncurses-dev
- **ubuntu / iverilog / seq:** 2 compile command(s) differ from make and 7 product(s) differ: driver/iverilog ivl ivlpp/ivlpp
- **ubuntu / iverilog / par:** 108 compile command(s) differ from make and 7 product(s) differ: driver/iverilog ivl ivlpp/ivlpp
- **ubuntu / iverilog / server:** 112 compile command(s) differ from make and 7 product(s) differ: driver/iverilog ivl ivlpp/ivlpp; smak-attach: bare `build` does not build the default goal
- **ubuntu / iverilog / multi:** 107 compile command(s) differ from make and 7 product(s) differ: driver/iverilog ivl ivlpp/ivlpp; jobs per host: node1=178 node2=180
- ubuntu / iverilog: auto-installed gperf
- **ubuntu / jq / seq:** compile commands printed differently from make (products identical)
- **ubuntu / jq / par:** timed out; smak error: smak: *** [src/config_opts.inc] Error 1; timed out; 104 artifact(s) make built are missing
- **ubuntu / jq / server:** exit status 1; smak error: smak: *** [src/config_opts.inc] Error 1; 104 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / jq / multi:** exit status 1; smak error: smak: *** [src/config_opts.inc] Error 1; jobs per host: node2=46
- **ubuntu / libuv / seq:** 2 artifact(s) make built are missing; compile commands printed differently from make (products identical)
- **ubuntu / libuv / par:** exit status 1; smak error: smak: *** [CMakeFiles/uv_run_tests.dir/test/test-tcp-close-while-connecting.c.o] Error 1; 525 artifact(s) make built are missing
- **ubuntu / libuv / server:** 953 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / libuv / multi:** exit status 1; smak error: smak: *** [CMakeFiles/uv_run_tests.dir/test/test-tcp-close-while-connecting.c.o] Error 1; 525 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / libuv / interp:** exit status 1; smak error: smak: *** [CMakeFiles/uv.dir/fs-poll.c.o] Error 1; compiler/tool error:   /work/libuv/tree/_smak_interp/../src/idna.c:20:10: fatal error: uv.h: No such file or directory; 7 product(s) cmake+make built are missing
- **ubuntu / lua / seq:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing
- **ubuntu / lua / par:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing
- **ubuntu / lua / server:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing; job server not running after detach
- **ubuntu / lua / multi:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / lz4 / seq:** 52 artifact(s) make built are missing; 2 file(s) written that make does not write
- **ubuntu / lz4 / par:** exit status 2; smak error: smak: *** [lib-release] Error 2; 53 artifact(s) make built are missing
- **ubuntu / lz4 / server:** exit status 1; smak error: smak: *** [lz4-release] Error 2; 53 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / lz4 / multi:** exit status 2; smak error: smak: *** [lib-release] Error 2; 53 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / redis / seq:** 736 artifact(s) make built are missing; compile commands printed differently from make (products identical)
- **ubuntu / redis / par:** exit status 127; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing
- **ubuntu / redis / server:** exit status 1; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / redis / multi:** exit status 127; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / tmux / seq:** 1 artifact(s) make built are missing; 156 compile command(s) differ from make and 1 product(s) differ: tmux
- **ubuntu / tmux / par:** exit status 1; compiler/tool error:         gcc -DPACKAGE_NAME=\"tmux\" -DPACKAGE_TARNAME=\"tmux\" -DPACKAGE_VERSION=\"next-3.9\" -DPACKAGE_STRING=\"tmux\ next-3.9\" -DPACKAGE_BUGREPORT=\"\" -DPACKAGE_URL=\"\" -DPACKAGE=\"tmux\" -DVER; 32 artifact(s) make built are missing
- **ubuntu / tmux / server:** exit status 1; compiler/tool error: compat/freezero.c:22:10: fatal error: compat.h: No such file or directory; 32 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / tmux / multi:** exit status 1; compiler/tool error:         gcc -DPACKAGE_NAME=\"tmux\" -DPACKAGE_TARNAME=\"tmux\" -DPACKAGE_VERSION=\"next-3.9\" -DPACKAGE_STRING=\"tmux\ next-3.9\" -DPACKAGE_BUGREPORT=\"\" -DPACKAGE_URL=\"\" -DPACKAGE=\"tmux\" -DVER; 32 artifact(s) make built are missing; jobs per host: node1=78 node2=78
- ubuntu / tmux: auto-installed libevent-dev libncurses-dev
- **ubuntu / zlib-cmake / seq:** exit status 127; smak error: smak: *** [test/infcover] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 83 artifact(s) make built are missing
- **ubuntu / zlib-cmake / par:** exit status 1; smak error: smak: *** [test/infcover] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 9 artifact(s) make built are missing
- **ubuntu / zlib-cmake / server:** 86 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / zlib-cmake / multi:** exit status 1; smak error: smak: *** [test/minigzipstatic] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 9 artifact(s) make built are missing; jobs per host: node1=7 node2=4
- **ubuntu / zlib-cmake / interp:** exit status 1; smak error: smak: *** [test/CMakeFiles/minigzipstatic.dir/minigzip.c.o] Error 1; compiler/tool error:   /work/zlib-cmake/tree/_smak_interp/../test/minigzip.c:29:10: fatal error: zlib.h: No such file or directory; 11 product(s) cmake+make built are missing
- **ubuntu / zlib / par:** compile commands printed differently from make (products identical)
- **ubuntu / zlib / server:** compile commands printed differently from make (products identical); smak-attach: bare `build` does not build the default goal
- **ubuntu / zlib / multi:** compile commands printed differently from make (products identical); jobs per host: node1=21 node2=21
- **ubuntu / zstd / seq:** 213 artifact(s) make built are missing
- **ubuntu / zstd / par:** exit status 127; smak error: smak: *** [/work/zstd/tree/lib/libzstd.a] Error 127; 213 artifact(s) make built are missing
- **ubuntu / zstd / server:** exit status 1; smak error: smak: *** [/work/zstd/tree/lib/libzstd.a] Error 127; 213 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / zstd / multi:** exit status 141; smak error: smak: *** [/work/zstd/tree/lib/libzstd.a] Error 127; 213 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)

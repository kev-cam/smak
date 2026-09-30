# smak build-test results

| distro | project | system | make | seq | par | server | multi | interp |
|---|---|---|---|---|---|---|---|---|
| ubuntu | cjson | cmake | PASS 1.8s | FAIL 0.3s | FAIL 1.3s | FAIL 0.5s | FAIL 2.0s | FAIL 1.7s |
| ubuntu | dnsmasq-full | make | PASS 3.9s | FAIL 15.6s | FAIL 5.6s | FAIL 5.9s | FAIL 5.5s |  |
| ubuntu | dnsmasq | make | PASS 3.9s | WARN 16.1s | PASS 5.8s | WARN 4.8s | PASS 6.4s |  |
| ubuntu | htop | autotools | CONFIG-FAIL |  |  |  |  |  |
| ubuntu | iverilog | autotools | PASS 113.1s | FAIL 388.1s | FAIL 110.3s | FAIL 114.0s | FAIL 115.0s |  |
| ubuntu | jq | autotools | PASS 9.8s | FAIL 26.3s | FAIL 1001.8s | FAIL 0.7s | FAIL 28.3s |  |
| ubuntu | libuv | cmake | PASS 15.6s | FAIL 60.1s | FAIL 6.5s | FAIL 0.5s | FAIL 8.6s | FAIL 0.5s |
| ubuntu | lua | make | PASS 2.5s | FAIL 0.2s | FAIL 0.3s | FAIL 0.3s | FAIL 0.3s |  |
| ubuntu | lz4 | make | PASS 10.0s | FAIL 0.8s | FAIL 1.0s | FAIL 0.9s | FAIL 1.2s |  |
| ubuntu | redis | make | PASS 120.1s | FAIL 0.4s | FAIL 0.4s | FAIL 0.6s | FAIL 0.7s |  |
| ubuntu | tmux | autotools | CONFIG-FAIL |  |  |  |  |  |
| ubuntu | zlib-cmake | cmake | PASS 1.0s | FAIL 0.3s | FAIL 1.0s | FAIL 0.5s | FAIL 1.4s | FAIL 0.6s |
| ubuntu | zlib | autotools | PASS 2.0s | PASS 8.8s | PASS 2.6s | WARN 2.8s | PASS 3.1s |  |
| ubuntu | zstd | make | PASS 33.4s | FAIL 1.0s | FAIL 0.7s | FAIL 0.8s | FAIL 1.1s |  |

## Details

- **ubuntu / cjson / seq:** exit status 127; smak error: smak: *** [cJSON_test] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 68 artifact(s) make built are missing
- **ubuntu / cjson / par:** exit status 1; smak error: smak: *** [fuzzing/fuzz_main] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 22 artifact(s) make built are missing
- **ubuntu / cjson / server:** 70 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / cjson / multi:** exit status 1; smak error: smak: *** [fuzzing/fuzz_main] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 21 artifact(s) make built are missing; jobs per host: node1=2 node2=3
- **ubuntu / cjson / interp:** exit status 1; smak error: smak: *** [cJSON_test] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 22 product(s) cmake+make built are missing
- **ubuntu / dnsmasq-full / seq:** 1 artifact(s) make built are missing; 1 file(s) written that make does not write
- **ubuntu / dnsmasq-full / par:** 1 artifact(s) make built are missing; 1 file(s) written that make does not write
- **ubuntu / dnsmasq-full / server:** 1 artifact(s) make built are missing; 1 file(s) written that make does not write; smak-attach: bare `build` does not build the default goal
- **ubuntu / dnsmasq-full / multi:** 1 artifact(s) make built are missing; 1 file(s) written that make does not write; jobs per host: node1=20 node2=23
- ubuntu / dnsmasq-full: auto-installed libdbus-1-dev libidn2-dev libnetfilter-conntrack-dev nettle-dev libnftables-dev
- **ubuntu / dnsmasq / seq:** 43 file(s) rebuilt on a no-op run: src/arp.o src/auth.o src/blockdata.o src/bpf.o src/cache.o
- **ubuntu / dnsmasq / server:** smak-attach: bare `build` does not build the default goal
- ubuntu / dnsmasq / multi: jobs per host node1=29 node2=14
- **ubuntu / htop / prepare:** compiler/tool error: configure: error: cannot find required curses/ncurses library; bin:required (unresolved)
- **ubuntu / iverilog / seq:** touching AStatement.cc did not rebuild AStatement.o
- **ubuntu / iverilog / par:** touching AStatement.cc did not rebuild AStatement.o
- **ubuntu / iverilog / server:** smak-attach: bare `build` does not build the default goal; touching AStatement.cc did not rebuild AStatement.o
- **ubuntu / iverilog / multi:** jobs per host: node1=172 node2=186; touching AStatement.cc did not rebuild AStatement.o
- ubuntu / iverilog: auto-installed gperf
- **ubuntu / jq / seq:** touching src/builtin.c did not rebuild src/.libs/builtin.o
- **ubuntu / jq / par:** exit status 143; smak error: smak: *** [src/config_opts.inc] Error 1; 104 artifact(s) make built are missing
- **ubuntu / jq / server:** exit status 1; smak error: smak: *** [src/config_opts.inc] Error 1; 104 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / jq / multi:** exit status 1; smak error: smak: *** [src/config_opts.inc] Error 1; jobs per host: node2=46
- **ubuntu / libuv / seq:** 2 artifact(s) make built are missing; compile commands printed differently from make (products identical)
- **ubuntu / libuv / par:** exit status 1; smak error: smak: *** [CMakeFiles/uv_run_tests.dir/test/test-tcp-close-while-connecting.c.o] Error 1; 527 artifact(s) make built are missing
- **ubuntu / libuv / server:** 953 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / libuv / multi:** exit status 1; smak error: smak: *** [CMakeFiles/uv_run_tests.dir/test/test-tcp-close-while-connecting.c.o] Error 1; 527 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / libuv / interp:** exit status 1; smak error: smak: *** [CMakeFiles/uv.dir/fs-poll.c.o] Error 1; compiler/tool error:   /work/libuv/tree/_smak_interp/../src/idna.c:20:10: fatal error: uv.h: No such file or directory; 7 product(s) cmake+make built are missing
- **ubuntu / lua / seq:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing
- **ubuntu / lua / par:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing
- **ubuntu / lua / server:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing; job server not running after detach
- **ubuntu / lua / multi:** exit status 2; perl error inside smak: at /opt/smak/Smak.pm line 2250.; 37 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / lz4 / seq:** 52 artifact(s) make built are missing; 2 file(s) written that make does not write
- **ubuntu / lz4 / par:** exit status 2; smak error: smak: *** [lz4-release] Error 2; 53 artifact(s) make built are missing
- **ubuntu / lz4 / server:** exit status 1; smak error: smak: *** [lib-release] Error 2; 53 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / lz4 / multi:** exit status 2; smak error: smak: *** [lib-release] Error 2; 53 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / redis / seq:** 736 artifact(s) make built are missing
- **ubuntu / redis / par:** exit status 127; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing
- **ubuntu / redis / server:** exit status 1; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / redis / multi:** exit status 127; smak error: smak: *** [build] Error 127; 736 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)
- **ubuntu / tmux / prepare:** compiler/tool error: configure: error: "libevent not found"
- **ubuntu / zlib-cmake / seq:** exit status 127; smak error: smak: *** [test/infcover] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 83 artifact(s) make built are missing
- **ubuntu / zlib-cmake / par:** exit status 1; smak error: smak: *** [test/minigzip] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 9 artifact(s) make built are missing
- **ubuntu / zlib-cmake / server:** 86 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / zlib-cmake / multi:** exit status 1; smak error: smak: *** [test/infcover] Error 1; compiler/tool error: collect2: error: ld returned 1 exit status; 9 artifact(s) make built are missing; jobs per host: node1=6 node2=6
- **ubuntu / zlib-cmake / interp:** exit status 1; smak error: smak: *** [test/CMakeFiles/minigzip.dir/minigzip.c.o] Error 1; compiler/tool error:   /work/zlib-cmake/tree/_smak_interp/../test/minigzip.c:29:10: fatal error: zlib.h: No such file or directory; 11 product(s) cmake+make built are missing
- **ubuntu / zlib / server:** smak-attach: bare `build` does not build the default goal
- ubuntu / zlib / multi: jobs per host node1=21 node2=21
- **ubuntu / zstd / seq:** 213 artifact(s) make built are missing
- **ubuntu / zstd / par:** exit status 127; smak error: smak: *** [/work/zstd/tree/programs/zstd] Error 127; 213 artifact(s) make built are missing
- **ubuntu / zstd / server:** exit status 1; smak error: smak: *** [/work/zstd/tree/lib/libzstd.a] Error 127; 213 artifact(s) make built are missing; smak-attach: bare `build` does not build the default goal
- **ubuntu / zstd / multi:** exit status 127; smak error: smak: *** [/work/zstd/tree/lib/libzstd.a] Error 127; 213 artifact(s) make built are missing; job placement not observed (compilers not called via PATH)

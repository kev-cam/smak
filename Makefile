# Makefile for libsmak-client.so — C client used by NVC's --accel path
# (and any other tool that wants to submit background compilation jobs
# to a running smak job-server instance).

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -fPIC
PREFIX  ?= /usr/local

.PHONY: all install uninstall clean

all: libsmak-client.so

libsmak-client.so: smak-client.c smak-client.h
	$(CC) $(CFLAGS) -shared -o $@ smak-client.c

install: libsmak-client.so
	install -d $(DESTDIR)$(PREFIX)/lib
	install -d $(DESTDIR)$(PREFIX)/include
	install -m 0755 libsmak-client.so $(DESTDIR)$(PREFIX)/lib/
	install -m 0644 smak-client.h $(DESTDIR)$(PREFIX)/include/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/lib/libsmak-client.so
	rm -f $(DESTDIR)$(PREFIX)/include/smak-client.h

clean:
	rm -f libsmak-client.so

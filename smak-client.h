// smak-client.h — Minimal C client for smak job server
// Connects to a running smak instance and submits build jobs.

#ifndef _SMAK_CLIENT_H
#define _SMAK_CLIENT_H

#include <stdbool.h>

// Find a running smak job server, return its master port (or -1)
int smak_find_server(void);

// Connect to smak server on given port, returns socket fd (or -1)
int smak_connect(int port);

// Submit a shell command as a build job
// target: the output file path (used as the target name)
// command: shell command to execute
// cwd: working directory
// Returns true if submission succeeded
bool smak_submit(int sockfd, const char *target,
                 const char *command, const char *cwd);

// Wait for a submitted job to complete
// Returns 0 on success, non-zero on failure
int smak_wait(int sockfd);

// Disconnect from smak
void smak_disconnect(int sockfd);

#endif // _SMAK_CLIENT_H

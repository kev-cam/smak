// smak-client.c — Minimal C client for smak job server

#include "smak-client.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>

// Find smak server port from port files in /tmp/$USER/smak/
int smak_find_server(void)
{
   const char *user = getenv("USER");
   if (!user) user = "unknown";

   char port_dir[256];
   snprintf(port_dir, sizeof(port_dir), "/tmp/%s/smak", user);

   DIR *dir = opendir(port_dir);
   if (!dir) return -1;

   int master_port = -1;
   struct dirent *ent;
   while ((ent = readdir(dir)) != NULL) {
      int pid;
      if (sscanf(ent->d_name, "smak-jobserver-%d.port", &pid) != 1)
         continue;

      // Check if process is alive
      if (kill(pid, 0) != 0) continue;

      // Read port file: first line = observer port, second = master port
      char path[512];
      snprintf(path, sizeof(path), "%s/%s", port_dir, ent->d_name);
      FILE *f = fopen(path, "r");
      if (!f) continue;

      int observer = 0;
      int master = 0;
      if (fscanf(f, "%d", &observer) == 1 && fscanf(f, "%d", &master) == 1)
         master_port = master;
      fclose(f);

      if (master_port > 0) break;
   }
   closedir(dir);
   return master_port;
}

int smak_connect(int port)
{
   int fd = socket(AF_INET, SOCK_STREAM, 0);
   if (fd < 0) return -1;

   struct sockaddr_in addr = {
      .sin_family = AF_INET,
      .sin_port = htons(port),
      .sin_addr.s_addr = inet_addr("127.0.0.1"),
   };

   if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
      close(fd);
      return -1;
   }

   // Send minimal ENV then ENV_END
   dprintf(fd, "ENV_END\n");

   // Wait for JOBSERVER_WORKERS_READY
   char buf[256];
   FILE *sf = fdopen(dup(fd), "r");
   if (sf && fgets(buf, sizeof(buf), sf)) {
      fclose(sf);
      if (strncmp(buf, "JOBSERVER_WORKERS_READY", 22) == 0)
         return fd;
   }
   if (sf) fclose(sf);

   close(fd);
   return -1;
}

bool smak_submit(int sockfd, const char *target,
                 const char *command, const char *cwd)
{
   // smak expects: SUBMIT_JOB\n<target>\n<cwd>\n<composite>\n
   dprintf(sockfd, "SUBMIT_JOB\n%s\n%s\ntrue\n", target, cwd);
   return true;
}

int smak_wait(int sockfd)
{
   // Read responses until we see JOB_DONE or JOB_FAILED
   char buf[4096];
   FILE *sf = fdopen(dup(sockfd), "r");
   if (!sf) return -1;

   int result = -1;
   while (fgets(buf, sizeof(buf), sf)) {
      if (strncmp(buf, "JOB_DONE", 8) == 0) {
         result = 0;
         break;
      }
      if (strncmp(buf, "JOB_FAILED", 10) == 0) {
         result = 1;
         break;
      }
      // Other output: ignore or log
   }
   fclose(sf);
   return result;
}

void smak_disconnect(int sockfd)
{
   dprintf(sockfd, "QUIT\n");
   close(sockfd);
}

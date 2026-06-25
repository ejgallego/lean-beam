// Copyright (c) 2026 Lean FRO LLC. All rights reserved.
// Released under Apache 2.0 license as described in the file LICENSE.

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double monotonic_seconds(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    perror("clock_gettime");
    exit(2);
  }
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void timeout_handler(int signum) {
  (void)signum;
  static const char message[] = "mcp-http-resolver-probe: timeout in active resolver call\n";
  ssize_t ignored = write(STDERR_FILENO, message, sizeof(message) - 1);
  (void)ignored;
  _exit(124);
}

static int parse_timeout(int argc, char **argv) {
  if (argc < 2) {
    return 5;
  }
  char *end = NULL;
  long value = strtol(argv[1], &end, 10);
  if (end == argv[1] || *end != '\0' || value <= 0 || value > 300) {
    fprintf(stderr, "usage: %s [timeout-seconds]\n", argv[0]);
    exit(2);
  }
  return (int)value;
}

int main(int argc, char **argv) {
  setvbuf(stderr, NULL, _IONBF, 0);
  int timeout = parse_timeout(argc, argv);
  signal(SIGALRM, timeout_handler);

  fprintf(stderr, "mcp-http-resolver-probe: pid=%ld timeout=%ds\n", (long)getpid(), timeout);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("socket");
    return 1;
  }

  int reuse = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) {
    perror("setsockopt(SO_REUSEADDR)");
    close(fd);
    return 1;
  }

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = 0;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  double start = monotonic_seconds();
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    perror("bind");
    close(fd);
    return 1;
  }
  fprintf(stderr, "mcp-http-resolver-probe: bind elapsed=%.3fs\n", monotonic_seconds() - start);

  socklen_t addr_len = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &addr_len) != 0) {
    perror("getsockname");
    close(fd);
    return 1;
  }

  char ip[INET_ADDRSTRLEN];
  if (inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip)) == NULL) {
    perror("inet_ntop");
    close(fd);
    return 1;
  }
  fprintf(stderr, "mcp-http-resolver-probe: bound ip=%s port=%u\n", ip, (unsigned)ntohs(addr.sin_port));

  fprintf(stderr, "mcp-http-resolver-probe: gethostbyaddr start ip=%s\n", ip);
  start = monotonic_seconds();
  errno = 0;
  alarm((unsigned)timeout);
  struct hostent *host = gethostbyaddr(&addr.sin_addr, sizeof(addr.sin_addr), AF_INET);
  int saved_errno = errno;
  int saved_h_errno = h_errno;
  alarm(0);
  fprintf(
      stderr,
      "mcp-http-resolver-probe: gethostbyaddr done elapsed=%.3fs result=%s h_errno=%d errno=%d (%s)\n",
      monotonic_seconds() - start,
      host != NULL ? host->h_name : "<null>",
      saved_h_errno,
      saved_errno,
      strerror(saved_errno));

  char name[NI_MAXHOST];
  fprintf(stderr, "mcp-http-resolver-probe: getnameinfo start ip=%s\n", ip);
  start = monotonic_seconds();
  alarm((unsigned)timeout);
  int gai = getnameinfo((struct sockaddr *)&addr, addr_len, name, sizeof(name), NULL, 0, NI_NAMEREQD);
  saved_errno = errno;
  alarm(0);
  fprintf(
      stderr,
      "mcp-http-resolver-probe: getnameinfo done elapsed=%.3fs result=%s gai=%d (%s) errno=%d (%s)\n",
      monotonic_seconds() - start,
      gai == 0 ? name : "<null>",
      gai,
      gai == 0 ? "ok" : gai_strerror(gai),
      saved_errno,
      strerror(saved_errno));

  close(fd);
  return 0;
}

/* dozor-run PORT /absolute/path [args...]. The network boundary is installed before exec. */
#include <sys/socket.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sysexits.h>
#include <spawn.h>
#include <libproc.h>
#include <pwd.h>
#include <sys/stat.h>
#include <sys/proc.h>

#include <limits.h>
#include <time.h>
#include <math.h>
#include <ctype.h>
#include <sys/time.h>
extern char **environ;

static int current_permit(long port) {
    char path[PATH_MAX];
#ifdef DOZOR_TEST_BUILD
    const char *state = getenv("DOZOR_TEST_STATE");
    if (!state || snprintf(path, sizeof(path), "%s/cli.permit", state) >= sizeof(path)) return 0;
#else
    struct passwd *pw = getpwuid(getuid());
    if (!pw || snprintf(path, sizeof(path), "%s/Library/Application Support/Dozor/cli.permit", pw->pw_dir) >= sizeof(path)) return 0;
#endif
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0022)) { close(fd); return 0; }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return 0; }
    long approved; double end, wall; int pid; unsigned long long sec, usec; char extra;
    int n = fscanf(f, "%ld %lf %lf %d %llu %llu %c", &approved, &end, &wall, &pid, &sec, &usec, &extra);
    fclose(f);
    double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
    struct proc_bsdinfo info;
    return n == 6 && approved == port && isfinite(end) && isfinite(wall) && end > now && end <= now + 11 &&
        wall > clock_gettime_nsec_np(CLOCK_REALTIME) / 1e9 && wall <= clock_gettime_nsec_np(CLOCK_REALTIME) / 1e9 + 11 && pid > 1 &&
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
        info.pbi_uid == getuid() && info.pbi_status != SZOMB && info.pbi_start_tvsec == sec && info.pbi_start_tvusec == usec;
}

int main(int argc, char **argv) {
    if (argc < 3 || argv[2][0] != '/') {
        fprintf(stderr, "Usage: dozor-run LOCAL_HTTP_PROXY_PORT /absolute/executable [args...]\n");
        return EX_USAGE;
    }
    char *end;
    long port = strtol(argv[1], &end, 10);
    if (!*argv[1] || strspn(argv[1], "0123456789") != strlen(argv[1]) || *end || port < 1 || port > 65535) return EX_USAGE;
    if (!current_permit(port)) { fprintf(stderr, "Dozor: fresh VPN approval required; launch blocked\n"); return EX_UNAVAILABLE; }
    /* An inherited connected descriptor would predate this policy. Keep only normal stdio. */
    for (int fd = 0; fd <= 2; fd++) {
        int type; socklen_t size = sizeof(type);
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0) return EX_NOPERM;
    }
    char profile[512], proxy[64];
    snprintf(profile, sizeof(profile), "(version 1)(allow default)(deny network*)(allow network-outbound (remote tcp \"localhost:%ld\"))", port);
    snprintf(proxy, sizeof(proxy), "http://127.0.0.1:%ld", port);
    const char *names[] = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", NULL};
    for (int i = 0; names[i]; i++) if (setenv(names[i], proxy, 1)) return EX_OSERR;
    unsetenv("NO_PROXY"); unsetenv("no_proxy");
    /* Validate proxy availability before launching a new job. The sandbox remains in force if it disappears later. */
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons((unsigned short)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    struct timeval timeout = {.tv_sec=1};
    if (sock < 0 || setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) || connect(sock, (struct sockaddr *)&addr, sizeof(addr))) {
        fprintf(stderr, "Dozor: local proxy unavailable; launch blocked\n"); return EX_UNAVAILABLE;
    }
    close(sock);
    char **args = calloc((size_t)argc + 2, sizeof(*args));
    if (!args) return EX_OSERR;
    args[0] = "/usr/bin/sandbox-exec"; args[1] = "-p"; args[2] = profile;
    for (int i = 2; i < argc; i++) args[i + 1] = argv[i];
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    if (posix_spawnattr_init(&attr) || posix_spawn_file_actions_init(&actions) ||
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT)) return EX_OSERR;
    for (int fd = 0; fd <= 2; fd++) {
        if (fcntl(fd, F_GETFD) != -1 && posix_spawn_file_actions_addinherit_np(&actions, fd)) return EX_OSERR;
    }
    pid_t pid;
    errno = posix_spawn(&pid, args[0], &actions, &attr, args, environ);
    perror("Dozor: protected launch failed"); return EX_OSERR;
}

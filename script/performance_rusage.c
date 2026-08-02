#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static uint64_t monotonic_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static void sleep_milliseconds(uint64_t milliseconds) {
    struct timespec requested = {
        .tv_sec = (time_t)(milliseconds / 1000ULL),
        .tv_nsec = (long)((milliseconds % 1000ULL) * 1000000ULL),
    };
    while (nanosleep(&requested, &requested) != 0 && errno == EINTR) {
    }
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s pid duration-seconds interval-milliseconds\n", argv[0]);
        return 2;
    }

    const int pid = atoi(argv[1]);
    const double duration_seconds = strtod(argv[2], NULL);
    const uint64_t interval_ms = strtoull(argv[3], NULL, 10);
    if (pid <= 0 || duration_seconds <= 0 || interval_ms == 0) {
        fprintf(stderr, "invalid sampler arguments\n");
        return 2;
    }

    const uint64_t started_at = monotonic_nanoseconds();
    const uint64_t duration_ns = (uint64_t)(duration_seconds * 1000000000.0);
    puts("monotonic_ns,elapsed_ns,energy_nj,user_time_ns,system_time_ns,idle_wakeups,interrupt_wakeups,phys_footprint_bytes");
    fflush(stdout);

    for (;;) {
        struct rusage_info_v6 usage = {0};
        if (proc_pid_rusage(
                pid,
                RUSAGE_INFO_V6,
                (rusage_info_t *)&usage
            ) != 0) {
            if (errno == ESRCH) {
                return 0;
            }
            perror("proc_pid_rusage");
            return 3;
        }
        const uint64_t now = monotonic_nanoseconds();
        const uint64_t elapsed = now - started_at;
        printf(
            "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
            now,
            elapsed,
            usage.ri_energy_nj,
            usage.ri_user_time,
            usage.ri_system_time,
            usage.ri_pkg_idle_wkups,
            usage.ri_interrupt_wkups,
            usage.ri_phys_footprint
        );
        fflush(stdout);
        if (elapsed >= duration_ns) {
            break;
        }
        sleep_milliseconds(interval_ms);
    }
    return 0;
}

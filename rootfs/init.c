/* Minimal PID 1 used to prove that Linux reaches userspace on RTL. */

typedef unsigned long size_t;

struct timespec {
    long tv_sec;
    long tv_nsec;
};

static long syscall3(long number, long arg0, long arg1, long arg2)
{
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a2 __asm__("a2") = arg2;
    register long a7 __asm__("a7") = number;

    __asm__ volatile ("ecall"
                      : "+r"(a0)
                      : "r"(a1), "r"(a2), "r"(a7)
                      : "memory");
    return a0;
}

static size_t string_length(const char *text)
{
    size_t length = 0;
    while (text[length] != '\0')
        ++length;
    return length;
}

static void print(const char *text)
{
    /* RISC-V Linux syscall 64: write(fd, buffer, count). */
    syscall3(64, 1, (long)text, (long)string_length(text));
}

__attribute__((noreturn)) void _start(void)
{
    static const struct timespec delay = { 1, 0 };

    print("\nlinuxCPU: reached minimal RISC-V userspace\n");
    print("linuxCPU: PID 1 is alive on OpenC906 RTL\n");

    for (;;) {
        /* RISC-V Linux syscall 101: nanosleep(request, remaining). */
        syscall3(101, (long)&delay, 0, 0);
    }
}

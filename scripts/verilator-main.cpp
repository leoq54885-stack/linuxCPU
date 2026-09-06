// Project main loop for reproducible Verilator experiments.
//
// Verilator releases before 5.044 did not set VerilatedContext's runtime
// thread count in the --binary-generated main.  The context then defaulted to
// hardware_concurrency(), creating an oversized worker pool.  Keep this small
// wrapper until the pinned Verilator is upgraded.

#include <csignal>
#include <memory>

#include "Vtb.h"
#include "verilated.h"

#ifndef LINUXCPU_MODEL_THREADS
#error "LINUXCPU_MODEL_THREADS must match Verilator --threads"
#endif

namespace {
volatile std::sig_atomic_t stopRequested = 0;

void requestStop(int) { stopRequested = 1; }
}  // namespace

int main(int argc, char** argv, char**) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->threads(LINUXCPU_MODEL_THREADS);
    contextp->commandArgs(argc, argv);
    std::signal(SIGINT, requestStop);
    std::signal(SIGTERM, requestStop);

    const std::unique_ptr<Vtb> topp{new Vtb{contextp.get()}};
    while (!contextp->gotFinish() && !stopRequested) {
        topp->eval();
        if (!topp->eventsPending()) break;
        contextp->time(topp->nextTimeSlot());
    }
    topp->final();
    return 0;
}

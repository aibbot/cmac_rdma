#ifndef RDCP_STOP_SIGNAL_HPP
#define RDCP_STOP_SIGNAL_HPP

#include <csignal>

namespace rdcp {

inline volatile std::sig_atomic_t stop_signal_latched{};

inline void latch_stop_signal(int) noexcept {
    stop_signal_latched = 1;
}

inline bool install_stop_signal_handlers() noexcept {
    stop_signal_latched = 0;
    return std::signal(SIGINT, latch_stop_signal) != SIG_ERR &&
           std::signal(SIGTERM, latch_stop_signal) != SIG_ERR;
}

inline bool stop_signal_requested() noexcept {
    return stop_signal_latched != 0;
}

inline void clear_stop_signal() noexcept {
    stop_signal_latched = 0;
}

}  // namespace rdcp

#endif
